/* shell-worker.js -- runs the Racket WASM runtime in a dedicated Web
 * Worker.
 *
 * The page (browser-shell.js) spawns this script as a worker. The worker
 * loads scheme-web.js synchronously; Emscripten boots Racket's `main()`
 * on this thread (which is *this* worker's own main thread, not the
 * page's). Once the runtime is up, we hand the page:
 *
 *   - the SharedArrayBuffer that backs WASM linear memory (sharable
 *     because scheme-web.js is built with -pthread), and
 *   - the int32 offsets and capacities of the stdin/stdout rings
 *     defined in wasm_shell_io.c.
 *
 * The page then writes typed bytes into the input ring and polls the
 * output ring. Because the rings live in the same SharedArrayBuffer,
 * Atomics.wait/notify in shell-tty.js coordinate this worker (consumer
 * of stdin) with the page (producer of stdin).
 *
 * IDBFS persistence (legacy-FS / save-and-restart flavor):
 *   - Boot:  /home/web_user is mounted on IDBFS and FS.syncfs(true)
 *            runs during preRun, before the event loop is monopolized
 *            by Racket. See wasm-shell/idbfs-init.js (--pre-js).
 *   - Save:  the page sends `(exit 0)\n` over the input ring on a
 *            user-initiated "Save & Restart"; Racket exits cleanly,
 *            Module.onExit runs (event loop now free), we flush
 *            MEMFS -> IDB via FS.syncfs(false), then post `exit` to
 *            the page so it can terminate this worker and spawn a
 *            fresh one.
 *
 * This replaces the older -sPROXY_TO_PTHREAD design, where Emscripten
 * itself spawned a "compute" pthread but proxied filesystem syscalls --
 * including the TTY's get_char -- back to the page's main thread,
 * forcing a non-blocking, busy-polling stdin. Hosting the runtime in a
 * worker we created ourselves means get_char actually runs here and is
 * free to Atomics.wait, eliminating the spin between keystrokes.
 */
"use strict";

function post(msg) { self.postMessage(msg); }

self.Module = {
  locateFile: function (path) { return path; },

  // setStatus messages from Emscripten include the download
  // "loaded/total" suffix; the page parses both.
  setStatus: function (text) {
    post({ type: "status", text: text || "" });
  },

  monitorRunDependencies: function (remaining) {
    post({ type: "deps", remaining: remaining });
  },

  print:    function (s) { /* routed via TTY ring; ignore */ },
  printErr: function (s) { /* routed via TTY ring; ignore */ },

  onRuntimeInitialized: function () {
    var M = self.Module;
    var inAddr  = M["_shell_in_addr"]();
    var inCap   = M["_shell_in_cap"]();
    var outAddr = M["_shell_out_addr"]();
    var outCap  = M["_shell_out_cap"]();
    post({
      type:    "ready",
      heap:    M["HEAPU8"].buffer,            // SharedArrayBuffer
      inBase:  inAddr  >> 2,                  // int32 indices
      inCap:   inCap,
      outBase: outAddr >> 2,
      outCap:  outCap,
    });
  },

  onAbort: function (reason) {
    post({ type: "abort", reason: String(reason) });
  },

  onExit: function (code) {
    // Final IDB flush. The runtime has just exited so the worker's
    // JS thread is no longer monopolized; IDB async callbacks can
    // now actually fire. The page waits for our { type: "exit" }
    // message before terminating us.
    var done = function (err) {
      post({ type: "exit", code: code | 0, syncErr: err && (err.message || String(err)) });
    };
    try {
      self.Module.FS.syncfs(false, done);
    } catch (e) { done(e); }
  },
};

// Synchronously instantiate the runtime; Emscripten's generated wrapper
// reads self.Module that we set above.
importScripts("./scheme-web.js");
