/* idbfs-init.js -- linked into scheme-web.js via `emcc --pre-js`.
 *
 * Mount IDBFS at /home/web_user during Module.preRun, when we are
 * still inside the module's IIFE (so `IDBFS`, `FS`, `addRunDependency`
 * are reachable as bare identifiers) and the event loop is still
 * alive (so syncfs's IDB callbacks can complete before main() runs).
 *
 * Sync direction:
 *   - Boot:   IDB -> MEMFS via FS.syncfs(true), gated by
 *             addRunDependency so main() doesn't start until the
 *             previous session's files are loaded.
 *   - Save:   MEMFS -> IDB via FS.syncfs(false), called from
 *             Module.onExit (shell-worker.js). This is the *only*
 *             time the persistent flush is safe to do, because the
 *             worker's event loop is blocked inside Racket the rest
 *             of the time. The page-side "Save & Restart" button
 *             drives a clean exit via (exit 0) sent on the input
 *             ring; after the worker has flushed it terminates and
 *             the page spawns a fresh worker.
 */
(function () {
  if (typeof Module === "undefined") return;
  Module["preRun"] = Module["preRun"] || [];
  Module["preRun"].push(function () {
    try { FS.mkdirTree("/home/web_user"); } catch (e) { /* exists */ }
    if (typeof IDBFS === "undefined") {
      try { self.postMessage({ type: "idbfs", text: "IDBFS not linked" }); } catch (_) {}
      return;
    }
    try {
      FS.mount(IDBFS, {}, "/home/web_user");
    } catch (e) {
      try { self.postMessage({ type: "idbfs", text: "mount failed: " + (e && e.message) }); } catch (_) {}
      return;
    }
    addRunDependency("idbfs-load");
    FS.syncfs(true, function (err) {
      try {
        self.postMessage({
          type: "idbfs",
          text: err ? "load error: " + (err.message || err) : "loaded"
        });
      } catch (_) {}
      removeRunDependency("idbfs-load");
    });
  });
})();
