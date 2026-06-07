# Claude operating notes for racket-wasm

This repo builds **Racket CS for WebAssembly** (Emscripten) as a *delta over
upstream Racket*, not a fork. A Racket orchestrator under `build/` clones
upstream at the commit pinned in `upstream.lock`, applies `patches/` (edits to
upstream files) and `overlay/` (additive files) into `.work/racket`, and drives
the cross-build, emitting a node runtime and a browser/IDE surface into `dist/`.

The substantive design documentation — architecture, build stages, dependency
recipes, known issues, and the rationale for every non-obvious decision — lives
in [`build-wasm.md`](build-wasm.md). Read it before doing anything in the build
area. It predates the repo split (it was written for the fork), so its `make
wasm` invocations map onto the orchestrator subcommands per the reading note at
its top.

## Repo structure

- `build/` — the orchestrator (Racket). `main.rkt` is the CLI; `config.rkt`
  holds the pin + defaults; `upstream.rkt` (`sync`), `patches.rkt` (`apply`),
  `toolchain.rkt`, `stages.rkt`, `pkgs.rkt`, `util.rkt` implement the rest.
  `extract-from-fork.rkt` regenerates `patches/`+`overlay/` from the fork.
- `patches/` — one `git diff` per modified upstream file, mirroring its path.
  Apply with `git apply` onto the pinned clone.
- `overlay/` — additive files copied verbatim into the clone (incl. `wasm-shell/`
  at the clone root).
- `upstream.lock` — pinned upstream URL + SHA the delta applies onto.
- `extract-manifest.rktd` — what the extractor classified as patch vs overlay
  vs skipped.
- `.work/` (gitignored) — the disposable clone + build artifacts.
- `dist/` (gitignored) — collected build outputs.

## Conventions

- **The clone is disposable.** Never commit into `.work/racket`. `sync` hard-
  resets it to the pin; `apply` re-lays the delta idempotently (it restores the
  patched tracked files and re-copies overlay, without git-cleaning the build
  artifacts).
- **Patches mirror upstream paths** under `patches/`. To change the delta, edit
  the file in a fork checkout and re-run `build/extract-from-fork.rkt`, or hand-
  edit the `.patch` (keep it `git apply`-able onto the pin).
- **`setup-core.rkt`'s `make-docs-step` no-op was committed by accident** in the
  fork and is deliberately **excluded** from `patches/`. Do not reintroduce it;
  doc suppression on the cross path is handled by `lib.zuo`'s `--no-docs` and
  `main.zuo`'s `--no-pkg-deps`.
- **`scheme-version.zuo`'s hex-parse fix is a real, platform-independent bug
  fix** — keep it; it's a candidate to upstream.

## Keep `build-wasm.md` current

Any non-trivial decision made in a session (a new dep recipe, a build-system
workaround, a known limitation future work must respect, a why-X-over-Y
rationale) belongs in `build-wasm.md` near the relevant section — it is the
project's durable memory. When a change touches the **delta** (a new patch, a new
overlay file, a changed pin), also re-run the extractor or update the patch and
note it.

## Prerequisites for a real build

- Source the **emsdk** first (`source <emsdk>/emsdk_env.sh`) — the orchestrator
  checks for `emcc`/`emconfigure` and refuses to build without them.
- A native **threaded host Chez** (`--scheme`, else one is bootstrapped in the
  clone) and a same-version host **Racket** (`--racket`).

## Bumping the pin

Edit `upstream.lock`'s `sha`, then `racket build/main.rkt sync` and
`apply --check`. If a patch fails `--check`, that line pinpoints exactly which
upstream file moved; regenerate that patch against the new pin.
