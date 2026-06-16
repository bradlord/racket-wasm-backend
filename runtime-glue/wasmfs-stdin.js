// wasmfs-stdin.js -- linked into racket-web.js via `emcc --js-library`.
//
// Restores the stdin half of the legacy shell-tty.js path under WasmFS.
//
// Why not the obvious _wasmfs_stdin_get_char hook? WasmFS hard-codes fd 0 to its
// StdinFile, whose read() loops the overridable _wasmfs_stdin_get_char(). Backing
// that hook with the input ring looks right but never runs: rktio gates every
// read on poll(POLLIN) (rktio_fd.c do_poll_read_ready), and WasmFS's
// __syscall_poll reports a non-regular fd readable only when
// getFile()->getSize() > 0 (syscalls.cpp). StdinFile::getSize() is hard-coded 0
// and is not overridable, so poll never fired, the read never ran, and the hook
// was dead. The REPL printed its prompt and hung.
//
// Fix: don't use StdinFile at all. Register our own jsimpl backend and dup2 its
// file onto fd 0 (in racket_wasm_browser_fs_init). wasmfs_create_file masks the
// S_IFCHR type bit off the mode (doOpen: `mode &= S_IALLUGO`), so the node is a
// *regular* file -- which is exactly what we want: rktio fstats it, sees
// S_ISREG, sets RKTIO_OPEN_REGFILE, and then SKIPS poll entirely ("Reading
// regular file never blocks", rktio_fd.c) and issues a plain blocking read().
// That read lands in the backend read() below, which blocks on the input ring
// with Atomics.wait until the page supplies a line -- the same discipline
// shell-tty.js's TTY.stream_ops.read used, just re-homed onto a jsimpl device.
//
// THREADING: identical to wasmfs-console.js. WasmFS's jsimpl ops
// (_wasmfs_jsimpl_read/_get_size) run on the *calling* thread and look up the
// backend in `wasmFS$backends`, which is per-thread JS state and is NOT proxied
// (system/lib/wasmfs/js_impl_backend.h). Under -sPROXY_TO_PTHREAD, Racket -- and
// thus every stdin read() -- runs on the proxied main pthread, so the backend
// must be registered on that same pthread. Hence this is a C-callable
// (rkt_stdin_setup) invoked from racket_wasm_browser_fs_init, which runs in
// main() on the proxied pthread, co-locating registration with the reads.
//
// rkt_stdin_setup returns the fd of the freshly created device node (wasmfs_-
// create_file opens it read-only); C dup2()s that onto fd 0. It also mirrors the
// io-state flag (1 while parked in Atomics.wait, 0 otherwise) that the page polls
// for its "waiting for input" affordance.
addToLibrary({
  rkt_stdin_setup__deps: [
    '$wasmFS$backends',
    'wasmfs_create_jsimpl_backend',
    'wasmfs_create_file',
    '$stringToUTF8OnStack',
    '$withStackSave',
  ],
  rkt_stdin_setup: function () {
    var HEAD = 0, TAIL = 1, DATA = 2;
    var inBase = _shell_in_addr() >> 2;          // byte addr -> int32 index
    var inCap  = _shell_in_cap();
    var stateBase = _shell_io_state_addr() >> 2;

    var backend = _wasmfs_create_jsimpl_backend();
    wasmFS$backends[backend] = {
      allocFile: function () {},
      freeFile:  function () {},
      // Any positive size: a non-regular interpretation of this fd would poll
      // readable (getSize > 0) and proceed to read. (rktio actually treats the
      // node as a regular file and skips poll, but this keeps both paths live.)
      getSize:   function () { return 1; },
      setSize:   function () { return 0; },
      // stdin is read-only; accept and discard any write.
      write:     function (file, buffer, length, offset) { return length; },

      // Blocking ring read. Park (Atomics.wait) while the ring is empty, then
      // drain up to `length` bytes. Always returns >= 1, so rktio never sees a 0
      // (EOF) result and the REPL stays alive. Re-read HEAP32 after each wait:
      // ALLOW_MEMORY_GROWTH can swap the view out from under us.
      read: function (file, buffer, length, offset) {
        if (length <= 0) return 0;
        var H = HEAP32;
        var head = Atomics.load(H, inBase + HEAD);
        var tail = Atomics.load(H, inBase + TAIL);
        while (head === tail) {
          Atomics.store(H, stateBase, 1);        // blocked: waiting for input
          Atomics.wait(H, inBase + TAIL, tail);
          H = HEAP32;
          tail = Atomics.load(H, inBase + TAIL);
        }
        Atomics.store(H, stateBase, 0);          // input available
        var n = 0;
        while (head !== tail && n < length) {
          HEAPU8[buffer + n] = Atomics.load(H, inBase + DATA + (head % inCap)) & 0xff;
          head++; n++;
        }
        Atomics.store(H, inBase + HEAD, head);
        return n;
      },
    };

    // Create the device node bound to the backend. wasmfs_create_file creates
    // AND opens it (read-only, O_RDONLY == 0), returning the fd we hand back to C
    // for the dup2 onto fd 0.
    return withStackSave(function () {
      return _wasmfs_create_file(stringToUTF8OnStack("/dev/rkt_stdin"), 0o444, backend);
    });
  },
});
