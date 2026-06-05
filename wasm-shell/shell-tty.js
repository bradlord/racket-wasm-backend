/* shell-tty.js  --  linked into scheme-web.js via `emcc --post-js`.
 *
 * This runs inside the Emscripten module closure (on the runtime
 * worker -- see shell-worker.js), so it can see the internal `TTY`,
 * `HEAP32`, and the exported ring accessors.
 *
 * It replaces the TTY stream ops so that stdin/stdout go through the
 * shared-memory rings defined in wasm_shell_io.c instead of
 * window.prompt / console.log:
 *
 *   - read (stdin): blocks on the input ring with Atomics.wait until at
 *     least one byte is available, then drains up to `length` bytes from
 *     the ring into the syscall buffer and returns the count. Blocking
 *     here is safe because the runtime lives on a dedicated worker (the
 *     page itself spawns it). The page's main thread, which may NOT
 *     Atomics.wait, only writes into the input ring and polls the
 *     output ring.
 *
 *     *We override stream_ops.read directly, not default_tty_ops.get_char.*
 *     Emscripten's TTY stream_ops.read implementation calls get_char in a
 *     loop, breaking only when get_char returns null/undefined. A blocking
 *     get_char would happily deliver the first byte(s), then block forever
 *     inside the same read syscall waiting for the (length - bytesRead)
 *     trailing characters that nobody will ever type. The syscall would
 *     never return; Racket would never observe the typed line. Owning
 *     the whole syscall and returning after one wait avoids that trap.
 *
 *   - write (stdout/stderr): push each byte into the output ring; the
 *     page polls and renders it (no newline buffering, so the REPL
 *     prompt shows immediately).
 *
 * The page side (ide.js) is the peer producer/consumer.
 */
(function () {
  if (typeof TTY === "undefined") {
    return;
  }

  var HEAD = 0, TAIL = 1, DATA = 2;

  var inBase = -1, inCap = 0;
  var outBase = -1, outCap = 0;

  function inReady() {
    if (inBase >= 0) return true;
    var addrFn = (typeof _shell_in_addr === "function") ? _shell_in_addr
               : (Module && Module["_shell_in_addr"]);
    var capFn = (typeof _shell_in_cap === "function") ? _shell_in_cap
              : (Module && Module["_shell_in_cap"]);
    if (typeof addrFn !== "function" || typeof capFn !== "function") return false;
    inBase = addrFn() >> 2;   // byte address -> Int32 index
    inCap = capFn();
    return true;
  }

  function outReady() {
    if (outBase >= 0) return true;
    var addrFn = (typeof _shell_out_addr === "function") ? _shell_out_addr
               : (Module && Module["_shell_out_addr"]);
    var capFn = (typeof _shell_out_cap === "function") ? _shell_out_cap
              : (Module && Module["_shell_out_cap"]);
    if (typeof addrFn !== "function" || typeof capFn !== "function") return false;
    outBase = addrFn() >> 2;
    outCap = capFn();
    return true;
  }

  function streamRead(stream, buffer, offset, length /*, pos */) {
    if (length <= 0) return 0;
    if (!inReady()) return 0;

    // Re-read HEAP32 each time we touch it: ALLOW_MEMORY_GROWTH can
    // swap the typed-array view.
    var H = HEAP32;
    var head = Atomics.load(H, inBase + HEAD);
    var tail = Atomics.load(H, inBase + TAIL);

    // Block until the page bumps tail and notifies. Wait at most once
    // per syscall: when we wake (or were already past), we deliver
    // whatever is currently buffered and return -- the rktio read path
    // is happy to be called again for the remainder.
    while (head === tail) {
      Atomics.wait(H, inBase + TAIL, tail);
      H = HEAP32;
      tail = Atomics.load(H, inBase + TAIL);
    }

    var n = 0;
    while (head !== tail && n < length) {
      buffer[offset + n] = Atomics.load(H, inBase + DATA + (head % inCap)) & 0xff;
      head++;
      n++;
    }
    Atomics.store(H, inBase + HEAD, head);
    return n;
  }

  function putByte(val) {
    if (val === null || val === undefined) return;
    if (!outReady()) return;
    var H = HEAP32;
    var tail = Atomics.load(H, outBase + TAIL);
    H[outBase + DATA + (tail % outCap)] = val & 0xff;
    Atomics.store(H, outBase + TAIL, tail + 1);
    // No notify: the page polls (it may not Atomics.wait).
  }

  function streamWrite(stream, buffer, offset, length /*, pos */) {
    if (length <= 0) return 0;
    for (var i = 0; i < length; i++) putByte(buffer[offset + i]);
    return length;
  }

  TTY.stream_ops.read  = streamRead;
  TTY.stream_ops.write = streamWrite;

  // Keep put_char overrides so anything that still calls them (fsync of
  // a partially buffered line, future code paths) routes through the
  // output ring rather than the default console.
  TTY.default_tty_ops.put_char = function (tty, val) { putByte(val); };
  TTY.default_tty_ops.fsync    = function () {};
  if (TTY.default_tty1_ops) {
    TTY.default_tty1_ops.put_char = function (tty, val) { putByte(val); };
    TTY.default_tty1_ops.fsync    = function () {};
  }
})();
