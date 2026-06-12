/* shell-worker.js -- runs the Racket WASM runtime in a dedicated Web
 * Worker.
 *
 * The page (ide.js) spawns this script as a worker. The worker waits
 * for an `init` message from the page before loading scheme-web.js, so
 * that the page gets to choose:
 *
 *   - `argv`   -- becomes Module.arguments. Racket sees these as its
 *                 command-line arguments. `[]` (the default) runs the
 *                 interactive REPL; `["-u","/tmp/main.rkt"]` runs a
 *                 module and exits; `["-e","(form)"]` runs an
 *                 expression. The IDE uses `[]` (a plain REPL) and then
 *                 requires racket/enter + `enter!`s the program itself.
 *   - `files`  -- { "/abs/path": "<text>" } seeded into MEMFS during
 *                 preRun (before main()). Used by the IDE to drop the
 *                 editor's source at /tmp/main.rkt before main() runs.
 *   - `idbfs`  -- whether to mount IDBFS at /home/web_user. A
 *                 persistent surface passes true; the IDE's transient
 *                 process-per-run passes false.
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

    // Under -sPROXY_TO_PTHREAD, Emscripten spawns its pthread workers (the
    // proxied main + the pool) via `new Worker(pthreadMainJs)`, where
    // pthreadMainJs defaults to `_scriptName` -- which is THIS worker's URL
    // (shell-worker.js), because scheme-web.js is loaded via importScripts and
    // cannot discover its own URL. That spawns useless extra shell-worker.js
    // instances and the proxied main never boots. Point it at the real
    // Emscripten module so pthread workers run scheme-web.js in pthread mode.
    mainScriptUrlOrBlob: "./scheme-web.js",

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
      /* io-state flag: 1 while the runtime is blocked on stdin (see
         wasm_shell_io.c / shell-tty.js). The page polls it to show a
         "waiting for input" affordance. */
      var ioStateAddr = M["_shell_io_state_addr"] ? M["_shell_io_state_addr"]() : 0;
      /* DOM RPC slots (see racket/src/cs/c/wasm_dom.c). The page-
         side rAF poller in ide.js consumes commands from cmd_seq /
         cmd_buf and writes replies to reply_seq / reply_buf. */
      var domCmdSeq   = M["_wasm_dom_cmd_seq_addr"]   ? M["_wasm_dom_cmd_seq_addr"]()   : 0;
      var domCmdLen   = M["_wasm_dom_cmd_len_addr"]   ? M["_wasm_dom_cmd_len_addr"]()   : 0;
      var domCmdBuf   = M["_wasm_dom_cmd_buf_addr"]   ? M["_wasm_dom_cmd_buf_addr"]()   : 0;
      var domCmdCap   = M["_wasm_dom_cmd_cap"]        ? M["_wasm_dom_cmd_cap"]()        : 0;
      var domReplySeq = M["_wasm_dom_reply_seq_addr"] ? M["_wasm_dom_reply_seq_addr"]() : 0;
      var domReplyLen = M["_wasm_dom_reply_len_addr"] ? M["_wasm_dom_reply_len_addr"]() : 0;
      var domReplyBuf = M["_wasm_dom_reply_buf_addr"] ? M["_wasm_dom_reply_buf_addr"]() : 0;
      var domReplyCap = M["_wasm_dom_reply_cap"]      ? M["_wasm_dom_reply_cap"]()      : 0;
      post({
        type:    "ready",
        heap:    M["HEAPU8"].buffer,            // SharedArrayBuffer
        inBase:  inAddr  >> 2,                  // int32 indices
        inCap:   inCap,
        outBase: outAddr >> 2,
        outCap:  outCap,
        stateBase: ioStateAddr >> 2,
        dom: {
          cmdSeqBase:   domCmdSeq   >> 2,
          cmdLenBase:   domCmdLen   >> 2,
          cmdBufAddr:   domCmdBuf,
          cmdCap:       domCmdCap,
          replySeqBase: domReplySeq >> 2,
          replyLenBase: domReplyLen >> 2,
          replyBufAddr: domReplyBuf,
          replyCap:     domReplyCap,
        },
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
  // Load the package payload loader first. Unlike the boot/collects payload
  // (baked into scheme-web.js by the emcc link), the Racket package tree
  // ships as a SEPARATE file_packager artifact -- share.data + share.data.js,
  // built by the orchestrator's `pack-pkgs` step -- so changing packages
  // needn't relink scheme-web.*. This loader pushes onto Module.preRun and
  // gates run() via addRunDependency until share.data is fetched into MEMFS,
  // so /share/pkgs is present before main(), exactly as when it was in-link.
  // It must run before scheme-web.js so its preRun registers in time; it
  // reaches FS/addRunDependency (exported on Module) once the runtime is up.
  importScripts("./share.data.js");
  // Synchronously instantiate the runtime; Emscripten's generated
  // wrapper reads self.Module that we set above.
  importScripts("./scheme-web.js");
};
