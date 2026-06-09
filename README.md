# racket-wasm

A standalone build of **Racket CS for WebAssembly** (Emscripten), expressed as a
*delta* over upstream Racket rather than a fork. The orchestrator clones upstream
at a pinned commit (`upstream.lock`), applies a small set of source patches
(`patches/`) and additive files (`overlay/`), and drives the cross-build end to
end, emitting a node runtime (`scheme.{js,wasm,data}`) and a browser/IDE surface
(`scheme-web.*` + `index.html`).

The architecture, build stages, dependency recipes, and known issues are
documented in [`build-wasm.md`](build-wasm.md). Read it before working in here.

## Layout

- `build/` — the Racket orchestrator (`racket build/main.rkt <subcommand>`).
- `patches/` — one diff per modified upstream file, applied to the clone.
- `overlay/` — additive files copied into the clone (and `wasm-shell/` at its root).
- `upstream.lock` — the pinned upstream commit the delta applies onto.
- `.work/` — the cloned tree + build artifacts (gitignored, disposable).
- `dist/` — collected build outputs (gitignored).

## Prerequisites

- An active **emsdk** (`source <emsdk>/emsdk_env.sh`).
- A native **threaded host Chez Scheme** (cross-compiler host) — or let the
  orchestrator build one.
- A same-version host **Racket** (the `raco setup` cross-server).

## Usage

```sh
racket build/main.rkt sync          # clone/fast-forward upstream to the pin
racket build/main.rkt apply         # apply patches/ + overlay/ into the clone
racket build/main.rkt build \
  --pkgs "draw-lib datalog pict-lib" --wasm-deps draw \
  --scheme <host-chez> --racket <host-racket>
racket build/main.rkt serve dist 8123   # COOP/COEP server -> http://127.0.0.1:8123/
```
