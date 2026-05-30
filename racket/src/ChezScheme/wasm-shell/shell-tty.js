/* shell-tty.js  --  linked into scheme-web.js via `emcc --post-js`.
 *
 * This runs inside the Emscripten module closure (on every thread that
 * loads the script, including the PROXY_TO_PTHREAD compute worker), so it
 * can see the internal `TTY`, `HEAP32`, and the exported ring accessors.
 *
 * It replaces the default TTY character ops so that stdin/stdout go
 * through the shared-memory rings defined in wasm_shell_io.c instead of
 * window.prompt / console.log:
 *
 *   - get_char (stdin): NON-blocking. Return the next byte from the input
 *     ring if one is buffered, otherwise return `undefined`. Returning
 *     `undefined` makes Emscripten's TTY raise EAGAIN, which rktio treats
 *     as a clean "would-block" and retries; returning `null` instead would
 *     be read as EOF and kill the REPL. Crucially we must NOT block here:
 *     under -sPROXY_TO_PTHREAD the filesystem is proxied to the main
 *     browser thread (MEMFS is per-thread JS state), so get_char actually
 *     runs on the main thread, where Atomics.wait is illegal and throws
 *     (Emscripten then reports ESPIPE/errno 29 -- the original bug).
 *   - put_char (stdout/stderr): push each byte into the output ring; the
 *     page polls and renders it (no newline buffering, so the REPL prompt
 *     shows immediately).
 *
 * The page side (browser-shell.js) is the peer producer/consumer. Because
 * the proxied FS and the page both run on the main thread, the input ring
 * is effectively single-threaded; the Atomics calls are kept only for
 * memory ordering and cost nothing here.
 */
(function () {
  if (typeof TTY === "undefined") {
    return;
  }

  var HEAD = 0, TAIL = 1, DATA = 2;

  var inBase = -1, inCap = 0;
  var outBase = -1, outCap = 0;

  function resolveAddr(fn) {
    // The accessor may be visible as a closure-scoped `_name` or on Module.
    if (typeof fn === "function") return fn();
    return null;
  }

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

  // A read() pulls the currently-available bytes; when the ring is empty
  // we return `undefined` (EAGAIN / would-block), never `null` (EOF).
  var pending = [];

  function getChar() {
    if (pending.length) return pending.shift();
    if (!inReady()) return undefined;

    // Re-read HEAP32 each time: ALLOW_MEMORY_GROWTH can swap the view.
    var H = HEAP32;
    var head = Atomics.load(H, inBase + HEAD);
    var tail = Atomics.load(H, inBase + TAIL);

    if (head === tail) return undefined;   // no input yet -> would-block

    while (head !== tail) {
      pending.push(Atomics.load(H, inBase + DATA + (head % inCap)) & 0xff);
      head++;
    }
    Atomics.store(H, inBase + HEAD, head);

    return pending.length ? pending.shift() : undefined;
  }

  function putByte(val) {
    if (val === null || val === undefined) return;
    if (!outReady()) return;
    var H = HEAP32;
    var tail = Atomics.load(H, outBase + TAIL);
    H[outBase + DATA + (tail % outCap)] = val & 0xff;
    Atomics.store(H, outBase + TAIL, tail + 1);
    // No notify: the main thread polls (it may not Atomics.wait).
  }

  TTY.default_tty_ops.get_char = function () { return getChar(); };
  TTY.default_tty_ops.put_char = function (tty, val) { putByte(val); };
  TTY.default_tty_ops.fsync = function () {};

  if (TTY.default_tty1_ops) {
    TTY.default_tty1_ops.put_char = function (tty, val) { putByte(val); };
    TTY.default_tty1_ops.fsync = function () {};
  }
})();
