/* node-locate-file.js -- linked into the node `scheme.js` build via
 * `emcc --extern-pre-js`.
 *
 * Emscripten's internal `locateFile(path)` resolves files against
 * `scriptDirectory` (the directory of scheme.js under node), which is why
 * `scheme.wasm` loads regardless of the process CWD. The data-package
 * loader emitted by `--preload-file`, however, does NOT use that path: it
 * calls `Module["locateFile"]` directly and, when that hook is undefined,
 * falls back to the bare relative string ("scheme.data"), which
 * `fs.readFileSync` then resolves against the *current working directory*.
 *
 * The result is that `node scheme.js` only finds `scheme.data` when run
 * from inside the build dir; `node path/to/scheme.js` fails with ENOENT.
 *
 * This MUST be an `--extern-pre-js`, not a `--pre-js`: the file-packager
 * loader runs `loadPackage()` synchronously at parse time, *before* the
 * point where emcc splices ordinary pre-js. `--extern-pre-js` is
 * concatenated at the very top of the output file, ahead of the `var
 * Module` declaration and the loader, so the hook is in place in time.
 *
 * The browser surface never reaches this (no node `process`), so it is a
 * no-op there.
 */
(function () {
  if (typeof process === "undefined" || !process.versions || !process.versions.node) return;
  if (typeof __dirname === "undefined") return;

  var path = require("path");
  function locate(filename) {
    if (path.isAbsolute(filename) || /^[a-z][a-z0-9+.-]*:\/\//i.test(filename)) {
      return filename;
    }
    return path.join(__dirname, filename);
  }

  // `var Module` is hoisted from its declaration later in the generated file
  // (same top-level scope under the non-MODULARIZE node build), so this
  // assignment populates that binding before the data loader reads it.
  if (typeof Module === "undefined") { Module = {}; }
  if (!Module["locateFile"]) { Module["locateFile"] = locate; }
})();
