# racket-wasm

A nearly-complete **Racket CS** — the compiler *and* the runtime — running
entirely **inside a web browser**. Racket is compiled to
[WebAssembly](https://webassembly.org/) (a portable binary format browsers run
at near-native speed) via [Emscripten](https://emscripten.org/), so everything
executes client-side: there is no server-side Racket, no remote evaluation, just
Racket itself running on the page.

**▶ Try the live playground/REPL: <https://racket-wasm.netlify.app/>**

This project is expressed as a *delta* over upstream Racket rather than a fork: a
Racket orchestrator clones upstream at a pinned commit, applies a small set of
patches, and drives the cross-build end to end.

## What's in this repo

- **Patches** (`patches/` + additive files in `overlay/`) that get upstream
  Racket CS building for WebAssembly under Emscripten.
- **A Racket orchestrator** (`build/`) that clones upstream at the pin
  (`upstream.lock`), applies the delta, drives the cross-build, and packages the
  result into a static bundle that runs in a browser (or under node).
- **Sample applications** (`apps/`) — including a browser playground/REPL
  (`apps/ide`, the live demo above) and a node REPL (`apps/node-repl`).

## How it runs (the short version)

A few of the less-obvious runtime decisions, for orientation:

- Racket runs in a **dedicated Web Worker** so its blocking `main()`/REPL
  doesn't freeze the page. The page and the worker exchange console bytes
  through `SharedArrayBuffer` ring buffers, and the worker parks on input with
  `Atomics.wait`.
- The link enables **`-sPROXY_TO_PTHREAD`**, running Racket off the worker's own
  main thread so Emscripten's main-thread-proxied calls can complete (this is
  what fixed a GLib/font deadlock).
- The Chez "pb" interpreter is built as **tpb32l** (32-bit pointers, to match
  WASM32), and boot images are pbchunk-compiled so boot takes ~2 s instead of
  minutes.

These and the rest of the design history are written up in
[`build-wasm.md`](build-wasm.md) — see the note on it below.

## Hosting a generated bundle

The output is just static files (`racket-web.{js,wasm,data}`, `index.html`, and
the worker glue), but the page **must be served cross-origin isolated**. The
host has to send:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

Browsers gate `SharedArrayBuffer` (used for the stdin/stdout ring buffers
between the page and the runtime worker) behind cross-origin isolation, so a
plain static server will not start the runtime. The repo sets these two ways:
the dev server `runtime-glue/serve.rkt` sends them on every response, and the
Netlify deploy ships a `netlify.toml`/`_headers` with them.

**Size caveat.** The runtime payload is large — roughly **~26 MB
`racket.wasm` + ~87 MB `racket.data`** with the fast-boot images. That's fine
for demos, playgrounds, and teaching, but likely impractical for a production
web app where download size matters.

## Layout

- `build/` — the Racket orchestrator (`racket build/main.rkt <subcommand>`).
- `patches/` — one diff per modified upstream file, applied to the clone.
- `overlay/` — additive files copied into the clone.
- `runtime-glue/` — repo-side runtime glue: the emcc link-JS (passed to the
  link via `RUNTIME_GLUE_DIR`) + the browser worker bootstrap and dev server.
- `wasm-deps/` — native-dependency build recipes (passed via `WASM_DEPS_SRC_DIR`).
- `packages/` — repo-side Racket packages bundled into the build, e.g.
  `web-repl` (the DOM/canvas/REPL collection the browser IDE is built on).
- `package-patches/` — patches applied to upstream Racket *packages* (as opposed
  to the core tree), e.g. a cairo font-options fix for `draw-lib`.
- `apps/` — sample applications (`ide`, `node-repl`); each builds into its own
  `<app>/dist/` (gitignored) — e.g. `apps/ide/dist/`.
- `examples/` — minimal standalone example app (`hello`).
- `test/node/` — WASM test/bench scripts, run against the built clone.
- `upstream.lock` — the pinned upstream commit the delta applies onto.
- `.work/` — the cloned tree + build artifacts (gitignored, disposable).

## Prerequisites

- An active **emsdk** (`source <emsdk>/emsdk_env.sh`).
- A native **threaded host Chez Scheme** (cross-compiler host) — or let the
  orchestrator build one.
- A same-version host **Racket** (the `raco setup` cross-server).

## Usage

```sh
racket build/main.rkt sync          # clone/fast-forward upstream to the pin
racket build/main.rkt apply         # apply patches/ + overlay/ into the clone
racket build/main.rkt app apps/ide \
  --pkgs "draw-lib datalog pict-lib" --wasm-deps draw \
  --scheme <host-chez> --racket <host-racket>
racket build/main.rkt serve apps/ide/dist 8123   # COOP/COEP server -> http://127.0.0.1:8123/
```

## About `build-wasm.md`

[`build-wasm.md`](build-wasm.md) is an **AI-generated** running log of this
port: design decisions, build instructions, dependency recipes, and known
issues. It's the record of what actually got Racket building and running on
WASM, and it's genuinely useful — but take it **with a grain of salt**,
especially anywhere it claims an approach is *necessary*. In many cases that's
just the path that happened to work, not the only one.
