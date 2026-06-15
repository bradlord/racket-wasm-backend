// wasmfs-stdin.js -- linked into racket-web.js via `emcc --js-library`.
//
// The WasmFS build replaces shell-tty.js. WasmFS drops the legacy
// `TTY.stream_ops` that shell-tty.js used to override and instead hard-codes
// stdin (fd 0) to its `StdinFile`, whose `read()` loops calling the overridable
// hook `_wasmfs_stdin_get_char()` -- up to the full stdio buffer -- and stops
// early only when the hook returns < 0 (emsdk system/lib/wasmfs/special_files.cpp,
// `StdinFile::read`). This `--js-library` override backs that hook with the
// shared-memory INPUT ring from wasm_shell_io.c.
//
// Discipline that dodges the per-char loop trap (a naive blocking get_char would
// deliver the first byte(s) then block forever inside the same read() waiting for
// the trailing chars nobody will type):
//
//   - block (Atomics.wait) only on the FIRST empty ring of a read burst;
//   - once we've delivered >= 1 byte this burst, return -1 on the next empty so
//     read() returns the line instead of looping to fill the whole buffer.
//
// Runs on the proxied main pthread (under -sPROXY_TO_PTHREAD), where Atomics.wait
// is permitted; the page (ide.js) is the peer producer. Mirrors the io-state flag
// (1 while parked waiting for input, 0 otherwise) that shell-tty.js used to set,
// so the page's "waiting for input" affordance still works.
addToLibrary({
  $shellStdin: { inBase: -1, inCap: 0, stateBase: -1, delivered: false },

  _wasmfs_stdin_get_char__deps: ['$shellStdin'],
  _wasmfs_stdin_get_char: function () {
    var S = shellStdin;
    if (S.inBase < 0) {
      S.inBase = _shell_in_addr() >> 2;   // byte addr -> int32 index
      S.inCap = _shell_in_cap();
      S.stateBase = _shell_io_state_addr() >> 2;
    }
    var HEAD = 0, TAIL = 1, DATA = 2;
    var base = S.inBase, cap = S.inCap;

    // Re-read HEAP32 each time we touch it: ALLOW_MEMORY_GROWTH can swap the
    // typed-array view out from under us.
    if (S.outBase === undefined) { S.outBase = _shell_out_addr() >> 2; S.outCap = _shell_out_cap(); }
    function dbg(s) { var Ho = HEAP32, t = Atomics.load(Ho, S.outBase + 1); for (var i = 0; i < s.length; i++) { Ho[S.outBase + 2 + (t % S.outCap)] = s.charCodeAt(i) & 0xff; t++; } Atomics.store(Ho, S.outBase + 1, t); }

    var H = HEAP32;
    var head = Atomics.load(H, base + HEAD);
    var tail = Atomics.load(H, base + TAIL);
    dbg("\n{gc h=" + head + " t=" + tail + " d=" + (S.delivered ? 1 : 0) + "}");

    if (head === tail) {
      // Empty. If we already delivered a byte this burst, end the read (so
      // read() returns the line) rather than blocking for more.
      if (S.delivered) { S.delivered = false; return -1; }
      // First empty of the burst: block for the next line.
      Atomics.store(H, S.stateBase, 1);   // blocked: waiting for the user to type
      dbg("{WAIT t=" + tail + "}");
      while (head === tail) {
        var wr = Atomics.wait(H, base + TAIL, tail);
        H = HEAP32;
        tail = Atomics.load(H, base + TAIL);
        dbg("{woke " + wr + " t=" + tail + "}");
      }
      Atomics.store(H, S.stateBase, 0);   // input available -- no longer waiting
    }

    var b = Atomics.load(H, base + DATA + (head % cap)) & 0xff;
    Atomics.store(H, base + HEAD, head + 1);
    S.delivered = true;
    return b;
  },
});
