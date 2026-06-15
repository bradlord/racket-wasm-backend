/* node-tty.js -- linked into the node `racket.js` build via `emcc --pre-js`.
 *
 * Replaces the default TTY get_char/put_char so that:
 *
 *   - get_char (stdin): reads real bytes from node's stdin via fs.readSync.
 *     Returns the next buffered byte; when the underlying read would block
 *     (e.g. stdin is a non-blocking pipe from `child_process.spawn`) we
 *     return `undefined`, which Emscripten's TTY layer maps to EAGAIN and
 *     rktio treats as a clean "would-block" so the REPL retries instead
 *     of looping on the error. Returning `null` is reserved for real EOF
 *     -- that ends the REPL cleanly.
 *
 *     This is the node analogue of the browser's ring-backed stdin
 *     (wasmfs-stdin.js); without it, Emscripten's
 *     default $FS_stdin_getChar leaks an EAGAIN exception out of
 *     fs.readSync, the TTY device wraps it as EIO (errno 29), and rktio
 *     reports `error reading from stream port` in a tight loop.
 *
 *   - put_char (stdout/stderr): write each byte unbuffered to the host
 *     process's stdout/stderr, so the REPL prompt appears immediately.
 */
(function () {
  if (typeof process === "undefined" || !process.stdin) return;
  if (typeof TTY === "undefined") return;

  var fs = require("fs");
  var BUF = Buffer.alloc(256);
  var pending = [];
  var atEOF = false;

  function fillBuffer() {
    if (atEOF) return;
    try {
      var n = fs.readSync(0, BUF, 0, BUF.length, null);
      if (n === 0) { atEOF = true; return; }
      for (var i = 0; i < n; i++) pending.push(BUF[i]);
    } catch (e) {
      var code = e && e.code;
      if (code === "EAGAIN" || code === "EWOULDBLOCK" || code === "EINTR") {
        return;                              // would-block: pending stays empty
      }
      if (String(e).indexOf("EOF") !== -1) { // node throws on EOF for some fd kinds
        atEOF = true;
        return;
      }
      // Anything else: treat as EOF rather than leaking EIO into rktio.
      atEOF = true;
    }
  }

  function getChar() {
    if (pending.length) return pending.shift();
    fillBuffer();
    if (pending.length) return pending.shift();
    if (atEOF) return null;
    return undefined;                        // signal EAGAIN, not EOF
  }

  function putByte(stream, val) {
    if (val === null || val === undefined) return;
    var buf = Buffer.from([val & 0xff]);
    try { stream.write(buf); } catch (_) {}
  }

  TTY.default_tty_ops.get_char  = function () { return getChar(); };
  TTY.default_tty_ops.put_char  = function (_tty, val) { putByte(process.stdout, val); };
  TTY.default_tty_ops.fsync     = function () {};
  if (TTY.default_tty1_ops) {
    TTY.default_tty1_ops.put_char = function (_tty, val) { putByte(process.stderr, val); };
    TTY.default_tty1_ops.fsync    = function () {};
  }
})();
