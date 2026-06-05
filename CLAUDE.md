# Claude operating notes for this tree

This is a fork of Racket whose live work is a WebAssembly port of
Racket CS, on the `wasm-backend` branch. Racket itself is the
upstream repo (`master`); everything WASM-specific is additive.

The substantive documentation for the port -- architecture, build
sequence, dep tree, dependency recipes, known issues, and rationale
for every non-obvious decision -- lives in
[`build-wasm.md`](build-wasm.md). Read it before doing anything in
the WASM area; that's where the design context is. Notable sections:

- §1-5: build sequence (rktio, libffi, tpb32l boot, Chez Emscripten,
  link).
- "Browser shell" and "IDE page": the shared-runtime + per-surface
  host architecture, and the DrRacket-like IDE (`ide.html`/`ide.js`)
  built on it.
- "Preloading additional Racket packages": how to ship a Racket
  package into the WASM `/share/pkgs` tree with a links file.
- "Calling WASM-specific primitives from Racket": the rktio dll
  shim, libm registrations, and the Sforeign_lookup hook that makes
  `ffi-lib` + `get-ffi-obj` work without dlopen.
- "DOM interaction": v0 synchronous DOM RPC via SAB; what's there,
  what's stub-only, and the migration path to a typed protocol.

## Keep `build-wasm.md` current

Any non-trivial decision made in a session (a new dep recipe, a
build-system workaround, a known limitation that future work has to
respect, a why-we-picked-X-over-Y rationale) belongs in
`build-wasm.md` near the relevant section. The doc is the project's
durable memory; without it, the next session re-derives context
from commit messages, which is slower and lossier.

Concretely, update `build-wasm.md` when:

- a new dep recipe lands under `racket/src/cs/c/wasm-deps/deps/`,
- a new C primitive in `racket/src/cs/c/wasm_*.c` becomes
  registered for FFI access,
- the build script gains a new stage / target / workaround,
- an upstream Chez / libffi / rktio patch goes in (note it in the
  "What still has to be written" list of patches to upstream),
- a Racket package preload is added or its dep set changes,
- a recurring failure mode is diagnosed (the kqueue / res_query /
  TextDecoder-SAB type of thing -- record it so the next attempt
  doesn't re-discover the same trap).

Commit doc changes alongside the code change they describe rather
than as a separate "update docs" commit; the doc and the code drift
otherwise.

## Build conventions

- Working directory: project root (`/Users/brad/oss/racket`). Most
  commands assume relative paths from here.
- Branch: `wasm-backend`. Commits stay on this branch; nothing has
  been upstreamed yet.
- Build entry point: `make wasm SCHEME=<host-scheme> RACKET=<host-racket>`
  (emsdk sourced first). This runs the stock build system end to end and
  emits both runtime surfaces into `racket/src/build/cs/c/wasm/`:
  `scheme.{js,wasm,data}` (node) and `scheme-web.{js,wasm,data}` plus the
  IDE page assets (`ide.html`/`ide.js`). See `build-wasm.md` for the stage
  breakdown and prerequisites. (The legacy per-stage `wasm-shell/*.sh`
  scripts have been removed; `wasm-shell/` now holds only the browser
  runtime assets/glue and the two test files.)
- The browser shell needs COOP/COEP headers for `SharedArrayBuffer`.
  Serve via `racket racket/src/build/cs/c/wasm/serve.rkt`.

## What this tree is *not*

It's not yet a clean upstream patch set. The Chez fixes
(foreign-call ABI alignment, self-tagged foreign-callable indices)
and the rktio dll shim are real bug fixes that should land upstream
eventually; the recipe-driven dep system, wasm_* primitives, and
shell JS are wasm-port machinery that probably stays branch-local.
The split is tracked in `build-wasm.md`'s "What still has to be
written" section.
