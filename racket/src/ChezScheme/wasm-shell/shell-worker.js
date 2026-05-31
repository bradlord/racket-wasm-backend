/* shell-worker.js -- runs the Racket WASM runtime in a dedicated Web
 * Worker.
 *
 * The page (e.g. browser-shell.js, playground.js) spawns this script as
 * a worker. The worker waits for an `init` message from the page before
 * loading scheme-web.js, so that the page gets to choose:
 *
 *   - `argv`   -- becomes Module.arguments. Racket sees these as its
 *                 command-line arguments. `[]` (the default) runs the
 *                 interactive REPL; `["-u","/tmp/main.rkt"]` runs a
 *                 module and exits; `["-e","(form)"]` runs an
 *                 expression; etc.
 *   - `files`  -- { "/abs/path": "<text>" } seeded into MEMFS during
 *                 preRun (before main()). Used by the playground to
 *                 drop the user's source in place for `-u`.
 *   - `idbfs`  -- whether to mount IDBFS at /home/web_user. The REPL
 *                 wants persistence (true); transient playground
 *                 programs do not (false).
 *
 * After init, importScripts("./scheme-web.js") boots the runtime on
 * this worker's own thread. Once it is up, we hand the page:
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
 *            by Racket. See wasm-shell/idbfs-init.js (--pre-js). It
 *            checks Module._idbfsEnabled and skips mounting if false.
 *   - Save:  the page sends `(exit 0)\n` over the input ring on a
 *            user-initiated "Save & Restart"; Racket exits cleanly,
 *            Module.onExit runs (event loop now free), we flush
 *            MEMFS -> IDB via FS.syncfs(false), then post `exit` to
 *            the page so it can terminate this worker and spawn a
 *            fresh one. When _idbfsEnabled is false we skip syncfs.
 */
"use strict";

function post(msg) { self.postMessage(msg); }

function buildModule(init) {
  return {
    arguments: Array.isArray(init.argv) ? init.argv.slice() : [],
    _idbfsEnabled: init.idbfs !== false,   // default on

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

    preRun: [
      function () {
        // Seed any page-supplied files into MEMFS before main() runs.
        var files = init.files || {};
        var paths = Object.keys(files);
        for (var i = 0; i < paths.length; i++) {
          var p = paths[i];
          var parent = p.replace(/\/[^/]*$/, "");
          try { if (parent) FS.mkdirTree(parent); } catch (_) {}
          try {
            FS.writeFile(p, files[p]);
          } catch (e) {
            post({ type: "fs-error", path: p, error: String(e && e.message || e) });
          }
        }
      },
    ],

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
      if (!self.Module._idbfsEnabled) { done(null); return; }
      try {
        self.Module.FS.syncfs(false, done);
      } catch (e) { done(e); }
    },
  };
}

self.onmessage = function (event) {
  var msg = event.data;
  if (!msg || msg.type !== "init") return;
  self.onmessage = null;
  self.Module = buildModule(msg);
  // Synchronously instantiate the runtime; Emscripten's generated
  // wrapper reads self.Module that we set above.
  importScripts("./scheme-web.js");
};
