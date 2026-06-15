// wasmfs-console.js -- linked into racket-web.js via `emcc --js-library`.
//
// The WasmFS build's replacement for shell-tty.js's stdout/stderr half.
//
// WasmFS has no `TTY.stream_ops` to override, and its hard-coded stdout/stderr
// (`WritingStdFile`, emsdk system/lib/wasmfs/special_files.cpp) line-buffer the
// fd until a '\n'/'\0' before calling emscripten_out -- which would swallow the
// REPL prompt ("> ", no trailing newline) and any unterminated `(display ...)`.
// The legacy TTY path delivered every byte immediately.
//
// To restore per-byte output we register a write-only char device whose `write`
// pushes each byte straight into the shared-memory OUTPUT ring (wasm_shell_io.c)
// with no newline buffering, then racket_wasm_browser_fs_init (wasm_shell_io.c)
// dup2()s fds 1 and 2 onto it.
//
// THREADING: WasmFS's jsimpl device ops (`_wasmfs_jsimpl_write`) run on the
// *calling* thread and look up the backend in `wasmFS$backends`, which is
// per-thread JS state -- they are NOT proxied (system/lib/wasmfs/
// js_impl_backend.h). Under -sPROXY_TO_PTHREAD, Racket -- and thus every stdout
// write() -- runs on the proxied main pthread, not the worker main thread where
// preRun runs. So the device must be created on that same pthread, or the
// backend lookup misses. Hence this is a C-callable (`rkt_console_setup`)
// invoked from racket_wasm_browser_fs_init, which runs in main() on the proxied
// pthread -- co-locating device registration with the writes.
//
// stdin (fd 0) is handled separately by wasmfs-stdin.js (--js-library), which
// overrides _wasmfs_stdin_get_char; the io-state "waiting for input" flag lives
// there. This file owns output only.
addToLibrary({
  $shellOut: { outBase: -1, outCap: 0, done: false },

  // Create the /dev/console ring device. Idempotent; called once from C on the
  // proxied main pthread (see THREADING above), before the dup2 of fds 1/2.
  rkt_console_setup__deps: ['$shellOut'],
  rkt_console_setup: function () {
    var S = shellOut;
    if (S.done) return;
    S.done = true;

    var HEAD = 0, TAIL = 1, DATA = 2;

    // Push one byte into the output ring. No Atomics.notify: the page polls (its
    // main thread may not Atomics.wait). Re-read HEAP32 each call: ALLOW_MEMORY_-
    // GROWTH can swap the view.
    function putByte(val) {
      if (val === null || val === undefined) return;
      if (S.outBase < 0) {
        S.outBase = _shell_out_addr() >> 2;   // byte addr -> int32 index
        S.outCap = _shell_out_cap();
      }
      var H = HEAP32;
      var tail = Atomics.load(H, S.outBase + TAIL);
      H[S.outBase + DATA + (tail % S.outCap)] = val & 0xff;
      Atomics.store(H, S.outBase + TAIL, tail + 1);
    }

    // FS.createDevice(parent, name, input, output): a write-only char device.
    // Its write() is invoked per write syscall and loops calling output() per
    // byte -- no '\n' buffering, unlike the WritingStdFile path.
    try {
      FS.createDevice("/dev", "console", null, putByte);
    } catch (e) {
      try {
        self.postMessage({ type: "console", text: "createDevice failed: " + (e && e.message || e) });
      } catch (_) {}
    }
  },
});
