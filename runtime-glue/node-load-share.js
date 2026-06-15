/* node-load-share.js -- linked into the node `racket.js` build via
 * `emcc --pre-js`.
 *
 * The node surface's package tree (the `/share/pkgs` + `/share/links.rktd`
 * payload) ships as a SEPARATE Emscripten data file -- `share.data` +
 * `share.data.js`, built by the orchestrator's `pack-pkgs` step -- instead of
 * being baked into the emcc link. That way changing packages needn't relink
 * the (expensive) `racket.*` surface. The boot images + /collects + /etc stay
 * in the link (they only change on a Racket-version rebuild).
 *
 * The browser worker loads share.data.js with `importScripts`, which runs it
 * in the worker's global scope where the `file_packager` loader binds to the
 * global `Module`. Node has no `importScripts`, and `racket.js`'s `Module` is
 * MODULE-scoped (a hoisted top-level `var`, set by node-locate-file.js), not on
 * `globalThis`. So we reproduce the worker's environment by hand:
 *
 *   - expose this module's `Module` and `require` on `globalThis`, then
 *   - run share.data.js via INDIRECT eval, which executes in global scope.
 *
 * The loader's own `var Module = typeof Module != 'undefined' ? Module : {}`
 * then rebinds to our `Module`, and its node branch (`require('fs')
 * .readFileSync`) finds `require`. It registers the package load on
 * Module.preRun and gates run() via addRunDependency until share.data is in
 * MEMFS -- exactly as the in-link core preload loader does. (Direct eval will
 * not do: the loader's self-declared `var Module` would shadow ours in the
 * surrounding function scope and disconnect.) Loading it at RUNTIME rather than
 * as a `--pre-js` is the whole point -- it keeps the package payload out of the
 * link. See build-wasm.md "Packages as a separate data file".
 *
 * The browser never reaches this (no node `process`), so it is a no-op there;
 * and if share.data.js is absent (a build that didn't pack it), it no-ops too.
 */
(function () {
  if (typeof process === "undefined" || !process.versions || !process.versions.node) return;
  if (typeof require === "undefined" || typeof __dirname === "undefined") return;

  var fs = require("fs");
  var path = require("path");
  var loader = path.join(__dirname, "share.data.js");
  if (!fs.existsSync(loader)) return;

  // `Module` resolves to racket.js's module-scoped runtime object (this file is
  // concatenated into that scope as a --pre-js); `require` is this module's.
  // Indirect eval runs the loader in global scope, where both must be reachable.
  globalThis.Module = Module;
  globalThis.require = require;
  (0, eval)(fs.readFileSync(loader, "utf8"));
})();
