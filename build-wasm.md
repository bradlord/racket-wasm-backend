# Building Racket for WebAssembly (Emscripten)

> **Reading note for the `racket-wasm` standalone repo.** This document was
> written when the port lived as a *fork* of Racket, so its stage descriptions
> and `make wasm` invocations are phrased against an in-tree checkout. In this
> repo the port is a **delta over upstream**: a Racket orchestrator
> (`build/main.rkt`) clones upstream at the pin in `upstream.lock`, applies
> `patches/` + `overlay/` into `.work/racket`, then runs the same in-tree
> `make wasm` flow this doc describes. The mapping:
>
> | this doc says | in this repo |
> |---|---|
> | edit/checkout the Racket tree | `racket build/main.rkt sync apply` (-> `.work/racket`) |
> | `make wasm SCHEME=.. RACKET=.. PKGS=.. WASM_DEPS=..` | `racket build/main.rkt build [--scheme ..] [--racket ..] [--pkgs ..] [--wasm-deps ..]` |
> | serve the output dir | `racket build/main.rkt serve <dir> [port]` (e.g. `dist`) |
>
> Everything below — architecture, stages, dep recipes, traps — is unchanged and
> remains the source of truth for *how* the build works; only the entry point
> moved. The patch/overlay split is recorded in `extract-manifest.rktd`.

This document describes the in-progress port of Racket CS to WebAssembly,
running under Emscripten. The pipeline reaches the point where Chez
Scheme + libffi + a statically linked `librktio` + a tpb32l-compiled
`racket.boot` boot together, execute libffi calls into rktio
successfully, and reach Racket's own startup code. A dedicated
Emscripten entry point (`racket/src/cs/c/main_em.c`) now populates the
`racket_boot_arguments_t` struct that `racket/src/cs/c/boot.c` expects
and calls `racket_boot`, replacing Chez's default `main.c` in the WASM
link line.

## Status

> ⚠️ **Places are disabled on WASM (single-threaded).** Even though the build is
> `tpb32l` (a *threaded* Chez machine type, so `threaded?` is true), **real
> places do not work** and are deliberately turned off. A place forks a Chez
> thread, which on WASM is a new pthread (an emscripten Worker); the **first
> foreign call inside that pthread traps** — as a `function signature mismatch`
> in the pb interpreter, or a `__wasmfs_jsimpl_write` `TypeError` — because
> per-Worker JS-side state (WASMFS backends, the libffi closure function-table)
> is **not** shared across emscripten Workers; only the wasm linear memory is.
> This is what crashed DrRacket on startup (it spawns a place for online
> expansion / background check-syntax); the original `chunk_15941`
> `function signature mismatch` was **mis-attributed to `call-with-c-return`** —
> the real culprit is the place pthread. The fix: `patches/racket/src/cs/rumble/
> place.ss.patch` makes `place-enabled?` return `#f` on `tpb32l`, so
> `racket/place` transparently falls back to its in-process thread emulation
> (`racket/place/private/th-place`), exactly as a `--disable-places` build. If
> you ever want real parallelism on WASM you must solve per-Worker JS state
> sharing first — do **not** just flip `place-enabled?` back on. Minimal repro
> (no rebuild): `node test/browser/tools/place-crash-cdp.mjs` spawns a trivial
> `dynamic-place` and captures the trap from the nested pthread Worker.

Working:

- Chez Scheme builds for WebAssembly via the upstream `--emscripten`
  configure path (basic pb).
- First-class continuations work under Chez pb on WASM (the pb
  interpreter manages its own Scheme stack independent of the WASM
  call stack).
- `librktio` cross-compiles cleanly to WASM via Emscripten with a
  small `__EMSCRIPTEN__` platform branch (committed earlier; see
  `racket/src/rktio/rktio_platform.h`).
- libffi 3.5.2 cross-compiles to WASM (`emconfigure ../configure
  --host=wasm32-unknown-emscripten ...`) and links into Chez's
  `--enable-libffi` build.
- A custom `racket.boot` compiled for the **tpb32l** machine type
  (`uptr = uint32_t`, matching WASM32's pointer width) loads into Chez
  Emscripten correctly. Racket's `io` layer initializes, calls
  `rktio_init` through libffi, and successfully invokes follow-on
  rktio operations on the result.
- The pb interpreter's `pb_call_*` instructions on tpb32l do
  `call_indirect` with the same WASM signatures as the C library's
  actually-compiled functions, so the `null function or function
  signature mismatch` class that plagues a basic-pb (`uptr =
  uint64_t`) build does not occur.

Done:

- Chez Scheme's default `main.c` calls `Sbuild_heap` and then enters
  the standard Scheme REPL. Racket's `racket.boot` instead expects to
  be entered through `racket_boot(racket_boot_arguments_t *)` (see
  `racket/src/cs/c/boot.c`), which needs `exec-file`, `run-file`,
  `collects-dir`, `etc-dir`, `k-file`, `segment-offset`,
  `embedded-interactive-mode?`, `is-gui?` and a handful of other
  bindings set before `racket.boot` runs its startup. Loaded under
  Chez's default startup these are unset and `racket.boot` aborts with
  the `expected ... to start` error.
- The Emscripten boot harness `racket/src/cs/c/main_em.c` now exists.
  Rather than mirroring the native `main.c` (which does Windows DLL
  injection, OS X frameworks, ELF section probing, and embedded
  boot-file offset discovery — none of it relevant under Emscripten),
  it is a self-contained ~80-line entry point that `memset`s the
  struct, points the three boot files at their preloaded MEMFS paths
  (`/petite.boot`, `/scheme.boot`, `/racket.boot`, all with
  `offset = 0`, `len = 0` for "read whole file"), passes `argv`
  through (stripping `argv[0]` per the struct's convention), sets
  `exec_file`/`run_file`/`k_file` to `argv[0]` (or `"racket"`), and
  calls `racket_boot`.

- pbchunk is wired into the WASM link (§5): all three boot images are
  used in their chunked form (`*-pbchunk.boot`) and the 30 generated
  chunk C files are recompiled with emcc and linked, with `boot.c`
  built `-DPBCHUNK_REGISTER`. This replaces interpreted boot bytecode
  with compiled C and **dropped boot from ~5 minutes to ~2 seconds**
  under `node racket.js`. The cost is binary size: `racket.wasm` grows
  ~1 MB → ~26 MB and `racket.data` ~47 MB → ~87 MB (irrelevant for the
  node CLI; matters more for the browser shell's download).
- Verified end-to-end through Racket: `(+ 4 2)` → `6`, a `for/sum`
  loop, and `(require racket/list)` (collection load from `/collects`)
  all evaluate correctly in ~2 s.
- `boot.c` has `RACKET_BOOT_TIMING`-gated `[boot-timing]` checkpoints
  to measure boot phases (native builds; see §6 for the node caveat).

Open:

- `main_em.c` now expects a `/collects` tree and `/etc` directory to
  be preloaded into MEMFS. It also sets `cs_compiled_subdir = 1` so
  the WASM runtime looks in a machine-specific `compiled` subdirectory
  instead of accidentally loading host-native fasls from plain
  `compiled/`.
- `main_em.c`'s `ba.collects_dir` MUST be **double-NUL-terminated**
  (`"/collects\0"`). `boot.c:parse_coldirs` treats it as a NUL-separated
  *list* terminated by a second NUL (mirroring `start/config.inc`'s
  `scheme_coldir = INITIAL_COLLECTS_DIRECTORY "\0\0"`); a plain
  `"/collects"` literal makes it read the byte past the path's own
  terminator out of bounds into adjacent rodata, and when nonzero it
  walks the C string-constant pool (cairo PostScript/SVG templates, glib
  paths, PS font keys) as bogus collection dirs — polluting
  `(current-library-collection-paths)` with 190+ garbage entries (count
  varies run-to-run; surfaces in any "collection not found" error's
  search-path dump). `config_dir` is a plain single string and needs no
  terminator. Fixed 2026-06-11; requires a runtime rebuild to take effect.
- **TCP/DNS hung instead of erroring** (`tcp-listen`, `tcp-connect`, any
  hostname lookup) — **fixed by `C1` alone.** The bug: rktio runs
  `getaddrinfo` on a background **pthread** and the calling Racket thread
  blocks polling a pipe the worker writes when done. The WASM runtime is
  single-threaded (Chez pb on the main thread), so on Emscripten the worker
  can't make progress while the main thread is blocked (it must yield to the
  JS event loop for the worker to be created and for its main-thread-proxied
  calls to complete) → unbreakable deadlock. rktio has **five** such
  helper-thread sites (`getaddrinfo`, the SIGCHLD signal worker in
  `rktio_process.c`, the background-sleep thread in `rktio_sleep.c`, the
  pending-`open` thread in `rktio_file.c`) — all transitively gated by
  `RKTIO_USE_PTHREADS` (`rktio_private.h` derives `SUPPORT_BACKGROUND_SLEEP_THREAD`
  and `RKTIO_USE_PENDING_OPEN` from it).

  **C1 — disable rktio's own pthreads (keep `tpb32l`).** `setup-rktio`
  (`lib.zuo`) appends `--disable-pthread` to the rktio sub-configure args when
  `EMSCRIPTEN=t` (last wins over the CS-propagated `--enable-pthread`), so
  `RKTIO_USE_PTHREADS` is **undefined** for the wasm `librktio` only. That
  collapses all five thread-spawn sites to their synchronous fallbacks at once
  — `getaddrinfo` then runs inline and the real Emscripten shim returns a
  resolution error immediately (it does *not* block), so `tcp-listen` /
  `tcp-connect` raise a clean `exn:fail:network` ("address-resolution error …
  gai_err=-2"). Safe because rktio's pthread locks (`ghbn_lock`,
  `child_status_lock`) exist for thread-safety under concurrent callers
  (multiple Racket *places*), and single-threaded WASM never has any.

  Delta: `patches/racket/src/lib.zuo.patch` (one flag, no rktio source
  patches). **Verified post-rebuild on both surfaces** (fresh `dist/`):
  node + browser `tcp-listen` and `tcp-connect` (hostname and numeric) all
  raise `exn:fail:network` with no hang; `(+ 4 2)` and `(require racket/tcp)`
  fine on both. Requires a runtime rebuild (and a clean rktio dir, so
  `--disable-pthread` regenerates `rktio_config.h`).

  **`E` (a fail-fast `do_getaddrinfo → EAI_FAIL` under `__EMSCRIPTEN__`) was
  tried and found UNNECESSARY.** The hypothesis was that the *synchronous*
  Emscripten `getaddrinfo` shim would itself block in the `shell-worker`
  (worker) context even after C1 removed the helper thread. A clean C1-only
  rebuild (served from a fresh `dist/`) disproved it: the real shim returns
  `gai_err=-2` instantly for listen, hostname-connect, and numeric-connect on
  the browser. The earlier "browser needs E / the synchronous shim blocks"
  belief was a **stale-asset measurement artifact** (see testing gotcha
  below). E is not in the delta.

  **Correction to an earlier note in this repo's history:** `--disable-pthread`
  was at one point dismissed as "not viable, it would flip `tpb32l`→`pb32l`."
  That conflated *two* `enable_pthread` knobs. The CS-level one
  (`cs/c/configure`) does set `thread_prefix="t"` → the `tpb32l` machine type,
  and flipping *that* is the risky path (C2). But `RKTIO_USE_PTHREADS` is
  rktio's **own** independent flag (`rktio/configure.ac`), only *incidentally*
  forced to match CS by the propagation at `cs/c/configure:6326`. Overriding
  that for rktio alone (C1) disables rktio threading while Chez stays threaded
  — no machine-type change, no source patches per rktio file. The first fix
  here was a narrower `__EMSCRIPTEN__` guard on just the `getaddrinfo` thread
  in `rktio_network.c`; it was **incomplete** (left the other four sites live)
  and was superseded by C1.

  **Alternative considered and rejected — make pthreads actually work
  (`-sPROXY_TO_PTHREAD`).** Run Racket off the main thread so the real main
  thread services the proxy queue. A pre-warmed pool (`-sPTHREAD_POOL_SIZE`)
  alone is insufficient (worker creation is fixed but the helper's calls are
  still proxied to the blocked main thread; the runtime has ~56
  `proxyToMainThread` sites). PROXY+pool worked on **node** (threaded
  `getaddrinfo` completes, REPL intact, ~1.2 s boot) but its precondition
  ("relocate off *the* main thread") doesn't hold on the browser, which
  already runs Racket inside `shell-worker.js`. It's an asymmetric, node-only
  capability with real boot cost (an always-on proxy worker + N pooled
  workers), so it was not adopted *for the TCP/DNS fix*; C1+E is uniform across
  both surfaces.

  **Correction (later):** the "precondition doesn't hold on the browser" claim
  was wrong -- `-sPROXY_TO_PTHREAD` *does* work on the browser once
  `Module.mainScriptUrlOrBlob` points the pthread pool at `racket-web.js` (the
  `importScripts` host otherwise can't supply its own URL). It is now enabled on
  the browser link to fix the GLib **font** deadlock (a different deadlock than
  this TCP/DNS one, which C1 still handles). See "Browser text: the GLib thread
  deadlock and its fix".

  **Testing gotcha (cost real time):** `runtime-glue/serve.rkt` roots at
  `(current-directory)`, so it must be launched **from `dist/`** (`cd dist &&
  racket ../runtime-glue/serve.rkt 8123`). Launching it elsewhere, or leaving
  stale `serve.rkt` instances from earlier runs holding the port, silently
  serves an **old** `racket-web.*` — the headless Playwright harness then tests
  a stale runtime (tell them apart by the version-date in the boot banner, e.g.
  `…-2026-06-12-…`). Some earlier browser-only conclusions in this history
  (PROXY/guard "hangs on browser") were measured against such stale assets and
  are unreliable; the C1+E result above was confirmed against a freshly served
  `dist/` and by a manual browser run.
- The browser shell boots much more slowly than node and downloads the
  larger (~26 MB wasm + ~87 MB data) assets; worth profiling/trimming
  there (compression, streaming, lazy `/collects`).
- An Emscripten linear-memory prewarm snapshot (dump WASM memory after
  boot, restore to skip `Sbuild_heap`) remains the theoretical next
  ceiling — Chez's own `Ssave_heap`/`Sregister_heap_file` are disabled
  ("saved heap files are not presently supported"), so it would have to
  be done at the Emscripten memory level, with `boot.c:215`
  (`Sbuild_heap`) and the `scheme-start` call as snapshot boundaries.
  **Deprioritized**: at ~2 s, node boot is already fast enough that
  this is not worth the complexity for now.

## Prerequisites

- `emsdk` — install via `git clone https://github.com/emscripten-core/emsdk.git`,
  then `./emsdk install latest && ./emsdk activate latest`. The scripts
  below assume `source <emsdk>/emsdk_env.sh` makes `emcc`/`emconfigure`/`emmake`
  available.
- A native **host Chez Scheme** (the cross-compiler host for the boot and
  `racket.boot` stages). A full `make cs` produces one at
  `racket/src/build/cs/c/ChezScheme/<mach>/...`, but it is no longer
  required: `make wasm` bootstraps a native threaded Chez under
  `racket/src/ChezScheme/<mach>/` via the committed pb boot files when
  none is present. See stage 0 below.
- A **full Racket** for the cross-root collections stage (it runs
  `raco`/`raco-cross`). This is the one piece `make wasm` does not build
  itself: it uses `racket/bin/racket` if present, otherwise pass
  `RACKET=<path>` (`make wasm RACKET=/path/to/racket`). A `make cs` build
  provides `racket/bin/racket`.
- libffi source tarball (release 3.5.x). 3.5.2 is known to work; older
  3.4.x versions use deprecated Emscripten JS-library names
  (`generateFuncType`, `uleb128Encode`) that newer emsdk renames.

## Build sequence

The full pipeline is six stages. All paths below are relative to the
repository root. The work directories that get created live under
`racket/src/` and are gitignored.

### Integrated entry point: `make wasm`

The build is wired into the stock build system as a target:

```sh
source <emsdk>/emsdk_env.sh
make wasm SCHEME=<native-threaded-host-scheme> RACKET=<host-racket> \
     RUNTIME_GLUE_DIR=<racket-wasm>/runtime-glue \
     WASM_DEPS_SRC_DIR=<racket-wasm>/wasm-deps
```

(The two `*_DIR` vars point at racket-wasm's repo-side link glue and
native-dep recipes; the orchestrator sets them automatically.)

`make wasm` runs `main.zuo`'s `wasm` target, which calls `build-base
"cs/c"` in a `wasm?` mode: it injects the cross-configure flags
(`--enable-pb --enable-mach=tpb32l --enable-crossany
--host=wasm32-unknown-emscripten`), defaults `CONFIGURE_WRAPPER` to
`emconfigure`, forces `CROSS_MODE=cross`, runs the CS `build` (configure
+ cross-build the tpb32l kernel, rktio, boot images, pbchunk), then runs
`wasm-setup` (cross `raco pkg install` + `raco setup`, compiling
collections to `compiled/tpb32l`), and finishes at the `wasm` emcc-link
target in `racket/src/cs/c/build.zuo`.

That link target emits **both** runtime surfaces into
`racket/src/build/cs/c/wasm/`, with the target `.zo` packaged in:

- the **node** REPL -- `racket.{js,wasm,data}` (run with
  `echo '(+ 1 2)' | node racket.js`); and
- the **browser** runtime -- `racket-web.{js,wasm,data}` (adds the
  browser-only `wasm_shell_io.o`, the SAB/DOM exports, WASMFS + an
  OPFS-backed `/home/web_user`, and the `wasmfs-stdin.js` (`--js-library`)
  / `wasmfs-console.js` (`--js-library`) console glue).

**The link emits only the runtime, not the page.** As of the
runtime/surface decoupling (project roadmap Phase 0), the `wasm` target no
longer stages any page assets next to the binary. The host-side glue
(`shell-worker.js`, the COOP/COEP dev server `serve.rkt`) and the page
**surface** (`index.html`/`ide.js`, the DrRacket-like IDE) live **repo-side**, not
in the clone -- under `runtime-glue/` and `apps/ide/public/` respectively -- and
the orchestrator's `collect-outputs` (`build/stages.rkt`) copies them into
`dist/` alongside the runtime. This is the seam that lets a different surface
ship against the same runtime binary without re-linking; see the project
roadmap.

**Surface selection (`target`).** Although the one `wasm` make target always
builds *both* surfaces (so the runtime cache stores the union), an app declares
which one it ships via its manifest's `'target` field -- `'browser` (default) or
`'node`. `collect-outputs` copies only that subset into `dist/`: a browser app
gets `racket-web.{js,wasm,data}` + the separate package payload
`share.data`/`share.data.js` + the worker glue `shell-worker.js`; a node app gets
`racket.{js,wasm,data}` only (packages are baked into `racket.data`, and it needs
no browser glue). `target` is *not* part of the build-key -- it only filters the
copy, so a browser and a node app with the same `pkgs`/`wasm-libs` share one
cache entry. `serve.rkt` is repo-side glue and is **not** copied into `dist/`;
run it in place against the output dir: `racket runtime-glue/serve.rkt 8123`
(sets the COOP/COEP headers `SharedArrayBuffer` needs), or use
`racket build/main.rkt serve <dir> [port]`, then open `/` (the surface's entry
page is `index.html`).

The browser-link flags live in the `wasm` target itself. (The legacy
`install-wasm-browser-shell.rkt` staging script, which predated the decoupled
path and listed the old in-clone asset names, has been dropped from the delta.)

#### Building a custom app (`make-wasm-racket` / the `app` subcommand)

Because the runtime is surface-agnostic, a *custom* web app is just "the shared
runtime + glue, plus a different page surface, into a different output dir."
`build/app.rkt` exposes that as `make-wasm-racket`:

```racket
(make-wasm-racket #:dest "out"
                  #:pkgs '(draw-lib)      ; -> PKGS  ('() = core only)
                  #:wasm-libs '(draw)     ; -> WASM_DEPS ('() = libffi only)
                  #:public "app/public")  ; the page surface (html/js/rkt)
```

It wraps `build-runtime` (`build/stages.rkt`), differing only in the output
`dest` and the page `surface-dir`. An app dir carries an `app.rkt` manifest that
`(provide app)` a hash of those fields
(`'pkgs 'wasm-libs 'public 'local-pkgs 'target`, plus optional `'pre-js`/
`'post-js`/`'extern-pre-js` and `'hooks`, below);
`read-app-manifest` normalizes it and `run-app-manifest` builds it.
`racket build/main.rkt app <dir>` builds into `<dir>/dist` (override `--dest`).
`examples/hello/` is the minimal example: a non-IDE page that seeds a `main.rkt`
into MEMFS, runs it (`argv ["-u" "/tmp/main.rkt"]`), and drains its stdout from
the output ring -- the smallest counterpart to `ide.js`. `apps/node-repl/` is the
node-target counterpart: a manifest-only app (`'target 'node`, no page surface)
whose `dist/` is `racket.{js,wasm,data}`, run directly as a Racket REPL with
`node apps/node-repl/dist/racket.js`.

**The IDE is just an app (dogfood).** There is no bespoke IDE build:
`racket build/main.rkt build` builds **`apps/ide`** through this same path
(`cmd-build` -> `run-app-manifest ide-app-dir` -> `make-wasm-racket`). The IDE's
package / native-dep / surface config lives in `apps/ide/app.rkt` (the single
source of truth -- `build/config.rkt` no longer hardcodes a default package
set), and its page is `apps/ide/public/index.html` plus a `dist/ide.js` generated
by a post-build hook from `apps/ide/ide.js` + `apps/ide/examples/` (see below). To ship a different
surface or dep set, write an app and `build` it -- the IDE has no privileged path.

**Local app packages (`#:local-pkgs`).** Catalog packages come from `#:pkgs`
(by name); an app's own packages are passed as **source dirs** in
`#:local-pkgs` and installed into `share/pkgs` via `raco pkg install --copy`,
so app code can live anywhere -- the clone stays pure upstream-delta. The
orchestrator threads them as the `LOCAL_PKGS` make var into `main.zuo`'s
`install-base-pkgs`, which (per package) `update --copy`s an already-present one
or `install --copy`s a new one (neither `raco` verb is idempotent on its own).
A `--link` from an outside path would record an absolute *host* path in
`links.rktd` that doesn't exist in MEMFS, which is why local packages must be
**copied** into `share/pkgs` (where the wholesale wasm preload picks them up).
Their contents feed the build-key, so editing a local package rebuilds.

The repo's own `web-repl` helper package is itself a `#:local-pkgs` entry now:
it lives at `packages/web-repl` (no longer `overlay-local/`, no longer in the
clone), and the default IDE build ships it via `default-local-pkgs`
(`build/config.rkt`). The clone-free consume keeps it on the `--copy` (source)
path -- only catalog packages are stripped into the binary catalog.

**App-supplied link JS (`#:pre-js` / `#:post-js` / `#:extern-pre-js`).** An app
can contribute its own JS to the emcc link via the manifest fields `'pre-js`,
`'post-js`, `'extern-pre-js` (each a list of app-relative `.js` paths, a bare
string accepted as one). `read-app-manifest` resolves them to absolute paths;
`make-wasm-racket` threads them through `build-runtime`, which passes them to
`make-wasm` as the space-joined `LINK_PRE_JS` / `LINK_POST_JS` /
`LINK_EXTERN_PRE_JS` make vars (plus `APP_TARGET`). The `Makefile`'s `BUILD_VARS`
forwards them to the `zuo . wasm` invocation, `main.zuo` propagates them into the
`cs/c` sub-build's vars, and the `wasm` link target in
`racket/src/cs/c/build.zuo` shell-splits each and appends `--pre-js <path>` (etc.)
**after** its own built-in glue (`node-tty.js`/`wasmfs-console.js`, the
`node-locate-file.js` extern-pre-js), so an app's JS runs after — and can override
— the runtime's. The JS lands in the app's **target surface only** (a node app's
JS in `racket.*`, a browser app's in `racket-web.*`); the one `wasm` target still
builds both surfaces, `APP_TARGET` just selects which link gets the JS. Because
the JS changes the linked binary, its **contents feed the build-key** (so editing
a pre-js file relinks), together with the target — meaning an app *with* link JS
keys separately per surface, while link-JS-free apps key exactly as before and a
node/browser pair still shares one cache entry. Like `LOCAL_PKGS`, the paths pass
through a make var that is shell-split downstream, so they must not contain spaces.

**Build hooks (`'hooks`).** The manifest may carry a `'hooks` field: a hash
mapping a hook-name symbol to a procedure the build calls at that point. The only
point so far is **`'post-build`**, called by `run-app-manifest` *after*
`make-wasm-racket` returns — i.e. once `dist/` is fully assembled (binaries +
glue + the verbatim `public/` copy + payload). The hook receives a context hash
`(hash 'dist <dist-dir> 'app-dir <app-dir> 'target 'browser|'node)` and is free to
generate or transform files in `dist/`. It runs on **every** build, outside the
runtime cache, so it always re-fires even on a cache hit (handy for codegen whose
inputs aren't part of the build-key). `read-app-manifest` validates `'hooks` is a
hash of procedures; the hash is named generically so more hook points can be added
without reshaping the manifest. The field is ignored by `package`/`cross-sdk`
(they assemble no surface). **The IDE uses this** (`apps/ide/build-examples.rkt`,
wired in `apps/ide/app.rkt`): its example programs live one-per-file under
`apps/ide/examples/` (`NN-name.rkt`/`.rhm` — the `NN-` prefix orders them and,
stripped along with the extension and with dashes→spaces, names the dropdown
entry), and the page driver source lives at `apps/ide/ide.js` with an
`__EXAMPLES__` placeholder token. Both sit *outside* `public/` so
`collect-outputs` doesn't ship them verbatim; the hook reads the examples, builds
the `[{name, code}, …]` JSON, splices it in place of the token, and writes
`dist/ide.js`.

#### Runtime cache (build isolation)

The runtime binary + package payload are fully determined by the **pinned
upstream SHA**, a **hash of the delta** (`patches/` + `overlay/` +
`overlay-local/`), the native-dep selection (**`WASM_DEPS`**), the package
set (**`PKGS`**), the **local packages** (`#:local-pkgs`, hashed by content),
and — when an app supplies emcc link JS — that **JS's contents plus the surface
it targets** -- *not* by the page surface. `build/cache.rkt` hashes those
into a short **build-key** and caches the runtime set (`runtime-output-names`)
under `.work/runtime-cache/<key>/`. (The link-JS component is omitted entirely
when an app has none, so keys for link-JS-free apps are byte-identical to before
the field existed.) `build-runtime` (`build/stages.rkt`) checks it first:

- **cache hit** -- a config built before is reassembled by *copying from the
  cache*: no `make`, no relink, and no mutation of the shared clone. Two apps
  with different configs therefore get separate cache entries and never clobber
  each other in the one clone -- the "build isolation" the roadmap calls for.
- **cache miss** -- a normal `make wasm` into the clone, then the runtime set is
  snapshotted into the cache for next time.

Only the heavy runtime set is cached; glue (`runtime-glue/`) and the page surface
(an app's `public/`) are repo-side and copied fresh on every
assemble, so editing a surface or `serve.rkt` is picked up immediately and never
invalidates the cache. Editing the delta (any patch/overlay file) *does* change
the build-key, so the cache self-invalidates. `--force` (CLI) / `#:force?`
(`make-wasm-racket`) bypasses the cache and forces a real build. Entries are
large (~100 MB each); they live under the disposable `.work/`.

##### Package-blank runtime/SDK; packages via the clone-free consume

`build-runtime` keeps the runtime in **three independently cached layers**. Only
the base needs the clone+emsdk; the app's packages are added **clone-free** by
cross-installing them against a pure SDK (the same path an external consumer uses
-- the full dogfood). The two clone-bound make targets -- `wasm` and
`wasm-cross-sdk` -- are **always `PKGS=`/`LOCAL_PKGS=`** (package-agnostic):

- **Base runtime** (`ensure-base-runtime!`, clone+emsdk) -- `make wasm` with
  `PKGS=`, then `pack-packages` packs the package-agnostic **base `share.data`**
  (the clone's core tree, emsdk-free). The browser link bakes only boot images +
  collects into `racket-web.data`; packages are never in the link (they're the
  separate `share.data`, see "Packages as a separate data file"). Binaries + base
  `share.data` cache together under **base-key** (omits `pkgs`/`local-pkgs`) -- one
  emcc link + one base pack, reused by every app on the same (delta, `wasm-deps`,
  link-JS, target). Needs the emsdk on a miss.
- **Pure SDK** (`ensure-sdk!`, clone, emsdk-free) -- `build-cross-sdk` runs `make
  wasm-cross-sdk` `PKGS=` + `package-cross-sdk` to emit the `cross-sdk` artifact
  (retarget files + `tpb32l` cross-root + the in-tree `pkgs/`). Keyed by **(delta,
  `wasm-deps`)** -- one SDK serves every app on that native-dep profile. Needs a
  **warm clone** (the cross-sdk can't cold-bootstrap), which the preceding base
  build provides.
- **App payload** (`ensure-app-payload!` -> `cross-install`, **clone-free,
  emsdk-free**) -- the only place the app's `pkgs`/`local-pkgs` flow. It
  cross-compiles them to `tpb32l` against the SDK **via a built-package catalog**
  (next paragraph) and folds their bytecode into the base `share.data`
  (`extend-data-package!`), writing the extended `share.data`/`share.data.js` into
  `work-dir/app-payload-cache/<pkg-key>/`. `build-runtime` copies that over dist's
  base `share.data`. With **no** app packages, the base `share.data`
  collect-outputs already shipped is final.

The consume (`build/consume.rkt`) is a **two-pass, catalog-mediated** install,
both passes running `raco pkg install` under a custom `-G` config whose
`pkgs-dir`/`links-file`/`lib-dir` point at the SDK cross-root (so the **base
package set registers as installed** and only the app's delta is fetched +
compiled) while `collects` stays on the host racket (host-form expansion). It is
host-safe by construction: `PLTADDONDIR` confines new packages to a throwaway
addon, and `-MCR <hostzo>:<xtgt>` (no in-place root) keeps every `.zo` out of the
host trees. `lib-dir`'s `system.rktd` makes the cross target `tpb32l`.

1. **Stage + catalog** (`refresh-pkg-catalog!`) -- stage-install the catalog
   `pkgs` (+ their non-base closure) from the network into a **persistent,
   SDK-keyed** tree (`work-dir/pkg-catalog/<sdk-key>/`) in three steps so any
   repo-side source patch lands *before* compilation: **(a) fetch** with
   `--no-setup` (resolves + registers the closure, no compile); **(b) patch** the
   staged source (`apply-pkg-patches!`, see "Text / Pango"); **(c) compile** the
   *whole* staged closure in one dependency-ordered cross `raco setup`
   (`setup-pkgs!`). Compiling everything in one pass (rather than the old
   install-all-then-recompile-just-the-patched-packages) ensures **dependents are
   built against the patched source**, not the unpatched version. Then harvest
   the `tpb32l` `.zo` in place, then re-emit each package through `pkg/strip`
   (`generate-stripped-directory`) into `build-catalog/pkgs/` and (re)build a
   `pkg/dirs-catalog` index over it -- the strip + index run as a **cross
   subprocess** (`build/strip-catalog.rkt`, see below). The catalog **accumulates**
   (`--skip-installed`
   -> incremental) and is keyed by the SDK because its `tpb32l` `.zo` depend on
   the delta + `wasm-deps`. The strip `STRIP-MODE` is the size knob: `'built`
   keeps source (a pure copy that never reads a `.zo` -- host-safe), `'binary-lib`
   drops source/docs (`.zo`-only). See "Binary-only packages via the catalog".
2. **Final consume** (`cross-install`) -- install the app's `pkgs` **from the
   local built catalog** (`catalogs (<file://build-catalog> #f)`) into a fresh
   addon, selecting just this app's closure out of the (possibly multi-app)
   catalog; `local-pkgs` install by `--copy` (they stay source -- they're tiny and
   you may be editing them). Harvest the `tpb32l` delta, verify each requested
   package produced a `.zo`, merge `/share/links.rktd`, and `extend-data-package!`.

Both passes keep their hostzo/xtgt compile shadows (staging's under the catalog
dir, the final pass's under `consume-work-cache`, both per-SDK) so repeats only
compile what's new.

The upshot: **a package change is a base + SDK cache hit + an emsdk-free
`cross-install`** -- a full `build` of a package change runs with the emsdk
entirely off `PATH` and **no clone mutation**. Native deps (`wasm-libs`, e.g. the
cairo/pango stack `draw` links) stay in the base build (linked *into* the wasm
binary, can't be layered on). Both surfaces consume the same surface-independent
`share.data` payload: the browser loads it via `importScripts` (shell-worker.js),
node via `node-load-share.js`'s indirect-eval (a `--pre-js` on the node link). So a
package change is an emsdk-free `cross-install` for node too -- the node
`racket.data` carries only the core (`/collects` + boot), never the app packages.

> First-consume cost: with an empty catalog + compile shadows, the staging pass
> regenerates the host-form + target bytecode of the new packages' dependency
> closure (draw/pict are sizable). The accumulating catalog + per-SDK shadows make
> subsequent consumes incremental. A lean SDK that pre-ships those shadows is a
> follow-on (the SDK ships sources, not shadows, today).

#### Build metadata + distributable binary packages

Every assembled output -- an app build's `dist/`, a runtime cache entry, and a
distributable package -- carries a **`racket-wasm.build.rktd`** sidecar (an
S-expression `hash`, `build/metadata.rkt`). It records the **`build-key`** and,
under `'components`, the *inputs* that produced it: `upstream-sha`/`upstream-url`,
`delta-hash`, `wasm-deps`, `pkgs`, `local-pkgs` (each `(basename . content-hash)`),
the surface-tagged `link-js` component (or `#f`), and `target`. It also records
the build's `racket-version` -- **informational provenance only, deliberately
*not* part of the key** (the key is the delta + dep set; host == target version
per this doc's `RACKET=` rule). `build/cache.rkt` is the single source of truth:
`build-key-components` builds the components hash, `key-from-components` hashes it
into the key (the exact historical join, so existing cache entries stay valid),
and `build-key` composes the two.

A **distributable binary package** is just a directory of the full runtime set
(`runtime-output-names`, *both* surfaces) plus that metadata file -- a portable
cache entry. `racket build/main.rkt package [<app-dir>]` builds (or reuses the
cache for) the app's config and emits `<app-dir>/package/` (override `--dest`)
plus a sibling **`.tar.gz`**. Because a package is keyed by the same components,
it is config-specific (and, for a link-JS app, surface-specific via that
component), but it always ships the union of surfaces so either `target` can
consume it.

**Consuming a package (`--runtime <pkg-dir>`).** `racket build/main.rkt app
<dir> --runtime <pkg-dir>` (also on `build`) assembles the app's surface against
a prebuilt package **with no clone, no `make`, no emsdk** -- the
"`build`-without-the-Racket-source" path. `build-runtime` (`build/stages.rkt`)
takes a separate branch (`assemble-from-package`) that recomputes the app's
*expected* `build-key` from the local repo + manifest (all the inputs live here,
not in the upstream clone) and compares it to the package's recorded key. A
**mismatch errors**, reporting which components differ (e.g. `pkgs: app expects
… / package has …`); `--force` downgrades that to a warning and assembles anyway.
The resulting `dist/` records the *package's* provenance (it describes the actual
binaries shipped). The `target` filter still selects which surface subset is
copied, and the package must contain that surface's files.

#### Licenses bundle

Every `dist/`, distributable package, and cross-SDK ships a **`licenses/`** tree
so the distribution is license-compliant. `build/licenses.rkt`
(`assemble-licenses!`) builds it; the grouped-by-origin layout is:

- `README.txt` -- the umbrella notice (`config.rkt` `license-readme-text`):
  this project is dual MIT/Apache 2.0, the bundled components carry their own
  licenses, all included here.
- `racket-wasm-MIT.txt` -- this repo's `LICENSE-MIT.txt`.
- `racket-wasm-APACHE.txt` -- this repo's `LICENSE-APACHE.txt`.
- `racket/` -- upstream Racket's `LICENSE*.txt` set (Apache/MIT/LGPL/GPL/
  libscheme), globbed from `<clone>/racket/src`.
- `deps/<name>/` -- one subdir per built native dep, holding its license file(s).
- `licenses.html` -- a browsable index: the umbrella notice followed by relative
  links to every collected file, grouped into *This project* / *Racket* /
  *Dependencies* (per dep). Written last so it links the final tree.

**Discovery is clone-driven and cache-keyed.** All texts except the repo licenses live
in the disposable clone (`<clone>/racket/src` + the extracted dep sources), which
exists only on a build **miss**. So `assemble-licenses!` runs in
`ensure-base-runtime!` (writing the tree into the **base cache**, keyed by
`wasm-deps`+delta -- exactly what the dep license set depends on) and in
`package-cross-sdk` (writing into the SDK). `collect-outputs` / `build-package` /
`assemble-from-package` then **copy** the prebuilt `licenses/` tree from the
cache (or the consumed package) into `dist/` -- they never regenerate it, so it
survives cache hits and the clone-free `--runtime` path. `cache-complete?` takes
`#:require-licenses?` (the base layer passes `#t`) so a cache entry predating
license collection is rebuilt once.

**Deps are found by scanning** `<clone>/racket/src` for `build-<name>-em` dirs --
exactly the wasm-deps recipes that ran (libffi always + whatever `WASM_DEPS` /
the `draw` alias selected), so no knowledge of the dep-set string or the bash
alias is needed. rktio is in-tree (no `build-*-em` dir) and covered by Racket's
own license, so it's correctly excluded. Within each dep's `src/`, license files
are located by a **filename glob** (`license`/`licence`/`copying`/`copyright`/
`notice`/`ftl`/`gpl`, case-insensitive) over the root, with a small
**override table** for deps whose texts sit in subdirs or a whole SPDX dir
(`freetype`: `docs/FTL.TXT` + `docs/GPLv2.TXT`; `glib`: `COPYING` + the
`LICENSES/` SPDX dir). An override path naming a **file** is flattened to
`<dep>/<basename>`; one naming a **directory** is copied as a tree, keeping its
structure (e.g. `glib/LICENSES/*.txt`). To support a new dep whose license the
glob misses, add an override entry naming its file(s)/dir(s) relative to the dep
source root; a dep that yields no license file logs a non-fatal warning. **Deferred:** the
licenses of packages installed into `share.data` are not yet collected.

#### Cross-compiler SDK (custom packages without the clone)

The runtime binary package lets you *assemble an app* without the clone. To
cross-compile **new** `raco` packages for `tpb32l` you also need a
**cross-compiler SDK** -- shipped as a **separate** artifact (not bundled into
the runtime package). `racket build/main.rkt cross-sdk [<app-dir>]` builds it
into `<app-dir>/cross-sdk/` (override `--dest`) plus a sibling `.tar.gz`.

The crucial property: **the cross-compiler and the `tpb32l` `.zo` are
emscripten-independent** -- pure target bytecode. The emscripten-ness lives
entirely in the C runtime (kernel + emcc link), which the runtime package
ships. So producing the SDK is a normal Racket pb/`tpb32l` cross-compile that
needs **no emsdk at all** -- only a native threaded host Chez (`--scheme`) and a
same-version host Racket (`--racket`). Its `tpb32l` output is ABI-compatible
with the emscripten runtime because both target `tpb32l`.

The SDK contains (`build/config.rkt` `cross-sdk-layout`, collected by
`build/stages.rkt` `package-cross-sdk`):
- **`cross-compiler/`** -- the retarget files `cross-serve.so` +
  `compile-xpatch.tpb32l` + `library-xpatch.tpb32l` (~15M). `cross-serve.so` is
  host-arch but target-generic (the target is a runtime arg); the xpatches carry
  the `tpb32l` target. All three are **host-arch + Racket-version locked** (Chez
  fasl, version-stamped) and **cannot** be regenerated by a consumer, so they
  pin the SDK to a host OS/arch + Racket version.
- **`cross-root/`** -- `collects/` + `share/pkgs/` carrying **both sources and
  the in-place `tpb32l` `.zo`** (~47M), plus `links.rktd`/`etc`/`config` and
  `lib/system.rktd` (which records `target-machine tpb32l` -- the consume path
  reads it to know it must cross-compile for `tpb32l`, not the host). The
  sources let the consumer's racket regenerate its host-loadable shadows on
  demand, so the ~143M `build/zo` (host-arch bytecode keyed by *absolute host
  paths*, non-portable) and `build/cs/c/compiled` are deliberately **not**
  shipped -- they rebuild on the consumer.
- **`pkgs/`** (a SIBLING of `cross-root`, ~24M) -- the in-tree bootstrap packages
  (racket-lib, base, net-lib, ...) the cross-root's `links.rktd` references as
  `(up up #"pkgs" X)`, which resolve relative to `<cross-root>/share` to
  `<sdk>/pkgs`. The consume points the install's `links-file` at the cross-root,
  so these must be present for the base packages to register as installed (else
  the whole base closure re-fetches). Mirrors `pack.rkt` `links-pkgs-roots`.
- **metadata** (`kind: 'cross-sdk`) recording the `build-key` (matching the
  runtime package for the same package set), plus `host-machine` + `chez-version`
  + `racket-version` as the **hard** host-compatibility gate.

Production path: `make wasm-cross-sdk` (the `sdk?` flavor of `main.zuo`'s
`build-base`). It is the same `--enable-pb --enable-mach=tpb32l
--host=...-emscripten` cross as `make wasm`, but **without** the `emconfigure`
wrapper (native `cc` -- the patched configure presets the cross 32-bit sizeof so
no `emcc` is needed) and the flow **stops after `wasm-setup`** instead of
running `wasm-deps` + the emcc link. The `--host=...-emscripten` marker still
makes `cs/c/build.zuo` stop at boot images (no native executable). The one extra
`cs/c` change is that `sdk?` (signalled via a `WASM_SDK` make var) **skips the
`scheme` target's Chez C kernel** in `build-racketcs`: for a cross target that
step compiles the kernel (`ChezScheme/<m>/c/*.o`, incl. `ffi.c`), whose libffi
headers come from the emsdk `wasm-deps` step -- and the SDK ships no kernel (it's
a runtime/link input). The cross-compiler pieces it *does* need -- the
boot/xpatch (host `bootquick`) and the `library-xpatch` CS-layer `.host-m`
objects (`racket.so`/`cs-targets`, host scheme) -- don't need the kernel, so a
cold from-scratch SDK build runs with **no emsdk and no `emcc` at all**. (The
cold cross-root, lacking the binary-only catalog, currently compiles the full
source dep set incl. doc packages, so it's fatter than the runtime's stripped
tree -- a future optimization could run the binary catalog first.)

**Consuming the SDK** -- `racket build/main.rkt cross-install --sdk <dir>
--share-data <runtime/share.data> --dest <out> [--racket <p>] [--local <dir>]...
<catalog-name>...` (`build/consume.rkt`). It **fetches** packages (catalog by
name, and/or local source dirs via `--local`) and **cross-compiles** them for
`tpb32l` with the SDK's retarget files -- a same-version host racket, **no emsdk
and no clone** -- folding their `tpb32l` `.zo` (plus sources and an updated
`/share/links.rktd`) into a runtime's `share.data`, writing a fresh
`share.data`/`share.data.js` into `<out>`. This is the path `build`'s package
layer dogfoods (`ensure-app-payload!`); the IDE's full 63-package closure
(draw/pict/datalog + the local `web-repl`) is cross-installed this way and boots.

The fetch + cross-compile invocation (proven host-safe):
```
PLTADDONDIR=<addon> <host-racket> -G <xcfg/etc> -MCR <hostzo>:<xtgt> \
  --cross-compiler tpb32l <sdk>/cross-compiler \
  -l- raco pkg install --scope user --no-docs --deps search-auto \
      --skip-installed <names...>            # locals: a separate --copy <dir> each
```
The crux is the custom `-G <xcfg>` config, which makes the SDK's **base package
set count as already installed** so only the app's *delta* is fetched + compiled:
```
#hash((pkgs-dir   . "<cross-root>/share/pkgs")   ; base pkgs register as installed
      (links-file . "<cross-root>/share/links.rktd")
      (lib-dir    . "<cross-root>/lib")           ; system.rktd -> target tpb32l
      (catalogs   . (#f)))                         ; network, for the app's NEW pkgs
```
`collects` stays on the **host racket** (host-form expansion). Setting only the
config etc-dir is *not* enough -- `find-pkgs-dir` then still resolves to the host's
`share/pkgs` and the whole base closure reinstalls; `pkgs-dir`/`links-file` are what
redirect it. The cross-root's links reference base pkgs as `(static-root (up up
#"pkgs" X))`, resolving to `<sdk>/pkgs` (a sibling of cross-root), so the SDK
**ships the in-tree `pkgs/`** (`cross-sdk-layout`); without it those links fail and
the base reinstalls. `lib-dir`'s `system.rktd` makes the cross target `tpb32l`
(without it the compile silently emits *host* bytecode); the running host racket
keeps its own machine identity regardless.

`-MCR` expands to `-M -C -R <hostzo>:<xtgt>` -- **cross-multi mode**
(`compiler/private/cm-minimal.rkt cross-multi-compile?`): two compiled-file roots,
**host form to `hostzo`, `tpb32l` form to `xtgt`**. Both roots are *explicit* (no
in-place `:` root) and `--scope user` + `PLTADDONDIR` confine the new packages to a
throwaway addon, so nothing is written to the host trees -- the discipline that
keeps the consume host-safe (cross-multi pointed at the host's own collects, e.g.
`raco pkg install -i` or `-X cross-root` with an empty shadow, would **silently
overwrite host bytecode with `tpb32l` and brick the host racket**).

`cross-install` then **harvests** only the `xtgt` artifacts under the addon package
tree (never the recompiled host-collects deps `xtgt` also holds), **verifies** each
requested package actually produced `tpb32l` `.zo`, and calls `build/pack.rkt`'s
`extend-data-package!` to append the new files after the existing `share.data` blob
and rewrite the loader manifest -- so the consumer never re-packs the whole tree.
`raco pkg install`'s host-side launcher step fails benignly (the cross `lib-dir`
lacks the `starter-sh` template); the consume tolerates *only* that signature
(`packages installed, although setup reported errors`) and the post-harvest `.zo`
verification catches any real compile failure. The `hostzo`/`xtgt` shadows persist
per-SDK (`consume-work-cache`) so a repeat consume only compiles the new packages.

`wasm-setup` (a `cs/c/build.zuo` target) assembles the cross-compiler
xpatch (`compile-xpatch.tpb32l`/`library-xpatch.tpb32l`, via the shared
`assemble-cross-xpatch`) and calls the existing cross `setup`
(`run-raco-setup` with `--cross-compiler tpb32l`). In cross mode that
runs the host `RACKET=` as both driver and `--cross-server` and never
needs the (absent) wasm `racketcs`. `RACKET=` must be the **same Racket
version as the tree** being built, since it loads the version-stamped
xpatch.

Prerequisites it does **not** do for you: source the emsdk first
(`emconfigure`/`emcc` on `PATH`); pass a native threaded host Chez
as `SCHEME=<scheme>` (the cross-compiler host -- see stage 0); and pass a
same-version host Racket as `RACKET=<racket>` (the `raco setup`
cross-server). The native library deps (libffi always, plus `WASM_DEPS`)
are built automatically by the `wasm-deps` target -- see "Native library
deps" below.

`make wasm` is now the only build path. The earlier per-stage
`wasm-shell/*.sh` scripts (and the `wasm-shell/build.zuo` orchestrator)
have been removed, and `wasm-shell/` itself is gone from the delta: the
emcc link-time JS glue (`wasmfs-stdin.js`, `wasmfs-console.js`, `node-tty.js`,
`node-locate-file.js`, `node-load-share.js`) lives repo-side in
`runtime-glue/` alongside the host-side glue, passed to the link via the
`RUNTIME_GLUE_DIR` make var (the orchestrator sets it; a manual
`make wasm` must pass `RUNTIME_GLUE_DIR=<racket-wasm>/runtime-glue`).
The page surface lives in `apps/ide/public/`, and the WASM test/bench
scripts in `test/node/` (`run-tests.sh`, `perf-bench.rktl`,
`draw-stack-test.rkt`). The stage descriptions below document what
`make wasm` does internally, stage by stage.

### How the stock cross build works (configure-driven)

`make wasm` drives the *stock* build system (`configure` + the `cs/c`
`build.zuo`) to cross-compile the runtime directly under `build/cs/c`.
The mechanism:

- **`CONFIGURE_WRAPPER=emconfigure`** -- a new make/zuo variable
  (top-level `Makefile`, threaded through `main.zuo` into
  `configured-targets-at` in `racket/src/lib.zuo`). When set, every
  `configure` the build runs is wrapped (`emconfigure ./configure ...`).
  Because the C compiles/links read `CC`/`AR`/`LDFLAGS`/`LIBS` out of the
  configure-generated Makefile, recording `CC=emcc` there makes all
  downstream `c-compile`/`c-link` (rktio, the Chez kernel, the final
  link) use `emcc` automatically -- no `emmake` needed, since zuo replaces
  `make` for the inner build. The wrapper is applied to both the `cs/c`
  configure and the rktio configure (`setup-rktio` passes it through).
  Source the emsdk (`source <emsdk>/emsdk_env.sh`) before `make` so
  `emconfigure`/`emcc` are on `PATH`.

- **Configure flags.** Drive the stock build with
  ```sh
  make CONFIGURE_WRAPPER=emconfigure \
       SCHEME=<native-threaded-host-scheme> \
       CS_CROSS_SUFFIX=-cross \
       SETUP_MACHINE_FLAGS="-MCR `pwd`/build/zo:" \
       CONFIGURE_ARGS="--enable-pb --enable-mach=tpb32l --enable-crossany \
                       --host=wasm32-unknown-emscripten"
  ```
  `--host=wasm32-unknown-emscripten` is what makes configure cross
  (`build_os != host_os`), sets the new `EMSCRIPTEN=t` marker, and (with
  the wrapper) triggers the emcc toolchain. `--enable-mach=tpb32l` is
  required because `wasm32` is not a recognized host CPU, so without it
  configure bails with "Platform is not supported natively"; it names the
  target machine explicitly. **`--enable-pb` is also required**: the
  `enable_pb` block is what sets `SCHEME_LIBFFI=yes` (the kernel's libffi
  path that Racket uses to reach rktio) and `PBCHUNK_MODE=pbchunk`.
  Reaching `tpb32l` via `--enable-mach` *alone* silently yields
  `SCHEME_LIBFFI=no` + `PBCHUNK_MODE=plain` -- a runtime that can't do
  I/O and a boot with no pbchunk. (`PLT_CS_MACHINE_TYPE` is no longer
  gated on `enable_pb` -- see the patches list -- so that one is set for
  any pb target regardless.)

- **The CS build stops at the boot images.** For an `EMSCRIPTEN=t`
  target, `cs/c/build.zuo` skips the native `racketcs`/`gracketcs`
  executables and the `embed-boot` step (boot images are
  `--preload-file`'d into MEMFS at the emcc link, not embedded), stopping
  at `racket.boot` + the `{petite,scheme,racket}-pbchunk.boot` images and
  the 30 pbchunk C sources under `build/cs/c/`. Drive it as
  `cd racket/src/build/cs/c && bin/zuo . build` (not `make in-place`,
  whose install/`raco setup` steps still expect a native `racketcs`).

What is **not** yet folded in (still needs new work):

1. **The Chez kernel's emscripten config.** `cs/c/build.zuo`'s `scheme`
   target synthesizes an empty `Mf-config` and never runs ChezScheme's
   `./configure --emscripten --pbarch --threads --enable-libffi` (the em
   kernel stage, §5). The stock `libkernel.a` therefore gets
   `CC=emcc` but not the emscripten cflags / pb-arch selection /
   libffi-closure `mdlinkflags`. This is the gating prerequisite for a
   real emcc link.
2. ~~WASM **libffi**~~ **(done)** -- libffi is now built automatically by
   the `wasm-deps` target (see "Native library deps" below); it always
   runs first, so `add-scheme-kernel-config`'s `-I`/`-L` into the libffi
   install is satisfied without a separate manual step. The `-I`/`-L`
   paths into `build-libffi-em/install` remain (the recipe builds there)
   but are no longer a hardcode pending other work.
3. ~~The **recipe deps**~~ **(done)** -- the recipe driver
   (repo-side `wasm-deps/`, via `WASM_DEPS_SRC_DIR`) is folded in as the
   `wasm-deps` zuo
   target; `WASM_DEPS="<libs>"` selects which to build (or `draw` for the
   full cairo/pango stack), `boot.o` is compiled with
   `-DRACKET_EXTRA_FOREIGN_INC` so `wasm_deps.inc` registrations apply,
   and the `wasm` link splices `.wasm-deps-linkflags.txt` +
   `wasm_deps_uflags.txt`. See "Native library deps" below.
4. **Trimming the preloaded collects.** Target `.zo` are now produced
   in-tree: the `wasm-setup` target runs the cross `raco setup`
   (`--cross-compiler tpb32l`) so `racket/collects/**/compiled/tpb32l/`
   is populated before the link preloads `collects`. What is still not
   folded in is the *trimmed* cross-root `collects/etc/share` (the
   cross-root collections stage, §6) -- `make wasm` currently preloads the
   **full** source `collects` (now including the `compiled/tpb32l` .zo),
   which is large.
5. ~~The **emcc link target**~~ **(done)** -- the `wasm` target in
   `cs/c/build.zuo` compiles `main_em.o` + `init_rktio.o` (reusing the
   already-built `boot.o` and pbchunk objects) and emcc-links against the
   in-tree `libkernel.a`/`liblz4.a`/`librktio.a` + the recipe-dep libffi,
   preloading the pbchunk boots and the source `collects`/`etc`. `boot.o`
   is compiled with `-DRACKET_EXTRA_FOREIGN_INC="wasm_extras.inc"` (so the
   libm + recipe-dep `wasm_deps.inc` symbols register), the recipe-dep
   link flags are spliced in (item 3), and the `wasm_*.c` primitives
   (`wasm_http`/`wasm_canvas`/`wasm_dom` entry points + `wasm_stubs`, which
   stubs the libc functions the deps reference -- `getprogname`,
   `copy_file_range`, `res_query`, `pthread_setname_np`, ...) are compiled
   and linked. It emits **both** the §5 **node** link
   (`racket.{js,wasm,data}`) and the **browser** `racket-web.*` variant
   with its shell JS + staged page assets. Still missing: the trimmed
   cross-root collects (item 4, so it currently preloads the full source
   tree). Whether it actually boots also depends on item 1 (the kernel's
   full emscripten config / `mdlinkflags`).

### 0. Build the native host Chez (only if missing)

Part of `make wasm` (stage 0). The boot and `racket.boot`
stages run a native **threaded** host Chez as the cross-compiler. If one
already exists -- from a prior `make cs`
(`racket/src/build/cs/c/ChezScheme/<mach>/`) or a prior run of this stage
(`racket/src/ChezScheme/<mach>/`) -- it is reused. Otherwise it is built
standalone, the same way the "Solo Chez Build" CI does:

```sh
cd racket/src/ChezScheme
./configure --threads      # auto-detects the native threaded machine
make                       # bootstraps via the committed boot/pb files
```

This works without `make fetch-pb` because the pb boot files are committed
under `racket/src/ChezScheme/boot/pb/` and `enableFrompb=yes` is the
configure default, so a native `./configure` arranges to "create boot
files via pb". Threaded is required (`t<arch>`): the cross-compiler is
generated from a threaded host so cp0 doesn't trip on `thread.sls` (see
§3). The same host-Chez detector is shared here and by stages 3-4.

### 1. Cross-compile rktio for WebAssembly

`make wasm` stage 1. The equivalent manual steps:

```sh
cd racket/src/rktio
mkdir -p build-em && cd build-em
source $EMSDK/emsdk_env.sh
emconfigure ../configure --host=wasm32-unknown-emscripten --disable-pthread
emmake make librktio.a
mv '@HIDE_NOT_STANDALONE@librktio.a' librktio.a   # configure leaves an
                                                  # unsubstituted token
                                                  # in the archive name
                                                  # for standalone builds
```

This uses the `__EMSCRIPTEN__` branch added to `rktio_platform.h`
(commit `1a2130c981`); no further patches are needed. The archive is
~388 KB.

The `cd build-em` before `../configure` matters: it makes `../configure`
resolve to rktio's own autoconf script. Running `../configure` from
`racket/src/rktio` instead invokes the top-level `racket/src/configure`,
which recurses into `cs/c/configure` and dies with "Platform is not
supported natively by Racket CS"; adding `--enable-mach=tpb32l` to escape
that then lands in `cs/c/configure`, which demands a WASM libffi rktio
never links. rktio's configure has neither a machine-type option nor a
libffi check, so either error means the wrong configure is running.

### 2. Native library deps (libffi + the Cairo/Pango stack)

Cross-compiled native libraries are built by a recipe driver that lives
**repo-side**, in racket-wasm's `wasm-deps/` (not in the clone); the
**`wasm-deps` zuo target** (`cs/c/build.zuo`) reads its location from the
`WASM_DEPS_SRC_DIR` make var (the orchestrator sets it) and `main.zuo`
runs the target before the kernel `build` (the Chez kernel's `ffi.c`
needs libffi's headers). Drive it via make:

```sh
make wasm SCHEME=... RACKET=... \
     WASM_DEPS_SRC_DIR=<racket-wasm>/wasm-deps ...  # libffi only (default)
make wasm WASM_DEPS="draw" ...                      # + the cairo/pango stack
```

`WASM_DEPS` is a space-separated list of recipe names from
`wasm-deps/deps/`, plus the group alias **`draw`** which expands to the
full `racket/draw` stack (`libpng pixman freetype pcre2 expat glib
libjpeg-turbo fontconfig cairo harfbuzz pango`, in build-leaf→root order;
fontconfig must precede cairo, harfbuzz must precede pango). **libffi is
always built first**, regardless of `WASM_DEPS`. The make var threads
through `main.zuo` (`build-base`'s `vars`) into `cs/c/build.zuo`'s
`(lookup 'WASM_DEPS)`.

Each `deps/<name>.sh` is a shell file that sets a handful of `DEP_*`
variables (source URL + sha256, configure args, archive name, link
flags, optional list of C symbols to register with `Sforeign_symbol`);
`deps.sh` provides the shared fetch / configure / `emmake` / cache logic,
and `symgen.sh` emits `wasm_deps.inc` (the `Sforeign_symbol`
registrations, `#include`d by `wasm_extras.inc` when `boot.o` is compiled
with `-DRACKET_EXTRA_FOREIGN_INC`) + `wasm_deps_uflags.txt` (`-Wl,-u`
flags so wasm-ld retains symbols nothing else references). Tarballs land
in `racket/src/.wasm-cache/` and builds in `racket/src/build-<name>-em/`
(a cache *outside* `build/`, so `make clean` of the build dir doesn't
discard them).

`build-deps.sh --src <racket/src> --out <dir> --deps "<list>"` writes its
three artifacts (`wasm_deps.inc`, `wasm_deps_uflags.txt`, and the
resolved `-L`/`-l` flags in final link order as
`.wasm-deps-linkflags.txt`) into `--out`, which the `wasm-deps` target
points at `build/cs/c/wasm-deps/`. The `boot.o` compile and the `wasm`
link read those files back rather than re-running the recipe loop. The
driver is incremental (per-dep state cache), so re-running is cheap.

(The recipe *sources* live repo-side under `wasm-deps/`; only the
*outputs* land in the clone's `build/cs/c/wasm-deps/`. The `wasm-deps`
target runs them automatically before the kernel build, since `ffi.c`
needs libffi's headers. The recipes are part of the build key -- editing
one invalidates cached runtimes, like any delta edit.)

A clean-up gotcha that bit once: meson-based recipes (glib, pango) leave
nested *git checkouts* under `src/subprojects/` (meson wrap). `git clean`
with a single `-f` refuses to delete untracked dirs that contain a git
repo, so a sync used to leave a gutted `build-<dep>-em/src/` behind --
and `wasm_dep_fetch` skips re-extracting when `src/` exists, so the next
build died at the dep's configure with "no meson.build". `sync` therefore
cleans with `-ffdx` (double `-f`), which removes nested repos too.

Recipe schema in brief:

```sh
DEP_NAME=libffi
DEP_VERSION=3.5.2
DEP_SOURCE_URL=https://...libffi-3.5.2.tar.gz   # omit for libs Emscripten
DEP_SOURCE_SHA256=...                            #   already bundles (USE_FOO=1)
DEP_BUILD_SYSTEM=autotools             # or "meson" (cmake: not yet)
DEP_BUILD_ARGS=(--enable-static --disable-shared ...)   # autotools style
                                                        # OR -Dfoo=bar (meson)
DEP_INSTALL_LIB=libffi.a
DEP_LINK_FLAGS=(-lffi)
DEP_SYMBOLS_MODE=explicit              # or "scrape" or "none"
DEP_SYMBOLS=(cairo_create cairo_destroy ...)
```

Meson recipes use `wasm-deps/wasm-emscripten.cross` as their
cross-compilation file (emcc/em++/emar wrappers; `system='emscripten'`;
`-pthread` + `USE_ZLIB=1` propagated to all c/cpp args + link args).
`PKG_CONFIG_PATH` is accumulated as each dep installs, so later
configure/meson steps can find earlier deps via `.pc` files (Cairo finds
pixman this way).

If the dep's headers are *not* among boot.c's includes, the generated
`extern void name();` blocks in `wasm_deps.inc` are sufficient — the
cast to `(void *)` discards the unspecified function type. If a recipe
is for a library whose headers boot.c does include, register those
symbols by hand in `wasm_extras.inc` instead and leave the recipe's
symbol list empty.

### 3. Generate tpb32l boot files and cross-compiler `xpatch`

The Racket `thread` layer uses `make-pthread-parameter`, so the target
must be a **threaded** pb variant: `tpb32l`. The cross-compiler is
generated from the native threaded host Chez (`tarm64osx` or whatever the
host machine type is) -- from §0, whether that came from `make cs` or the
stage-0 bootstrap -- *not* from a basic-pb host scheme, which trips
Chez's cp0 optimizer with `unexpected context ... call
current-thread/in-racket` on `thread.sls`.

`make wasm` stage 3 (locates the host Chez and skips the `pb-host`
rebuild if present). The equivalent manual steps:

```sh
cd racket/src/ChezScheme
# A native basic-pb host workarea, needed only to invoke bootquick:
./configure --pb --workarea=pb-host && make
# Cross-build pb32l boot files and the xpatch using the native threaded
# host scheme (from §0; path as detected by find_host_scheme):
bin/zuo pb-host bootquick \
  --host-scheme <native-threaded-scheme> \
  tpb32l
```

This produces `racket/src/ChezScheme/xc-tpb32l/boot/tpb32l/{petite,scheme}.boot`
and `xc-tpb32l/s/xpatch`.  Copy the boot files into the place where
Chez's `--emscripten` configure expects them:

```sh
mkdir -p boot/tpb32l
cp xc-tpb32l/boot/tpb32l/petite.boot boot/tpb32l/
cp xc-tpb32l/boot/tpb32l/scheme.boot boot/tpb32l/
```

### 4. Cross-build `racket.boot` for the tpb32l target

The Racket CS build needs to be told the host machine type is the
existing native tarm64osx (so it can run the compiler) but the target
machine type is tpb32l (so the produced `racket.boot` matches what
Chez Emscripten will load). `cs/c/configure --enable-pb
--enable-target=tpb32l` expresses exactly that split: it auto-detects
the native host `MACH` and keeps `TARGET_MACH`/`KERNEL_TARGET_MACH` at
the requested pb machine. (Earlier this clobbered an explicit pb target
with the host-derived pb name, so the build passed
`--enable-mach=tpb32l` and then sed-rewrote `MACH` back to the host in
the generated Makefile. `cs/c/configure` now honors the explicit pb
target -- see the upstream-patches list -- so neither workaround is
needed.)

`make wasm` stage 4 (depends on §3's xpatch; defaults `XCODE_FFI` to the
macOS SDK's `ffi.h` via `xcrun`, override the env var elsewhere). The
equivalent manual steps:

```sh
cd racket/src
mkdir -p build-cs-tpb32l && cd build-cs-tpb32l
CPPFLAGS="-I$XCODE_FFI" ../cs/c/configure \
  --enable-pb --enable-target=tpb32l \
  # --disable-pbchunk \
  --enable-scheme=<native-threaded-scheme>   # the §0 host Chez executable
# (Adjust XCODE_FFI / CPPFLAGS for your platform's libffi headers.)
# Yields MACH=<native host>, TARGET_MACH=tpb32l -- no Makefile sed.
# `--enable-scheme=<exe>` (configure's SCHEME= cross path) works for a
# host Chez in either layout; stage 4 passes the detected host path.

# Make the cross-compile xpatch visible where build.zuo looks for it:
mkdir -p ChezScheme/xc-tpb32l/s
cp ../ChezScheme/xc-tpb32l/s/xpatch ChezScheme/xc-tpb32l/s/xpatch

# bin/zuo is a Makefile target (compiles zuo/zuo.c). A fresh workarea
# has none, so build it before driving the boot build:
make bin/zuo

# Build the Chez tpb32l kernel + boot files first. racket-pbchunk.boot
# consumes ChezScheme/tpb32l/boot/tpb32l/{petite,scheme}.boot as plain
# inputs; they have no build rule of their own (the `scheme` target
# produces them as a side effect via bootquick --xpatch), so a fresh
# workarea that jumps straight to racket-pbchunk.boot dies with
#   missing input file: "ChezScheme/tpb32l/boot/tpb32l/petite.boot".
bin/zuo . scheme
bin/zuo . racket-pbchunk.boot
```

The `racket-pbchunk.boot` zuo target builds all the CS layers --
chezpart, rumble, thread, io, regexp, schemify, linklet, expander,
main -- writes `racket.boot` (~4.3 MB), and runs the
`to-pbchunk.ss` script to produce `petite-pbchunk.boot`,
`scheme-pbchunk.boot`, `racket-pbchunk.boot`, and the 30 pbchunk C
sources (`{petite,scheme,racket}{0..9}.c`) in the workarea root.

(`make` would do the same and then try to build the host `racketcs`
executable from those boot files; on a cross-build that fails in
`embed-boot.rkt` with `relative-path?: not a path string: ""`
because the host-runtime variables aren't set. The pbchunk target
stops cleanly before that step.)

### 5. Build Chez Emscripten for tpb32l with libffi and the rktio link

Once everything above (rktio, libffi, host pb, `racket.boot`) exists, the
whole compile-and-link of the WASM runtime is performed by `make wasm`'s
final stages: the `wasm` target (re)compiles `main_em.o`, `boot.o`,
`init_rktio.o`, and (on first run) the 30 pbchunk objects, then links
**both** `racket.{js,wasm,data}` (node) and `racket-web.{js,wasm,data}`
(browser) and stages the page assets. The rest of this section explains
what that stage runs and why, so the recipe can be reproduced or modified
by hand.

The Chez Emscripten workarea has to be configured once before the kernel
can be linked. The setup half below -- build the WASM libffi, configure
the workarea, patch `mdlinkflags`, and build `libkernel.a` -- is the em
kernel stage (it builds libffi so `configure --enable-libffi` is
satisfied). The manual steps:

```sh
cd racket/src/ChezScheme
source $EMSDK/emsdk_env.sh

CPPFLAGS="-I$PWD/../build-libffi-em/install/include" \
LDFLAGS="-L$PWD/../build-libffi-em/install/lib" \
./configure --emscripten --pbarch --threads --enable-libffi \
            --workarea=em-tpb32l \
            --emboot=$PWD/../build-cs-tpb32l/racket.boot

# The `em)` mdlinkflags case in ChezScheme/configure already emits the
# libffi-closure flags (addFunction/removeFunction exports +
# -sALLOW_TABLE_GROWTH=1), so Mf-config needs no post-configure edit.
# (This used to be an awk patch here; see the upstream-patches list.)
```

Then build the rktio-init object and the kernel with `CUSTOM_INIT`:

```sh
emcc -DPORTABLE_BYTECODE \
     -I ../rktio -I ../rktio/build-em \
     -I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/ -I em-tpb32l/lz4/lib \
     -O2 -pthread -s USE_ZLIB=1 \
     -o em-tpb32l/boot/tpb32l/init_rktio.o -c c/init_rktio.c

emcc -DPORTABLE_BYTECODE \
     -DCUSTOM_INIT=init_rktio_symbols -include c/init_rktio.h \
     -I ../build-libffi-em/install/include \
     -I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/ -I em-tpb32l/lz4/lib \
     -O2 -pthread -s USE_ZLIB=1 \
     -Wpointer-arith -Wall -Wextra -Wno-implicit-fallthrough \
     -o em-tpb32l/boot/tpb32l/main.o -c c/main.c
```

For the Racket-on-WASM target, compile the Emscripten entry point
`../cs/c/main_em.c` instead of Chez's `c/main.c`, plus `../cs/c/boot.c`
(which provides `racket_boot`). Both need Racket's `boot.h` on the
include path. Compile `boot.c` with `-DPBCHUNK_REGISTER` so that it
registers the pbchunk C functions (see the pbchunk subsection below);
without that define the chunked boot files reference chunks that are
never installed:

```sh
emcc -DPORTABLE_BYTECODE \
     -I ../cs/c \
     -I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/ \
     -O2 -pthread -s USE_ZLIB=1 \
     -Wall -Wextra \
     -o em-tpb32l/boot/tpb32l/main_em.o -c ../cs/c/main_em.c

emcc -DPORTABLE_BYTECODE -DPBCHUNK_REGISTER \
     -I ../cs/c -I ../rktio -I ../rktio/build-em \
     -I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/ \
     -O2 -pthread -s USE_ZLIB=1 \
     -o em-tpb32l/boot/tpb32l/boot.o -c ../cs/c/boot.c
```

#### pbchunk: compile the boot chunks to WASM (large boot-time win)

The pb interpreter executes the boot images instruction-by-instruction,
which dominates the (multi-minute) startup. "pbchunk" turns hot
bytecode sequences into C functions; the cross-build in §4 already
generated them in `../build-cs-tpb32l/`:

- `petite-pbchunk.boot`, `scheme-pbchunk.boot`, `racket-pbchunk.boot`
  — the chunked boot images (the racket one is ~16 MB vs. the plain
  4.3 MB), with chunk *references* embedded in the bytecode.
- `petite0.c … petite9.c`, `scheme0.c … scheme9.c`,
  `racket0.c … racket9.c` — 30 generated C files holding the chunk
  functions. (The matching `.o` files there are host-native Mach-O and
  cannot be reused; recompile the `.c` with emcc.)

All three boots share **one global chunk index space** (e.g. the racket
chunks occupy indices ~14067–22867), so the chunked `racket.boot`
assumes petite and scheme were chunked too. Use all three chunked
boots together — do not mix a chunked racket boot with plain
petite/scheme. `boot.c`'s `register_pbchunks()` likewise registers all
30, which is why `-DPBCHUNK_REGISTER` is all-or-nothing.

Recompile the 30 chunk sources with emcc:

```sh
for b in petite scheme racket; do
  for i in 0 1 2 3 4 5 6 7 8 9; do
    emcc -DPORTABLE_BYTECODE \
         -I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/ \
         -O2 -pthread -s USE_ZLIB=1 \
         -o em-tpb32l/boot/tpb32l/$b$i.o \
         -c ../build-cs-tpb32l/$b$i.c
  done
done
```

Finally link everything, including `librktio.a` and `-lffi`:

```sh
emcc -O2 -pthread -s USE_ZLIB=1 \
     -o em-tpb32l/bin/tpb32l/racket.html \
     em-tpb32l/boot/tpb32l/main_em.o \
     em-tpb32l/boot/tpb32l/boot.o \
     em-tpb32l/boot/tpb32l/init_rktio.o \
     em-tpb32l/boot/tpb32l/{petite,scheme,racket}{0,1,2,3,4,5,6,7,8,9}.o \
     em-tpb32l/boot/tpb32l/libkernel.a \
     em-tpb32l/lz4/lib/liblz4.a \
     ../rktio/build-em/librktio.a \
     -L ../build-libffi-em/install/lib \
     --extern-pre-js runtime-glue/node-locate-file.js \
     --post-js runtime-glue/node-tty.js \
     --preload-file ../build-cs-tpb32l/petite-pbchunk.boot@petite.boot \
     --preload-file ../build-cs-tpb32l/scheme-pbchunk.boot@scheme.boot \
     --preload-file ../build-cs-tpb32l/racket-pbchunk.boot@racket.boot \
    --preload-file ../../collects@/collects \
    --preload-file ../../etc@/etc \
     -s EXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1 \
     -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset \
     -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction \
     -sALLOW_TABLE_GROWTH=1 \
     -lffi
```

`runtime-glue/node-tty.js` is the node analogue of the browser's
ring-backed stdin (`wasmfs-stdin.js`): it
overrides Emscripten's default TTY `get_char` to do a real `fs.readSync`
on node's stdin and return `undefined` (EAGAIN) on a would-block rather
than letting the default path leak EAGAIN out as EIO (errno 29). Without
it, `node racket.js` with a non-blocking stdin (e.g. `child_process.spawn`,
or any non-piped invocation) loops on `error reading from stream port`.

`runtime-glue/node-locate-file.js` fixes data-file resolution under node so
that `node path/to/racket.js` works from any directory, not just from
inside the build dir. The trap: Emscripten's internal `locateFile(path)`
resolves against `scriptDirectory` (the dir of `racket.js`), which is why
`racket.wasm` always loads -- but the `--preload-file` data loader does
**not** go through it. It reads `Module["locateFile"]` directly and, when
that hook is unset, falls back to the bare relative string `"racket.data"`,
which `fs.readFileSync` resolves against the *process CWD*. So a plain
`echo ... | node racket/src/build/cs/c/wasm/racket.js` dies with
`ENOENT: ... open 'racket.data'`. The shim defines `Module["locateFile"]`
to join relative names onto the script's `__dirname` under node.

It must be linked with **`--extern-pre-js`, not `--pre-js`**: the
data-package loader runs `loadPackage()` synchronously at parse time,
*before* the point where emcc splices ordinary `--pre-js` content (the
loader sits near the top of the file; `--pre-js` lands much later). Only
`--extern-pre-js` is concatenated ahead of both the `var Module`
declaration and the loader, so the hook is in place when the loader reads
it. The shim relies on `var Module` being hoisted into the same top-level
scope, which holds for the non-MODULARIZE node build. It is a no-op on the
browser surface (no node `process`).

### 6. Run

```sh
cd em-tpb32l/bin/tpb32l
echo '(+ 1 2)' | node racket.js
```

With `main_em.c` linked in, you will see Chez's Petite banner print,
then `racket.boot` begin loading, then a long sequence of libffi calls
into rktio succeed, and the boot-arguments struct is now populated so
startup proceeds past the old `expected ... to start` error.

With pbchunk wired in (below), boot is fast: `echo '(+ 4 2)' | node
racket.js` returns `6` in **~2 seconds** wall time (down from ~5
minutes of pure interpretation), e.g.:

```
$ /usr/bin/time -p node racket.js <<< '(+ 4 2)'
Welcome to Racket v9.2.0.5 [cs].
> 6
real 1.82
```

`boot.c` also has `RACKET_BOOT_TIMING`-gated `[boot-timing]` checkpoints
around the heap-build and Racket-startup phases. These work for the
**native** CS build, but note that **under node/Emscripten `getenv`
does not see `process.env` by default**, so the checkpoints stay silent
there unless the environment is forwarded into the Emscripten runtime
(e.g. a `preRun` that populates `ENV`). Given the ~2s boot, per-phase
profiling is no longer needed.

### Browser shell

The browser shell is a
**shared runtime + per-surface host** design: one
`racket-web.{js,wasm,data}` binary backs every browser surface. Today
there is one surface -- `index.html`/`ide.js`, the DrRacket-like IDE (see
"IDE page" below) -- but the architecture is deliberately surface-
agnostic (future doc widgets / embeds / canvas GUIs are just another
HTML+JS pair that drives the same worker with a different init
payload).

It needs a **separate, browser-specific build** of the runtime,
because the node `racket.js` runs `main()` on the calling thread: in a
browser that would be the page's main thread, and Racket's blocking
REPL stdin read would freeze the event loop.

#### Per-surface init protocol

`shell-worker.js` no longer loads the runtime at top level. It waits
for an `init` message from the page, then sets `self.Module` and
`importScripts("./racket-web.js")`. The init payload lets the page
choose:

- `argv` -- becomes `Module.arguments`, which Racket sees as its
  command line. `[]` runs a plain interactive REPL (and keeps the
  default `racket/init`, so the REPL namespace has the full `racket`
  bindings); `["-u","/tmp/main.rkt"]` runs a module and exits;
  `["-e","(form)"]` evaluates an expression. The IDE uses `[]` and then
  drives `enter!` over the input ring (see "IDE page"). **Don't** reach
  for a startup action like `-l racket/enter` to preload the helper: any
  of `-l`/`-t`/`-e`/`-u` *suppresses* `racket/init`, leaving the REPL
  namespace bare (`#%top-interaction` unbound) -- require it from inside
  the REPL instead.
- `files` -- `{ "/abs/path": "<text>" }` written into the FS during
  `preRun` (before `main()`). The IDE uses this to drop the editor's
  source at `/tmp/main.rkt` before the runtime starts.

There is no longer an `idbfs` init field: persistence is unconditional.
`/home/web_user` is mounted on an OPFS backend by
`racket_wasm_browser_fs_init` (`wasm_shell_io.c`) early in `main()`, and
OPFS is durable on `close()` -- so a transient process-per-run still sees
files an earlier run wrote and closed, with no opt-in flag and no
save-on-exit `FS.syncfs`. (Mount is fail-soft: an in-memory `/home/web_user`
if OPFS is unavailable / single-tab-locked, emscripten #24648.)

The rings (`wasm_shell_io.c`) and the console glue (`wasmfs-stdin.js`,
`wasmfs-console.js`) stay surface-agnostic.

The page therefore hosts the runtime in a dedicated Web Worker it
spawns itself (`shell-worker.js`); `main()` runs on that worker's own
thread, free to block on stdin, while the page stays responsive. The
two threads exchange console bytes through ring buffers in the
module's *shared* linear memory (`-pthread` makes
`WebAssembly.Memory({shared:true})`, even though Racket never spawns
pthreads of its own):

- `racket/src/cs/c/wasm_shell_io.c` reserves the rings in the shared
  heap and exports their addresses.
- The WASMFS console glue replaces the old `TTY`-ops override (WASMFS
  has no `TTY.stream_ops`). Both halves register **jsimpl devices** that
  `racket_wasm_browser_fs_init` (`wasm_shell_io.c`) `dup2`s onto the std
  fds; both are set up from C in `main()` -- on the proxied main pthread --
  because WASMFS jsimpl device ops run on the *calling* thread against
  per-thread `wasmFS$backends` JS state and are *not* proxied, so a device
  must be created on the same pthread that later reads/writes it.
  - **stdout/stderr** -- `runtime-glue/wasmfs-console.js` (`emcc
    --js-library`) provides C-callable `rkt_console_setup`, which
    registers a `/dev/console` char device pushing each byte into the
    output ring with no newline buffering (so the REPL prompt `> ` appears
    immediately; WASMFS's built-in `WritingStdFile` would otherwise
    line-buffer until `\n` and hide it). `dup2`s fds 1/2 onto it.
  - **stdin** -- `runtime-glue/wasmfs-stdin.js` (`emcc --js-library`)
    provides C-callable `rkt_stdin_setup`. **It does NOT use the obvious
    `_wasmfs_stdin_get_char` hook**: that hook lives in WASMFS's built-in
    `StdinFile`, and rktio never calls its `read()`. rktio gates every
    read on `poll(POLLIN)` (`rktio_fd.c` `do_poll_read_ready`), and WASMFS
    `__syscall_poll` reports a non-regular fd readable only when
    `getFile()->getSize() > 0` (`syscalls.cpp`) -- but `StdinFile::getSize()`
    is hard-coded `0` and is not overridable, so poll never fired, the read
    never ran, and the hook was dead (the REPL printed its prompt and hung).
    Instead we register our *own* jsimpl backend whose `read()` blocks on
    the input ring with `Atomics.wait` (legal on the worker; sets
    `shell_io_state` to `1` while parked, `0` once input arrives, for the
    page's "waiting for input" affordance), then `dup2` its node onto fd 0.
    `wasmfs_create_file` masks the `S_IFCHR` type bit off the mode
    (`doOpen: mode &= S_IALLUGO`), so the node is a **regular** file -- which
    is exactly what we want: rktio fstats it, sees `S_ISREG`, sets
    `RKTIO_OPEN_REGFILE`, and then *skips poll entirely* ("Reading regular
    file never blocks") and issues a plain blocking `read()` that lands in
    our ring handler. This re-homes the exact `shell-tty.js` `streamRead`
    discipline onto a WASMFS device. (`getSize()` returns a constant `1` as
    a belt-and-suspenders so a non-regular interpretation would still poll
    readable; the read syscall does not clamp to it.)
- `runtime-glue/shell-worker.js` is the worker bootstrap: it sets up
  `self.Module`, `importScripts("./racket-web.js")` synchronously,
  and on `onRuntimeInitialized` posts the shared `HEAPU8.buffer`
  (a `SharedArrayBuffer`) plus the ring offsets back to the page.
- `ide.js` runs on the page: it spawns the worker via
  `new Worker("./shell-worker.js")`, receives the buffer/offsets,
  polls the output ring each animation frame and writes typed lines
  into the input ring followed by `Atomics.notify`.

`make wasm`'s `wasm` target builds the browser runtime alongside the
node one (it adds `wasm_shell_io.o`, the `--js-library wasmfs-stdin.js`
+ `--js-library wasmfs-console.js` console glue, `-sWASMFS=1`, and the
ring exports). It does **not** stage the page assets -- the worker glue
`shell-worker.js` and the surface `ide.*` are copied into `dist/` from the repo
by the orchestrator's `collect-outputs`, not from the clone (`serve.rkt` is
repo-side glue run in place, not copied; see the runtime/surface split note near
the top). The underlying link is
(the example paths below predate the move to `build/cs/c/wasm/`, but the
flags are what the `wasm` target emits):

```sh
emcc -O2 -pthread -s USE_ZLIB=1 \
     -o em-tpb32l/bin/tpb32l/racket-web.html \
     em-tpb32l/boot/tpb32l/main_em.o \
     em-tpb32l/boot/tpb32l/boot.o \
     em-tpb32l/boot/tpb32l/init_rktio.o \
     em-tpb32l/boot/tpb32l/wasm_shell_io.o \
     em-tpb32l/boot/tpb32l/{petite,scheme,racket}{0,1,2,3,4,5,6,7,8,9}.o \
     em-tpb32l/boot/tpb32l/libkernel.a \
     em-tpb32l/lz4/lib/liblz4.a \
     ../rktio/build-em/librktio.a \
     -L ../build-libffi-em/install/lib \
     --js-library runtime-glue/wasmfs-stdin.js \
     --js-library runtime-glue/wasmfs-console.js \
     --preload-file ../build-cs-tpb32l/petite-pbchunk.boot@petite.boot \
     --preload-file ../build-cs-tpb32l/scheme-pbchunk.boot@scheme.boot \
     --preload-file ../build-cs-tpb32l/racket-pbchunk.boot@racket.boot \
     --preload-file ../../collects@/collects \
     --preload-file ../../etc@/etc \
     --use-preload-cache \
     -s EXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1 \
     -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset,_shell_in_addr,_shell_in_cap,_shell_out_addr,_shell_out_cap,_shell_io_state_addr \
     -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction,HEAPU8,HEAP32 \
     -sALLOW_TABLE_GROWTH=1 \
     -lffi
```

`--use-preload-cache` is **browser-only** (it is in `browser-args`, not
`node-args`, in `cs/c/build.zuo`). It makes the generated `.data` loader
stash the preload package in IndexedDB keyed by package name + total
size, so a returning browser reads the (large) boot/collects/etc
payload from IDB instead of re-fetching `racket-web.data` over the
network on every load. The cache self-invalidates when the package size
changes, so a rebuild that alters the preload set transparently refreshes
it. The node surface has no persistent IndexedDB to cache into, so the
flag is omitted there. (The browser's *package* tree no longer rides in
`racket-web.data` — it ships as a separate `share.data`/`share.data.js`
that caches itself the same way; see "Packages as a separate data file".)

The base browser link historically omitted `-sPROXY_TO_PTHREAD`: an even
earlier design used it so Emscripten spawned the runtime thread, but that ran
the *filesystem* on the page's main thread (MEMFS is per-thread JS state),
forcing `get_char` to be non-blocking and the runtime to busy-poll between
keystrokes. By owning the worker ourselves, the FS and `main()` share a thread,
the blocking stdin read truly parks on `Atomics.wait`, and the runtime idles at 0% CPU.
**However, that thread-sharing is exactly what deadlocks GLib's font path**, so
the browser link now *does* enable `-sPROXY_TO_PTHREAD` again -- but with the
shell worker owned by us as the *proxy-pump* thread (not running Racket), and
`mainScriptUrlOrBlob` pointing the pthread pool at `racket-web.js`. The FS now
lives on the proxied pthread with `main()`, so the stdin read still blocks cleanly;
the page main thread only pumps the proxy queue. See "Browser text: the GLib
thread deadlock and its fix" for the full account.

Serve with **COOP/COEP headers** — `SharedArrayBuffer` is unavailable
without cross-origin isolation, so a plain static server will not start
the runtime. `runtime-glue/serve.rkt` (repo-side glue, run in place against
the output dir — not copied into `dist/`) sets the headers:

```sh
racket build/main.rkt serve dist 8123
# or: cd dist && racket ../runtime-glue/serve.rkt 8123
# browse to http://127.0.0.1:8123/
```

Notes / status:

- Output (stdout and stderr) is currently merged into one ring and
  rendered without color; the input ring is line-buffered on the page.
- The Definitions editor is a **CodeMirror 5** instance (syntax
  highlighting); the Interactions output is a scrolling `<pre>`, not a
  terminal emulator -- `ide.js` strips the few ANSI CSI sequences Racket
  emits. The REPL input box stays a plain `<textarea>` (a single
  submission line, not an editing surface). See "Syntax highlighting"
  below.
- This cannot be validated under node: a headless harness can't drive
  the page+worker handshake. Test in a browser.

### IDE page

`index.html` + `ide.js` is a single DrRacket-like page: a **Definitions**
editor on the left, an **Interactions** pane (output + REPL + the
program's stdin) on the right. It replaces the earlier split
`browser-shell` (bare REPL) and `playground` (run-a-module) pages --
one surface now does both.

Lifecycle is **process-per-run**. The Interactions pane is inert until
*Run*; a Run click:

1. Tears down any existing worker and clears the output.
2. Spawns a fresh worker with
   `{argv:[], files:{"/tmp/main.rkt": <editor text>}}` -- a
   plain interactive REPL (argv `[]` keeps `racket/init`, so the
   namespace has the full `racket` bindings), with the editor text
   dropped at `/tmp/main.rkt`.
3. On `ready`, injects a one-line prelude into the stdin ring (not
   echoed), as separate top-level forms -- each `require` takes effect
   before the next form is read:
   - install the **submission-oriented REPL reader** (`web-repl/ide-repl`'s
     `install-ide-prompt-read!`, guarded `dynamic-require`) -- see
     "Submission-oriented REPL reader" below. This is the *first* form, so
     the default per-datum reader reads it; once it installs itself, the
     remaining prelude forms are read by it as a single submission.
   - `(require racket/enter)` -- for `enter!`.
   - install the **bitmap printer** (`web-repl/print`'s
     `install-bitmap-printer!`, via a guarded `dynamic-require` so a
     missing `web-repl` still lets the program run): a `current-print`
     hook that renders bitmap-valued results via `display-bm`, so a
     bare top-level bitmap shows as an image rather than
     `#<object:bitmap%>`. Installed *before* `enter!` so the program's
     own top-level expressions get it too (`#lang racket` prints
     module top-level expression results through `current-print`).
   - `(begin (enter! (file "/tmp/main.rkt")) <configure-runtime> <re-install
     printer>)` -- `enter!` instantiates the module (its body runs --
     output streams in) **and** switches the REPL's current namespace to
     the module's, so every top-level definition is in scope. That is
     exactly DrRacket's Run: run the definitions, then a REPL that sees
     them (not just the `provide`d names a plain `-i -t` would expose).
     Bundled in the *same* `begin` (read+compiled in the `racket`
     namespace before `enter!` flips it), two follow-ups run for
     non-`racket` `#lang`s: a guarded `dynamic-require` of the module's
     `(submod ... configure-runtime)` if it `module-declared?`s one --
     that is what binds the language's REPL reader to
     `current-read-interaction` (e.g. rhombus's shrubbery reader; see
     the reader note below) -- and a re-install of the bitmap printer so
     it wraps whatever `current-print` `configure-runtime` set, keeping
     picts/bitmaps rendering at the REPL. These **must** sit inside the
     `begin`: once the namespace has switched, the REPL's
     `#%top-interaction` is the language's and rejects bare racket forms.

   The prelude ends with a trailing `"\n"` that delimits the submission;
   the submission reader (installed in the first form) consumes it as the
   line terminator, leaving the stdin ring empty for the program's first
   real `read-line`.

The single Interactions input box is both the REPL (Cmd/Ctrl+Enter
submits an expression) and the program's stdin (a submitted line
reaches a blocked `read-line`).

**Submission-oriented REPL reader (`web-repl/ide-repl`).** The stock REPL
reads *one* datum, then evaluates it. With the REPL's stdin doubling as
the program's stdin (one shared byte stream), that interleaving leaks:
submit `(foo)(foo)` where `foo` does `(read-line)`, and the first `foo`'s
read-line eats the trailing `(foo)` as its input instead of it being
evaluated. Two earlier symptoms had the same root cause -- the original
"`read-line` returns `""`" bug was the prelude's own trailing newline
leaking into the program the same way.

The fix replaces only the REPL's *read* step (`current-prompt-read`; the
stock loop still evals/prints/handles errors -- see `racket/repl`). The
new reader consumes a whole **submission** -- one line, or several lines
accumulated until the forms balance (`exn:fail:read:eof` => read more) --
parses *all* its top-level forms up front with the s-expression
`read-syntax`, and hands them to the REPL one at a time from a `pending`
queue (no extra `> ` between forms of one submission). Because the
submission's bytes are fully drained before any form runs, a `read-line`
during evaluation blocks for a *fresh* submission rather than eating the
rest of the line. That is DrRacket's separation: submitted expressions
and the input a running program reads are distinct streams in effect,
even though they ride the same ring. `(foo)(foo)` now prompts twice, once
per `foo`.

**Non-`racket` `#lang`s (rhombus, …).** That s-expression buffering is
correct only for languages whose surface syntax *is* s-expressions.
After `enter!` the REPL's namespace -- and so its `#%top-interaction` --
belongs to the module's `#lang`; for rhombus that macro wants a
*shrubbery* group, and handing it a Racket datum read by `read-syntax`
fails with `#%top-interaction: bad syntax in: (#%top-interaction . 4)`.
(`#lang datalog` has the same hole; it only looks fine because its output
comes from the module *body* on Run, not from REPL interaction.) So
`ide-repl` captures the default `current-read-interaction` at load and,
when a `#lang`'s `configure-runtime` (run in the `enter!` `begin` above)
has swapped in a different one, **defers to it** -- reading one
interaction form with the language's own reader instead of the s-expr
buffering. The buffering path is kept for the default reader, where the
shared-stdin interleaving problem it solves still applies; a language
reader does its own multi-line handling against the same ring.

**Waiting-for-input affordance.** Because the program's `read-line` and
the REPL's own prompt-read are the same fd, they are indistinguishable
at the I/O layer -- there is no way to label one block "stdin" and the
other "REPL". Instead a single honest signal covers both: `wasmfs-stdin.js`
flips the `shell_io_state` flag (`wasm_shell_io.c`, exported as
`_shell_io_state_addr`, posted to the page as `stateBase`) to `1` while
parked in `Atomics.wait` on the stdin ring, back to `0` once input is
available. `ide.js` polls it each animation frame (`reflectIoState`) and,
on a transition, highlights + focuses the input box with a "⌨ waiting for
input" label (or dims it with "running…" while busy). The flag lives in
the same shared linear memory as the rings, so no extra messaging is
needed; the page never has to guess from ring head/tail. A second Run
spawns a brand-new process -- fresh namespace, like DrRacket. Bitmaps
drawn via
`web-repl/display-bm` (or just evaluated bare, thanks to the printer)
and DOM pokes via `web-repl/dom` both land in this pane (inline
`<canvas>` per blit; see the `wasm_canvas`/`wasm_dom` notes).

A "not started" placeholder in the Interactions pane carries its own
Run button so the inert state isn't confusing. The persistent-worker
alternative (custodian shutdown + fresh namespace per Run, for sub-
second re-runs) is deferred; process-per-run matches the latency users
expect from comparable in-browser IDEs.

**Syntax highlighting (CodeMirror 5).** The Definitions editor is a
[CodeMirror 5](https://codemirror.net/5/) instance, overlaid on the
`<textarea id="editor">` via `fromTextArea`. The REPL input (`#input`)
deliberately stays a plain textarea -- it's a single submission line,
not an editing surface.

CM5 ships no racket mode; the editor uses the built-in **`scheme`**
mode, which covers every shared s-expression keyword (`define`,
`lambda`, `let`, `quote`, `cond`, ...) and renders Racket source
faithfully. Racket-only tokens (`#lang`, `#f`/`#t`, `#'`, `#%app`,
`#:keyword` args) render as plain text, which is fine. The mode is
chosen from the buffer's `#lang` line by `detectMode()` in `ide.js`:
lispy `#lang`s (`racket`, `typed/racket`, `scheme`, `at-exp`, ...)
map to `scheme`; non-lisp `#lang`s (`rhombus`, `datalog`,
`scribble`) map to `text/plain`. An unknown `#lang` defaults to
`scheme` (most are s-expr based). `detectMode` runs on
`loadExample` and on a 300 ms-debounced `change` event, so editing
the `#lang` line re-highlights.

The CM5 tree is **vendored** under `apps/ide/vendor/codemirror/` (not
CDN-loaded) and copied into `dist/codemirror/` by the `build-ide-js`
post-build hook (`build-examples.rkt`), alongside the examples splice.
The vendor dir lives outside `public/` so `collect-outputs` doesn't
ship it verbatim (it only copies flat files); the hook hand-copies the
subtree. Vendoring keeps `dist/` self-contained -- the page needs
COOP/COEP headers for SharedArrayBuffer, and a CDN dependency would
work but break the "ship one directory" property. The loaded pieces:
`lib/codemirror.{js,css}`, `mode/scheme/scheme.js`, and the
`matchbrackets`/`closebrackets` addons. `extraKeys` wires
Cmd/Ctrl+Enter to `restart()` and Tab to "insert two spaces",
replacing the textarea's old `keydown` handler; `matchBrackets` and
`autoCloseBrackets` are on. A small `.cm-s-default` palette in
`index.html` recolors tokens to the page's existing
`--accent`/`--accent-2`/`--muted` CSS variables so highlighting
matches the page rather than CM's defaults.

Serve and visit `http://127.0.0.1:8123/`.

### WIP: pre-generate `compiled/tpb32l`

`make wasm` now does this for the whole collection tree: its `wasm-setup`
stage runs the cross `raco setup` (`--cross-compiler tpb32l`, driven by
the host `RACKET=`), populating `racket/collects/**/compiled/tpb32l/`
before the link. The helper below predates that and remains useful for
compiling a single collection in isolation (e.g. when iterating on one
collection without a full `raco setup`).

From the repository root:

```sh
./racket/bin/racket -c ./racket/src/precompile-target-compiled.rkt reader
```

That currently compiles the `reader` collection and writes output like
`racket/collects/reader/lang/compiled/tpb32l/reader_rkt.zo` and its
matching `.dep` file. The `-c` is currently important in this working
tree: it prevents the host Racket process from loading stale
host-side `compiled/` artifacts that were polluted during earlier
cross-compilation experiments.

The helper also accepts explicit collections, `--all`, `--target`, and
`--build-dir`, but it should still be treated as experimental until it
has been exercised on a broader set of collections.

## Running the Racket test suite

`test/node/run-tests.sh` runs a slice of the
checked-in Racket core tests (the `.rktl` files in
`pkgs/racket-test-core/tests/racket/`) under the WASM/node build. Each
`.rktl` is a flat script that expects to be `load`ed inside a session
that already evaluated `testing.rktl`, so the script concatenates the
two and pipes them through `node racket.js`, then greps for the per-test
summary line. It runs against the orchestrator's clone (`.work/racket`)
by default; set `RACKET_WASM_CLONE` to point at a different built tree.

```sh
test/node/run-tests.sh             # default slice
test/node/run-tests.sh list hash   # by name
```

The default slice covers `control` (delimited continuations / prompts),
`contmark`, `generator`, `list`, `hash`, `string`, `bytes`, `for`,
`number`, `fixnum`, `flonum`, `math`, `chaperone`, `error`, and
`stxparam`. Results on tpb32l as of this writing:

| suite | tests | result |
|-------|------:|--------|
| control     | 30 | pass |
| contmark    | 677 | pass |
| generator   | 60 | pass |
| list        | 6,930 | pass |
| hash        | 984 | pass |
| string      | 3,295 | pass |
| bytes       | 16 | pass |
| for         | 522 | pass |
| number      | 76,267 | **1 fail** -- `(random 4294967087 prng)` returns a value off by exactly 2^31; a 32-bit signed/unsigned interpretation in the large-range path that is specific to `tpb32l`. The 76,000+ other arithmetic tests, including `random` in its normal range, all pass. |
| fixnum      | 104,970 | pass |
| flonum      | 93,831 | pass |
| math        | 717 | pass |
| chaperone   | 33,974 | pass |
| error       | 116 | pass |
| stxparam    | 38 | pass |

Approximately 322,000 expression tests pass total; the one functional
failure is the documented PRNG corner case above. (`param.rktl` and
`port.rktl` are intentionally not in the default slice: the former has
a cosmetic test that pattern-matches on the source-file name in an
error trace, which fails because we drive the harness through stdin;
the latter exercises subprocess/network features that rktio does not
implement on Emscripten and hangs.)

## Continuous integration

`.github/workflows/ci.yml` builds the IDE and runs its tests on every push to
`main` and on PRs. Two jobs:

- **`build`** — `racket build/main.rkt build` (the IDE is the default app),
  then the FFI draw-stack smoke (below), then it uploads `dist/` as the `dist`
  artifact. It sets up Racket/Node/emsdk, restores the content-addressed runtime
  cache, and — only on a cold build — builds + caches a host toolchain (see
  below) to pass as `--scheme/--racket`.
- **`browser-tests`** — `needs: build`; it calls the reusable
  `browser-tests.yml`, which downloads the `dist` artifact and runs the
  Playwright smoke suite (`test/browser/`) in headless Chromium.

**Why it's usually fast.** Cold builds are heavy (emsdk + a host threaded Chez +
the emcc link, ~30–45 min), but a build whose key inputs are unchanged is a
*clone-free, emsdk-free* cache assemble in seconds (`ensure-base-runtime!`
returns straight from the cache without touching the clone — see "the two build
layers"). `actions/cache` persists `.work/{runtime,sdk,app-payload}-cache` keyed
on the same inputs the build-key is computed from — `upstream.lock`, `patches/`,
`overlay/`, `wasm-deps/`, the `runtime-glue/` link-JS + `serve.rkt`,
`apps/ide/app.rkt`, and `packages/web-repl/`. Any change to those busts the
cache → a full cold rebuild; everything else (app/page/example/test edits) hits
it. The clone (`.work/racket`) is **not** cached — it's huge and mutated, and a
cold build re-`sync`s it on demand.

**FFI draw-stack smoke.** `test/node/run-draw-stack.sh` wraps
`draw-stack-test.rkt` into a pass/fail gate: it asserts `ffi-lib` resolves
`libcairo` and that a real `cairo_image_surface_create_for_data` + paint reads
back the expected `40 80 ff ff` pixel. It runs against the clone's node
`racket.js`, which exists **iff a cold build happened** — exactly when the
cairo/png/freetype linkage (`wasm-deps`/delta) could have changed. On a warm
cache-hit build the clone is absent and the runtime is byte-identical to a prior
green run, so the wrapper skips (exit 0). It does *not* assert on the test's
`dynamic-require racket/draw/unsafe/...` lines: the node base runtime bakes
`PKGS=`, so the draw-lib *collection* isn't present and those requires error
benignly (the live cairo paint is the real end-to-end proof).

**Host toolchain for the cold path.** A cold build needs a native *threaded*
host Chez (`--scheme`, the cross-compiler host) and a host Racket whose *version*
matches the pin (`--racket`, so the cross-server xpatch loads). Neither exists on
a stock runner, and the orchestrator can't bootstrap Chez itself: `sync`'s
`clean -ffdx` strips `boot/pb`, and the pinned upstream *vendors* `ChezScheme`
as a tree **without** `boot/` (so `build.zuo`'s pb path is unavailable). So CI
builds both from `racket/racket` at the pin SHA. There is **no BC fallback** in
Chez 10.x, so `racket/src/configure` needs `ChezScheme/boot/pb` for its CS-only
bootstrap; the workflow provisions it from `racket/pb`, picking the branch that
matches the vendored `scheme-version` (`#x0a050001` → 10.5.0.1 →
`v10.5.0-pre-release.1-<rev>`, which carries `petite.boot`/`scheme.boot`). The
in-tree `racket/src` build then produces a version-matched `racket/bin/racket`
(the `--racket`), but it only leaves the **pb** (portable-bytecode) bootstrap
scheme — not a native threaded one — so the workflow *also* runs a standalone
`cd racket/src/ChezScheme && ./configure --threads && make`, yielding the
threaded host Chez at `racket/src/ChezScheme/<mach>/bin/<mach>/scheme` (the
`--scheme`). The workflow caches that tree on the pin SHA
(it rarely changes) and passes `--scheme/--racket` into the orchestrator. The
host build is gated on the orchestrator cache *missing* (a warm assemble is
toolchain-free, so it's skipped then). The **first CI run is cold**: the host
toolchain build **plus** the orchestrator's own cross-build; both are cached
afterward. (Locally you sidestep all this by passing a prebuilt
`--scheme`/`--racket`, which is why the in-orchestrator Chez bootstrap was never
exercised.) On a pin bump that changes the Chez version, the `racket/pb` branch
is re-derived automatically from the new `scheme-version`.

**emcc link arg-length (Linux portability).** The `wasm` link force-keeps the
dep symbols cairo/png/freetype register (`-Wl,-u,<symbol>`) — thousands of them,
read from `wasm_deps_uflags.txt`. Inlined onto the command line they make it
~240 KB, and `build.zuo` runs the link via `shell/wait` (→ `sh -c "<cmd>"`); a
single argv string that large exceeds Linux's `MAX_ARG_STRLEN` (128 KB) and the
link dies instantly with zuo's "exec failed". macOS has no per-arg cap, so it
worked locally. Fix (in `patches/racket/src/cs/c/build.zuo.patch`): pass that
file to emcc as a `@response-file` instead of inlining it, keeping the command
short. This touches the **delta**, so it shifts the build-key (the committed
cache entry changes); it was hand-edited into the patch (re-running the fork
extractor would need the same edit on the fork side).

**Deploy** to Netlify (COOP/COEP headers already in
`apps/ide/public/netlify.toml`) is intentionally left as a commented `deploy`
sketch in `ci.yml`; wire it as a `needs: [build, browser-tests]` gate once the
suite is trusted.

## Performance vs. native Racket CS

`test/node/perf-bench.rktl` is a single-threaded, CPU-bound
microbenchmark shared by both runtimes. It is timed *internally* with
`current-process-milliseconds` / `current-inexact-milliseconds`, so the
WASM runtime's large startup and `.data` mount cost is excluded -- the
numbers below are steady-state compute only. Run it by piping the script
through either runtime's stdin REPL:

```sh
# native host racket
racket < test/node/perf-bench.rktl | grep BENCH
# WASM under node (against the orchestrator's clone)
node .work/racket/racket/src/build/cs/c/wasm/racket.js < test/node/perf-bench.rktl | grep BENCH
```

Measured on an Apple M3 Pro, node v22.16.0 (arm64). Native is
`minimal-racket` v9.2.0.5 [cs], a 64-bit build; WASM is this tree's
tpb32l target. Each figure is wall-clock ms averaged over two runs,
with the per-kernel iteration count folded in (the script repeats cheap
kernels so each does ~100 ms+ of native work):

| kernel | what it stresses | native | WASM | WASM / native |
|--------|------------------|-------:|-----:|--------------:|
| `fib33`        | non-tail integer recursion / call overhead | 212 ms | 7,620 ms | ~36x |
| `tak.24.16.8`  | deep recursion                              |  97 ms | 3,168 ms | ~33x |
| `ack.3.9`      | recursion + branching                       | 173 ms | 6,126 ms | ~35x |
| `sum-loop-50M` | tight counted loop, integer accumulate      | 268 ms | 19,801 ms | ~74x |
| `fsum-20M`     | flonum divide/add in a loop                 | 648 ms | 12,772 ms | ~20x |
| `sieve-10M`    | vector read/write, memory-bound             | 617 ms | 8,681 ms | ~14x |
| `list-sort-1M` | cons allocation + `sort`                    | 372 ms | 12,669 ms | ~34x |
| `string-1M`    | `number->string` + output-string port       | 458 ms | 3,973 ms | ~9x |

Takeaways:

- **Roughly an order of magnitude, kernel-dependent.** Call- and
  allocation-heavy code lands around 30-36x; memory-bound and
  port/string-bound code does markedly better (9-14x). The benchmark
  forms are `eval`'d at the REPL, so they run as interpreted Chez `pb`
  (portable bytecode) -- pb has no JIT, and the boot-image `pbchunk`
  pass only covers precompiled runtime code, not freshly-eval'd user
  code. The gap is therefore dominated by interpreter dispatch per
  bytecode op: kernels that do more work per op (`sieve`, `string`)
  amortize that better than kernels that are mostly calls (`fib`, `ack`).

- **`sum-loop-50M`'s 74x is a 32-bit artifact, not a loop-speed result.**
  tpb32l fixnums are 32-bit (~30-bit payload), so the accumulator
  (reaches 1.25e15) spills into bignums almost immediately on WASM, while
  the 64-bit native build keeps it a fixnum throughout. The kernel is
  therefore measuring bignum add overhead on WASM vs. fixnum add on
  native -- a real characteristic of the port (bignums appear far
  sooner), but not an apples-to-apples loop comparison. Keep the 32-bit
  fixnum boundary in mind when reading any integer-heavy figure; see also
  the `number` PRNG large-range note in the test-suite section, which has
  the same 32-bit root cause.

These are interpreted-pb vs. native-compiled numbers. The realistic
ceiling for the WASM side is whatever AOT-compiling user code (a
`pbchunk` pass over the eval'd forms) or a Wasm-GC-targeted Chez backend
would buy -- both out of scope for the current `pb`-interpreted port.

## Preloading additional Racket packages

`/collects` (the core distribution) is preloaded automatically; everything
else (anything under `racket/share/pkgs/`) has to be opted in.

### The mechanism

Racket finds packages through `links.rktd` files. The installation-scope
one is discovered at `<config-dir>/../share/links.rktd`; our
`main_em.c` sets `<config-dir>` to `/etc`, so that resolves to
`/share/links.rktd`. Each entry of the form
`(root (#"pkgs" #"<name>"))` says "treat everything under
`/share/pkgs/<name>/` as if it were on the collection root path."

Both that links file and the package tree are **build artifacts**, not
hand-maintained: `racket/share/links.rktd` and `racket/share/pkgs/` are
git-ignored and populated by the in-tree package install (main.zuo
`install-base-pkgs`, run on the wasm path before `wasm-setup`). The
wasm link (`cs/c/build.zuo`, `share-preloads`) then preloads them
**wholesale**:

```
--preload-file racket/share/pkgs@/share/pkgs
--preload-file racket/share/links.rktd@/share/links.rktd
```

plus every in-tree package the links file points at under `/pkgs/<name>`.
Not all links entries live under `share/pkgs`: catalog packages are
*copied* there (a `(root (#"pkgs" #"name"))` entry, covered by the
wholesale `share/pkgs` preload), but in-tree packages are *linked in
place* and show up as `static-root` entries (the core
metapackages/libraries -- `base`, `racket-lib`, `compiler-lib`, `zo-lib`,
...) or named-collection entries (any in-tree local source package), all
with a `(up up #"pkgs" #"name")` path that
resolves -- relative to the links file's `/share` dir -- to
`/pkgs/<name>`. Their source is the in-tree `<root>/pkgs/<name>`. Racket
errors reading `links.rktd` if any referenced dir is absent, so
`share-preloads` **parses `links.rktd`** and preloads each `/pkgs/<name>`
it finds (`links-pkgs-roots` in `cs/c/build.zuo`) rather than hardcoding a
list -- adding a package whose deps drag in new in-tree libraries needs no
edit to the link step. So there are no per-package emcc flags: anything
the install dropped under `racket/share/pkgs` or linked into `/pkgs` with a
links entry ships automatically. (The old `share-links.rktd` +
per-package `--preload-file` scheme is gone.)

### Adding a new package

The selector is the build's **`PKGS`** variable (see `buildit.sh`:
`PKGS="draw-lib web-repl"`). `install-base-pkgs` catalogs `./pkgs`
(every directory there is a source package, via `pkg/dirs-catalog`),
then runs `raco pkg install <REQUIRED_PKGS> <PKGS>` with
`--deps search-auto`, so transitive deps come along.

1. **Local package?** The orchestrator route is **`#:local-pkgs`** (a path
   anywhere on disk), `--copy`-installed into `share/pkgs` -- the clone stays
   pure upstream-delta. See "Local app packages" above; this is how `web-repl`
   (now at `packages/web-repl`) ships. (The older in-tree route -- drop the
   source under the clone's `pkgs/<name>/` so `pkg/dirs-catalog` catalogs it and
   add `<name>` to `PKGS` -- still works for packages that genuinely live in the
   tree.) **Catalog package** (like `draw-lib`)? Skip this -- it resolves from
   the configured catalog. Either way, check `info.rkt`'s `deps` for
   native-library needs (see "FFI dependencies" below).
2. Add `<name>` to `PKGS` in the build invocation.
3. Rebuild (`make wasm` / `buildit.sh`). The install writes
   `racket/share/pkgs/<name>` + its links entry; the link preloads the
   tree. `(require <name>)` now works in the image.

### Trimming doc-only build-deps

`raco pkg install --deps search-auto` resolves a package's `build-deps`
(docs/tests) as well as its runtime `deps` -- `pkg/private/install.rkt`'s
`get-all-deps` appends both unconditionally, and there is **no**
`--no-build-deps` flag. `--no-docs`/`-D` only stops docs from *building*;
the build-deps are still fetched and compiled. `--binary-lib` only strips
files *after* staging; it doesn't change which deps get resolved. So for a
monolithic catalog package whose `build-deps` drag in a large tree (the
classic offender is `racket-doc`), the only lever is the package
*metadata*.

The general fix is **binary-only packages via the catalog** (next section): a
`binary-lib` strip drops `build-deps` from every package's `info.rkt`, so the
final consume from the binary catalog resolves only runtime `deps` -- no
per-package work. **Use that, not a vendored trim.**

Historically (before the binary preload existed) the only lever was to
**vendor a hand-trimmed copy** as a local package: drop `build-deps` from
the copy's `info.rkt` so it shadows the upstream catalog entry. The lone
example was **`datalog`** (`pkgs/datalog/`), whose `build-deps`
(`racket-doc`, `scribble-lib`, `rackunit-lib`) were the entire bloat. That
vendored fork has been **removed** -- `datalog` now installs from the
upstream catalog and the binary strip prunes its build-deps like any other
package. Don't reintroduce per-package vendoring for build-dep trimming.

### Binary-only packages via the catalog

Shrinking the payload below the ~70 MB source ship means **binary-only**
packages: `.zo`-only, source + docs stripped, `build-deps` pruned. This now
lives in the **clone-free consume** (`build/consume.rkt`), not the old
clone-bound `make wasm-binary-pkgs` path (superseded; see below). The consume's
first pass (`refresh-pkg-catalog!`) re-emits each staged, in-place
tpb32l-compiled package through `pkg/strip`'s `generate-stripped-directory` into
an SDK-keyed **dirs-catalog** of stripped package *directories*
(`work-dir/pkg-catalog/<sdk-key>/build-catalog/`); the second pass installs the
app's closure *from* that catalog. `pkg/dirs-catalog` over stripped dirs is used
rather than `raco pkg create` archives -- `generate-stripped-directory` already
emits a directory, so there is no archive/unarchive round-trip, and the repo
already builds dirs-catalogs.

`STRIP-MODE` (a constant in `consume.rkt`) is the size knob, and the two modes
have very different host-safety profiles:

- **`'built`** (initial/default) -- a near-pure copy: it drops only doc
  `.css`/`.js` + `synced.rktd`, and rewrites the package-level `info.rkt`. It
  **never reads or loads a `.zo`**, so it is completely host-safe on tpb32l
  bytecode. Ships source, so the payload size is unchanged (~70 MB) -- it exists
  to prove the catalog pipeline end-to-end before the strip.
- **`'binary-lib`** (default) -- the real win: drops every `.rkt`/`.ss` that has a
  sibling `.zo`, plus `tests`/`scribblings`/`doc`/`.scrbl`/`.dep`, sets
  `assume-virtual-sources`, and prunes `build-deps` from the rewritten `info.rkt`.
  This mode calls `fixup-zo`, which `(read)`s each module `.zo` with
  `read-accept-compiled` (to strip test/doc submodules), so the strip **must run
  under the cross xpatch** -- a plain host racket traps decoding tpb32l fasl
  (`fasl-read: incompatible ... machine-type 'tpb32l`). That is why the strip runs
  as a **subprocess** (`build/strip-catalog.rkt`) of the host racket with the same
  cross flags as the install (`-G <etc> -MCR <hostzo>:<xtgt> --cross-compiler
  tpb32l <cc>`): under it, `read` decodes the target `.zo` exactly as the old
  `make wasm-binary-pkgs` path did. `(strip-binary-compile-info #f)` keeps the
  strip from `managed-compile-zo`-ing the rewritten `info.rkt` on the host (which
  would inject host bytecode); the final cross `raco setup` compiles it for tpb32l.
  On the IDE closure this took the payload 67 MB -> ~45 MB and the install set
  63 -> 52 packages (build-only deps pruned).

Both the strip and `create-dirs-catalog` call `get-info/full`, which **loads** a
package's `compiled/info_rkt.zo` if present -- and a tpb32l (or wrong-version) one
traps the host orchestrator (`fasl-read: incompatible ... machine-type 'tpb32l`).
So `harvest!` **skips `info_rkt.zo`/`.dep`**: with them absent, `get-info` falls
back to the always-present source `info.rkt` everywhere (strip, dirs-catalog, and
`pkg-link-entry`), host-safe under any orchestrator version. `info.rkt` is
setup/pkg metadata, never loaded at program runtime, so the payload doesn't need
its `.zo` (the final cross `raco setup` regenerates it for tpb32l if wanted). This
is the in-process equivalent of the old path's `build/zo` machine-independent
mirror.

The catalog is **keyed by the SDK** (delta + `wasm-deps`) because its tpb32l `.zo`
depend on them, and it **accumulates**: each app's packages are staged + stripped
once (`--skip-installed` keeps re-runs incremental) and the final consume selects
just that app's closure out of it. A `STRIP-MODE` change is detected via a
`.strip-mode` sentinel and rebuilds the stripped dirs. `build-deps` pruning is
automatic in `'binary-lib`: with the local binary catalog as the install source,
`--deps search-auto` walks only runtime `deps`, so build-only packages
(`racket-doc`, `scribble-lib`, `rackunit-lib`, …) are never fetched -- the general
replacement for per-package vendoring (the old `datalog` hand-trim, long removed).

**Removed clone-bound path.** An earlier mechanism did the same strip *inside*
the clone -- `make wasm-binary-pkgs` (`racket/src/build-wasm-binary-pkgs.rkt`)
produced a `.wasm-pkgs-cache/catalog` that `main.zuo`'s `install-base-pkgs`
consumed, driven by `build/pkgs.rkt`'s `rebuild-binary-catalog`. The SDK-keyed
catalog made it redundant, so it has been **removed** (the make target, the
overlay strip script, the `install-base-pkgs` binary branch, and the orchestrator
command + module). Its `build/zo`-root trick (a machine-independent host-loadable
mirror so `get-info/full` could run each `info.rkt` while the in-place `compiled/`
was tpb32l) addressed the same host-trap as this section's
`strip-binary-compile-info #f` + the `harvest!` `info_rkt.zo` skip. NOTE: the
removal hand-edits `patches/main.zuo.patch` + `patches/Makefile.patch`, so a
re-run of `build/extract-from-fork.rkt` against an *unmodified* fork would
reintroduce the make target (the overlay script is guarded by the extractor's
skip list); reconcile by cleaning the fork if you ever re-extract.

**Notes / traps (catalog path):**

- **`-lib` packages, not metapackages, in `PKGS`.** A metapackage like `pict`
  (vs `pict-lib`) or `draw` (vs `draw-lib`) is a catalog-only entry that just
  `implies` an implementation package plus a `-doc`; it has no directory, so it
  never enters the dirs-catalog and the final consume fails with `cannot find
  package on catalogs`. It also drags its `-doc` sibling's whole build-dep closure
  into the staging install. Use the `-lib` package, matching `draw-lib`.
- **List `-lib` package metadata is the only build-dep lever.** `--deps
  search-auto` resolves `build-deps` as well as runtime `deps` and there is no
  `--no-build-deps` flag; `--no-docs` only stops docs from *building*. So the
  staging pass still fetches build-deps -- the `'binary-lib` strip is what prunes
  them from the catalog `info.rkt` so the *final* consume resolves runtime `deps`
  only.

### Packages as a separate data file

The package tree is the part of the preload that changes most often (every
`PKGS` edit), and re-linking just to repackage it is the slow step. So **both**
surfaces ship the package payload as a **separate Emscripten data file** —
`share.data` + its loader `share.data.js` — instead of baking it into the emcc
link. Changing packages then means: re-install + repack (`pack-pkgs`),
**no relink** (and, since the packer is pure Racket, **no emsdk** either).

The split (in `cs/c/build.zuo`, the `wasm` target): the link preloads only
`core-preloads` (boot images + `/collects` + `/etc`, which change only on a
Racket-version rebuild) into the MEMFS, for both the node (`racket.*`) and
browser (`racket-web.*`) surfaces. The package tree is no longer referenced in
the link at all.

The orchestrator's `pack-share-data` (`build/pack.rkt`) is a **pure-Racket
equivalent of `file_packager.py`** — it needs no emsdk, just racket. It emits
`share.data`/`share.data.js` into the wasm out dir from the installed tree: the
wholesale `/share/pkgs`, `/share/links.rktd`, and every in-tree `/pkgs/<name>`
the links file points at (the `links-pkgs-roots` parse of `links.rktd` for
`(up up #"pkgs" #"name")` entries — formerly in `build.zuo`, now living **only**
here). The artifact is dead simple: `share.data` is the package files
concatenated, and `share.data.js` carries each file's `[start,end)` + the
directory tree and replays them into MEMFS via the documented preload ABI below.
It is wired into `build` (the base-runtime pack, before `collect-outputs`) and
exposed standalone as `racket build/main.rkt pack-pkgs` for the
repack-without-relink path.

> The pure packer was verified equivalent to `file_packager.py` three ways: the
> two `share.data`s are byte-size-identical (same file set/bytes; only the
> *order* within the blob differs — `.data` and `.data.js` are a matched pair, so
> order is immaterial); executing **both** generated loaders against a mock
> `Module` builds a byte-identical virtual FS (same paths, same per-file hashes);
> and the real browser IDE boots on the pure `share.data` and loads packages from
> it (`racket/draw`, `pict`, `datalog`). The browser test harness
> (`test/browser`, `tools/eval.mjs`) drives that last check.
>
> One sharp edge the loader must respect: it does **all** FS work
> (`FS_createPath`/`FS_createDataFile`) inside its `preRun` callback, never at
> import time — `shell-worker.js` `importScripts`es it *before* `racket-web.js`,
> so the runtime and those hooks don't exist yet when the loader is first
> evaluated. (A loader that calls `FS_createPath` at import silently hangs the
> worker.)

Both surfaces emit and share **one** `share.data`/`share.data.js` pair; the
generated loader is environment-aware (browser `fetch` vs node `readFileSync`),
and `Module.locateFile` resolves `share.data` next to the script in either case.

The loader reproduces emscripten's **`--use-preload-cache`** (ported from
`tools/file_packager.py`'s `if options.use_preload_cache:` branch — the
`openDatabase`/`checkCachedPackage`/`fetchCachedPackage`/`cacheRemotePackage`
helpers and the try/catch preload flow, trimmed to this loader's FS-replay
shape). After the first download `share.data` is cached in IndexedDB
(`EM_PRELOAD_CACHE`, the upstream DB name/schema/64MB-chunking) keyed on a
content hash — `package_uuid`, embedded in the loader's manifest by
`data-package-uuid` in `build/pack.rkt`. A matching cache entry is served from
IndexedDB with no network; a mismatch (the bytes changed) re-fetches and
re-caches. The cache path is **browser-only and guarded**: the node and
`getPreloadedPackage` paths bypass it, a missing `indexedDB` falls straight
through to a plain `fetch`, and any IDB error is caught and falls back to a
direct fetch — so loading never *depends* on the cache and node never hits the
`indexedDB`-undefined throw. (file_packager uses sha256 for the uuid; Racket
ships no built-in sha256 and the value is an opaque equality token, so the pure
packer uses sha1, prefixed `sha1-` to keep the scheme explicit.)

Runtime wiring loads `share.data.js` so its loader pushes onto `Module.preRun`
and gates `run()` via `addRunDependency` until `share.data` is in MEMFS — so
`/share/pkgs` is present before `main()`, exactly as when it was in-link:

- **Browser:** `shell-worker.js` does `importScripts("./share.data.js")`
  **before** `importScripts("./racket-web.js")`. The loader runs in the worker's
  global scope, where its self-declared `var Module` binds to the `self.Module`
  the worker set up.
- **Node:** `racket.js`'s `Module` is module-scoped (not global) and there is no
  `importScripts`, so the baked-in `--pre-js` `node-load-share.js` reproduces the
  worker's environment: it puts this module's `Module` and `require` on
  `globalThis`, then runs `./share.data.js` via **indirect** `eval` (global
  scope). Direct eval would not do — the loader's own `var Module` would shadow
  ours and disconnect. Loading at runtime (not as another `--pre-js` payload) is
  what keeps the packages out of the link.

Two runtime methods the externally-loaded loader reaches by name —
`FS_createPath` and `FS_createDataFile` — plus `addRunDependency` /
`removeRunDependency` are added to each link's `-sEXPORTED_RUNTIME_METHODS` (the
two `RunDependency` helpers are also used by the share.data loader itself; the
in-link core loader uses minified locals and needs none exported). If the loader references a method not
yet exported, boot aborts with an "X is not exported" error — add it to that list
and rebuild. (The pure packer deliberately uses only these four, the same set
`file_packager` reached for, so the export list is unchanged.)

### A `web-repl` helper collection

`racket/collects/web-repl/` is the home for the WASM browser-surface
helpers, so IDE users `(require ...)` instead of pasting
`vm-eval` blobs. It is a plain **collection**, not a package: dropping
it under `racket/collects` puts it on the default collection path and
the wasm link preloads `/collects` wholesale, so it ships with **no
`PKGS` / links / catalog machinery at all** (deliberately the simple
route for now -- revisit if these helpers ever need their own
versioned package). Modules:

- `web-repl/display-bm` -- `(display-bm bm)` blits a racket/draw
  `bitmap%` to the page (one inline `<canvas>` per call).
- `web-repl/canvas` -- raw `canvas-blit-{rgba,argb,bgra}` over the
  three `wasm_canvas_blit*` channels.
- `web-repl/dom` -- `(dom-eval js)`, the synchronous DOM RPC.
- `web-repl/http` -- `(http-get url)` -> `(values status body)`.
- `web-repl/print` -- `install-bitmap-printer!`, a `current-print`
  hook that renders bitmap-valued results via `display-bm` (the IDE
  installs it as a prelude). Bitmap detection is duck-typed on
  `get-argb-pixels` (only `racket/class`); picts are rendered with
  `pict?`/`pict->bitmap`/`inset`, bound via **`dynamic-require` at module
  load** (not a static `require`) -- see "pict printing" below.
- `web-repl` (`main.rkt`) re-provides all five.

> **pict printing: `dynamic-require`-at-load + a 1px inset.** Two
> non-obvious constraints shape `web-repl/print`:
>
> 1. **Why not `(require pict)` / `(require pict/convert)` statically.**
>    `pict-balloon2` (pulled transitively by `rhombus-pict-lib`) is a
>    *single-collection* package literally named `pict`
>    (`(define collection "pict")`, `assume-virtual-sources #t`). In the
>    cross `raco setup` that compiles the local `web-repl` source package,
>    its directory shadows the `pict` collection: resolving any `pict` /
>    `pict/convert` module path lands in `pict-balloon2/<x>.rkt` (which
>    doesn't exist) and errors -- and because `assume-virtual-sources`
>    makes setup *believe* the file is there, it doesn't fall through to
>    `pict-lib`. Worse, `run-install`'s benign-error tolerance
>    (`consume.rkt`, the "packages installed, although setup reported
>    errors" launcher-template case) swallows this *real* compile error,
>    so the build silently ships `share.data` **without** `print.zo` /
>    `main.zo`. Binding the entry points through `dynamic-require` (a
>    runtime call) means compiling `web-repl` never resolves `pict`; the
>    runtime module resolver in the packed image resolves it fine. (If you
>    touch this and see picts stop rendering, check the manifest:
>    `grep -o 'web-repl/compiled/print_rkt.zo' dist/share.data.js`.)
> 2. **Why `dynamic-require` at *module load*, not at print time.**
>    Deferring the `dynamic-require` into the `current-print` lambda trips
>    a draw-lib init-order bug under WASM (`cairo-lock-name` referenced
>    before `cairo.rkt`'s instance initializes `pango.rkt`'s import) when
>    draw-lib is first instantiated lazily mid-REPL. Resolving the
>    bindings at module instantiation -- the prelude loads `web-repl/print`
>    before `enter!` runs the user program, in the clean REPL namespace --
>    instantiates cairo/pango once, in order, exactly as the old static
>    `(require pict)` did.
> 3. **The 1px inset.** `pict->bitmap` sizes the bitmap to exactly
>    `ceiling(width) x ceiling(height)`, so a border drawn on the pict's
>    bounding edge (e.g. `frame`) sits on the last pixel boundary. The
>    WASM cairo build's `'aligned` snapping rounds that stroke *outward*
>    and clips the right/bottom border (desktop cairo rounds inward, so it
>    shows there). Rendering `(inset v 1)` gives a 1px transparent margin
>    so the edge stroke always has a pixel column to land in.

Each wraps a `Sforeign_symbol`-registered primitive through
`ffi/unsafe/vm` (`vm-eval` + `foreign-procedure`), the only FFI path
that works without dlopen (see "Calling WASM-specific primitives from
Racket"). The `vm-eval`s run at module *instantiation* -- inside the
wasm image, where the symbols exist -- so the host/cross `raco setup`
that only compiles these to `.zo` never trips on them. Nothing in the
collection requires `racket/draw`: the primitives are reached by name
and `display-bm` takes its `bitmap%` by argument (the user's drawing
code is what requires `racket/draw`).

### FFI dependencies

Most non-trivial packages bind to native libraries via `ffi-lib` +
`get-ffi-obj`. With the Phase C shim (rktio dll hooks + Chez's
`Sforeign_lookup`, see boot.c) any `(ffi-lib "<name>")` succeeds with
a sentinel handle; the actual gate is whether each `get-ffi-obj`
name was registered with `Sforeign_symbol`.

For libraries we *do* link (Cairo, libpng, FreeType), the
`DEP_SYMBOLS_MODE=scrape` line in the recipe pulls every public
symbol out of the static archive via `llvm-nm`; the recipe pattern
in §2 has examples.

For libraries we *don't* link yet (libjpeg, expat, fontconfig,
pango, glib, harfbuzz at the time of writing), `(require <pkg>)`
fails at module load with `ffi-obj: could not find export from
foreign library, name: <C-symbol>`. That error names exactly the
missing entry point; the fix is to add a recipe for the underlying
library and relink. `wasm-deps/deps/cairo.sh` is the template for
a meson recipe with symbol scraping.

A stub mechanism exists for the few cases where binding to a no-op
unblocks load (`racket/src/cs/c/wasm_stubs.c` provides
`wasm_unimplemented_stub` and `wasm_passthrough_stub`; the
commented-out block in `wasm_extras.inc` shows the pattern). It is
not a substitute for actually linking the library: WASM
`call_indirect` is signature-typed, so a stub only works for
callers whose FFI signature matches the stub's C signature -- which
is rarely true for non-trivial APIs.

### Status

**`(require racket/draw)` works.** Tier 2's full native dep tree is
linked (Cairo + libpng + FreeType + libjpeg-turbo + pcre2 + expat +
GLib + FontConfig + HarfBuzz + Pango, ~12 archives totalling several
megabytes of static code). `make-bitmap` returns a real `bitmap%`,
`make-dc` returns a working `bitmap-dc%`, and `(send dc draw-ellipse
...)` / `(send dc draw-rectangle ...)` execute through Cairo's
software backend without error. The wasm grew from ~26 MB to ~32 MB
and the .data from ~87 MB to ~95 MB.

> **Text rendering -- works on node AND the browser.** Drawing (geometry)
> works as above. *Text* (`get-text-extent`, `draw-text`, `pict`'s `text`)
> required three function-pointer/signature fixes plus fontconfig
> provisioning (node), and then `-sPROXY_TO_PTHREAD` + two glue/runtime
> tweaks (browser). All are **merged into this repo's delta** (re-homed from
> the old fork branch `wasm-text-fonts-wip`). See the "Text / Pango" section
> just below for the node fixes and "Browser text" for the PROXY fix and where
> each change lives. The browser IDE now renders Pango text inline (verified in
> headless Chromium); `web-repl/text`'s Canvas-2D path remains available as a
> font-free alternative.

A handful of libm / libc essentials (fmod, pow, sqrt, sin/cos/tan,
atan2, exp/log, floor/ceil/round/trunc, fabs) are registered in
`wasm_extras.inc` because draw-lib's color math reaches them via
`(ffi-lib #f)` (look in any opened library). The Emscripten sysroot
links the math library statically; the Sforeign_symbol entries
just expose the addresses to `Sforeign_lookup`.

Stubs in `wasm_stubs.c` cover the small set of libc functions
GLib/FontConfig reference but the wasm32-emscripten sysroot doesn't
ship: copy_file_range, splice, fallocate, close_range, free_sized,
free_aligned_sized, pthread_setname_np, pthread_getaffinity_np,
__sched_cpucount, posix_spawnp, res_query, g_inotify_file_monitor_get_type,
getprogname. None get called on the drawing path; they exist so
wasm-ld can satisfy references.

### Text / Pango: three function-pointer-cast traps + fontconfig (node)

Text -- `racket/draw`'s `get-text-extent`/`draw-text`, and anything on them
(`pict`'s `text`) -- used to die with `RuntimeError: null function or
function signature mismatch`. Pure geometry was always fine; only the font
path trapped. All three root causes are the **same class of bug**: a function
pointer called through a signature that doesn't match the callee's real wasm
type. Native ABIs tolerate this; WebAssembly's `call_indirect` is strictly
type-checked and traps. Empirically only an **argument-count** mismatch traps
(a return-type-only mismatch does not). The trap surfaced at three layers,
peeled one at a time:

1. **GObject `class_init`** (GLib). The first font call,
   `pango_cairo_font_map_new` -> `g_object_new`, registers the font-map's
   GObject type hierarchy; GLib's `GTypeInfo`/`G_DEFINE_TYPE` cast a narrowly
   typed `class_init` (`void (SomeClass*)`, wasm `vi`) to the generic
   `GClassInitFunc` (`void (gpointer, gpointer)`, wasm `vii`). **Fix:**
   backport the gobject subset of the Fluendo glib WASM fork's "Fix function
   pointer cast issues" commit as `wasm-deps/deps/glib-fpcast.patch`, applied
   in `wasm-deps/deps/glib.sh`'s `wasm_dep_patch` (idempotent, guarded on the
   new `class_data` arg). Pango's own types, compiled against the patched
   `gtype.h`, are fixed too. No `-sEMULATE_FUNCTION_POINTER_CASTS`.
2. **GObject `iface_init`** (GLib). `G_IMPLEMENT_INTERFACE` only drops the
   cast; it can't adapt a consumer's 1-arg `iface_init`, so `gtype.c`'s
   `type_iface_vtable_iface_init_Wm` still called it as a 2-arg
   `GInterfaceInitFunc`. Every `iface_init` on this stack is genuinely 1-arg,
   so `glib.sh` additionally `sed`s `gtype.c`'s call site to invoke it through
   its real 1-arg signature (covers all consumers without patching them).
3. **`cairo_font_options_copy`** (draw-lib, a genuine upstream Racket bug). It
   is `cairo_font_options_t* (const cairo_font_options_t*)` -- **one** arg
   returning a pointer -- but `cairo.rkt` declared it
   `(_cfun _cfo _cfo -> _void)` (two args, void). `set-font-antialias` calls
   it only `(when o ...)` where `o` is the context's existing font options;
   that is usually NULL (so it never bit native or a fresh context) but is
   non-null on the real dc path. **Fix:** rebind it 1-arg `-> _cfo` with the
   `allocator` wrap (like `cairo_font_options_create`), and in `dc.rkt` use
   `(if o (cairo_font_options_copy o) (cairo_font_options_create))`.

**How fix #3 is carried (catalog source patch).** This repo fetches `draw-lib`
from the network catalog via the clone-free consume rather than vendoring it,
so the fix lives as `package-patches/draw-lib/cairo-font-options-copy.patch`.
`build/consume.rkt`'s `refresh-pkg-catalog!` applies it to the *staged*
`draw-lib` source after the `--no-setup` fetch (no compile yet) and then runs a
single `raco setup --pkgs <whole staged closure>` (`setup-pkgs!`, same host-safe
`-MCR`/`-G` cross discipline), so the built catalog archives **patched**
`tpb32l` `.zo` and every dependent compiles against the patched source
(`discover-pkg-patches` scans `package-patches/<pkg>/*.patch`). The patch dir is
folded into the **delta-hash** (`build/cache.rkt` / `config.rkt`
`package-patches-dir`), so editing it yields a fresh SDK/catalog/payload. (The
real fix is upstream in `racket/draw`, worth a PR.)

> **Two traps that cost time here, both now handled:**
> - **Apply with `patch`, not `git apply`.** The staged tree lives under
>   `.work/` (inside the racket-wasm git repo). `git apply` is repo-aware: it
>   resolves paths against the repo *toplevel*, not the cwd, so it silently
>   no-ops (exit 0!) on the gitignored staging dir. `apply-pkg-patches!` uses
>   `patch -p1` (repo-agnostic, cwd-relative) with a **forward dry-run** as the
>   idempotency probe (exit 0 = not yet applied; nonzero + "previously applied"
>   = skip; other nonzero = the patch drifted from the package version → error).
>   BSD `patch -R --dry-run` succeeds on *both* states, so it can't detect
>   already-applied.
> - **Recipe edits must invalidate the dep cache.** `wasm-deps/deps.sh`'s
>   `wasm_dep_manifest_hash` now folds in the recipe `.sh` + its sibling
>   `.patch` files; before this, editing a recipe's `wasm_dep_patch` (e.g.
>   adding the glib fpcast patch) left the dep "up to date" and silently linked
>   the **unpatched** library. **Cross-dep caveat:** the manifest tracks only a
>   dep's *own* recipe, so patching a dependency's *headers* (glib's `gtype.h`)
>   does not auto-rebuild its consumers (pango). The fpcast change here forced a
>   full stack rebuild (the manifest *formula* changed), which recompiled pango
>   against the patched glib in leaf→root order; a future targeted glib-only
>   edit must force-rebuild the GObject consumers by hand.

**A fourth cast trap, surfaced by the GUI backend: `cairo_pattern_reference`.**
The same class of bug bit the mred/wasm backing-store flush path (`backing-draw-bm`
in `mred/private/wx/common/backing-dc.rkt`, reached when a canvas paints).
`cairo_pattern_reference` is `cairo_pattern_t* (cairo_pattern_t*)` -- it returns
the pattern -- but `cairo.rkt` bound it `(_cfun _cairo_pattern_t -> _void)` with a
`(retainer cairo_pattern_destroy car)` wrap (the retainer extracts the *arg* via
`car`, so the ignored return was fine on native). Under wasm's typed
`call_indirect` the `(i32)->()` call site vs the real `(i32)->i32` function traps
("null function or function signature mismatch"). **Fix:** rebind it
`-> _cairo_pattern_t` (the retainer wrap is unchanged -- it still retains the
first arg). Carried as `package-patches/draw-lib/cairo-pattern-reference.patch`,
same mechanism as fix #3. Lesson: any cairo binding declared `-> _void` whose C
function actually returns a value is a latent wasm trap; audit `*_reference`/
`*_copy`/`*_create` siblings when a new draw path lights up.

**A fifth class of cast traps, surfaced by DrRacket's text editor: Pango
GFunc/GCopyFunc casts.** The editor calls `pango_layout_get_iter` which calls
`pango_layout_check_lines` → `pango_layout_get_effective_attributes` →
`pango_attr_list_copy` → `g_ptr_array_copy(attrs, (GCopyFunc)pango_attribute_copy,
NULL)`. `pango_attribute_copy` is `PangoAttribute* (const PangoAttribute*)` --
one arg, wasm type `(i32)->i32` -- but `GCopyFunc` is
`gpointer (gconstpointer, gpointer)` -- two args, `(i32,i32)->i32`. The same
pattern appears at five more Pango call sites on the text path: four `(GFunc)`
casts of 1-arg free functions (`free_metrics_info`, `pango_item_free`,
`pango_attribute_destroy`) passed to `g_slist_foreach` / `g_list_foreach`. These
are all in Pango's own source (not a Racket binding issue). **Fix:** add thin
static 2-arg wrapper functions at each call site in `wasm_dep_patch` inside
`wasm-deps/deps/pango.sh` (idempotent, guarded on wrapper presence). Affected
files: `pango/pango-attributes.c`, `pango/pangocairo-font.c`,
`pango/pangofc-font.c`, `pango/pango-context.c`, `pango/pango-item.c`,
`pango/pango-markup.c`.

**A sixth class: GLib's own `g_list_free_full` / `g_slist_free_full` /
`g_queue_free_full` / `g_queue_clear_full` / `g_async_queue_unref`.** GLib
implements these by casting the `GDestroyNotify` free argument (1-arg: `void
f(ptr)`) to `GFunc` (2-arg: `void f(ptr, ptr)`) and passing it to the
corresponding `_foreach`. The trap is latent -- it only fires when the list/queue
is non-empty. On the text path, `pango_layout_check_lines` calls
`g_list_free_full(state.baseline_shifts, g_free)` on every layout check; this is
safe only as long as `baseline_shifts` is NULL (no baseline-shift attributes in
the text). **Fix:** in `wasm-deps/deps/glib.sh`'s `wasm_dep_patch`, replace the
foreach-with-cast bodies with direct loops that call the `GDestroyNotify` at its
correct 1-arg type. Four files patched: `glib/glist.c`, `glib/gslist.c`,
`glib/gqueue.c`, `glib/gasyncqueue.c`.

**Systematic detection: `-Wcast-function-type`.** This clang flag warns at
compile time on any explicit cast of a function pointer to an incompatible type.
It is now threaded through `wasm-deps/wasm-emscripten.cross` (`c_args`/`cpp_args`)
and `deps.sh`'s autotools `emflags`. Future dep version bumps or new deps will
surface remaining mismatches in the build log rather than as runtime traps.
*Note:* `g_list_sort` / `g_slist_sort` (which cast `GCompareFunc` through `GFunc`
to `GCompareDataFunc` in their internal sort helpers) are also technically
affected, but those code paths are not on our Pango text path and the fix would
require rewriting the sort infrastructure; defer until actually triggered.

**Fontconfig provisioning (makes node text reliable).** With the three casts
fixed, text *executes*, but was flaky without a config + a font
(`FcInitLoadConfigAndFonts` returns NULL; Pango then sometimes returns
degenerate metrics and `pict->bitmap` fails). Fixed by shipping
`overlay/racket/src/cs/c/wasm-fonts/` (DejaVuSans.ttf + a minimal `fonts.conf`):
`build.zuo`'s `core-preloads` drops them at `/share/fonts/DejaVuSans.ttf` and
`/etc/fonts/fonts.conf` on both surfaces, and `main_em.c` exports
`FONTCONFIG_FILE`/`FONTCONFIG_PATH`/`HOME`/`XDG_CACHE_HOME` and `mkdir`s a
writable cache before boot. **Under node, text now renders reliably.**

**Why not `-sEMULATE_FUNCTION_POINTER_CASTS=1`.** It would fix the C-side casts
at once, but (a) it doesn't link -- `wasm-opt --fpcast-emu` aborts with
`max-func-params needs to be at least 17` and Emscripten exposes no knob to
forward `--pass-arg`; (b) it rewrites the whole function table, endangering
Chez's self-tagged foreign-callable indices; and (c) it wouldn't fix #3, which
is a Racket-level binding bug, not a C cast.

#### Browser text: the GLib thread deadlock and its fix (`-sPROXY_TO_PTHREAD`)

`racket/draw` text first appeared to **hang in the browser shell** -- not a
signature bug, the shell's threading model. The font path makes GLib spin up a
helper thread and `g_cond_wait`s for it:

```
S_pb_interp -> ffi_call -> pango_layout_get_iter -> ...
  -> pango_fc_font_map_get_config -> g_cond_wait
  -> pthread_cond_wait -> _do_futex_wait        (blocks forever)
```

The cause: `shell-worker.js` runs the Emscripten module *inside a Web Worker*
that boots Racket and then blocks synchronously (`Atomics.wait` on the SAB
stdin/DOM rings). When Racket runs **on** that worker, the worker is the
module's "main thread", so it can never spawn/handshake the GLib helper thread
the cond waits on (node spawns it fine, hence node always worked).

**Fixed by running Racket on a proxied pthread (`-sPROXY_TO_PTHREAD`).** Two
small changes, no source patches to GLib/Pango, no shell-IO rewrite:

1. **`build.zuo.patch`** adds `-sPROXY_TO_PTHREAD -sPTHREAD_POOL_SIZE=4` to the
   **browser** emcc link. `main()`/Racket now runs on a child pthread (a nested
   worker); the shell worker becomes the proxy-pump/main thread and stays free
   to service `pthread_create` + proxied main-thread ops, so the GLib helper
   thread spawns and `g_cond_wait` completes. The SAB stdin/stdout/DOM rings are
   shared memory, so they keep working across the thread boundary unchanged.
2. **`runtime-glue/shell-worker.js`** sets `Module.mainScriptUrlOrBlob =
   "./racket-web.js"`. Without it, Emscripten spawns its pthread pool by
   `new Worker(_scriptName)` where `_scriptName` is the *current* worker's URL
   (`shell-worker.js`, because the module is loaded via `importScripts` and
   can't discover its own URL) -- spawning useless extra `shell-worker.js`
   instances so the proxied `main()` never boots (stuck at "Downloading…").
   Pointing it at the real module makes the pool spawn `racket-web.js` in
   pthread mode.
3. **`wasm_canvas.c`** delivers the pixel blit via `MAIN_THREAD_EM_ASM` instead
   of `EM_JS`. Under PROXY the blit runs on the Racket pthread, whose
   `self.postMessage` reaches the shell worker, *not* the page -- so picts
   computed but never rendered. `MAIN_THREAD_EM_ASM` proxies the `postMessage`
   to the main thread (the shell worker), whose `postMessage` reaches the page;
   when Racket already runs on the main thread (non-proxy / node) it runs
   inline, so the change is surface-agnostic. (Watch the EM_ASM comma trap: the
   C preprocessor protects commas only inside parens, not the `{ }` body, so use
   one `var` per statement, not `var a=$0, b=$1`.)

**Verified end-to-end in headless Chromium** against a freshly served `dist/`:
the core REPL boots/evals/exits under PROXY; `get-text-extent`/`draw-text` run
with correct metrics and no hang (run-then-exit *and* the interactive IDE REPL);
and a `(text …)` pict **renders inline as a `<canvas>`** in the IDE Interactions
pane. `-sPTHREAD_POOL_SIZE` alone (no PROXY) was the earlier dead end -- it hung
at startup because the pool handshake also needs the worker to pump messages,
which it can't once it boots Racket synchronously; PROXY is what frees it.

Cost: an always-on proxy worker + a small pthread pool, and a modestly larger
browser link. The node surface is unaffected (its link has no PROXY flag).

**Page-side follow-up: PROXY reorders `ready` ahead of the loader-status drain.**
With PROXY the worker posts `ready` (from `onRuntimeInitialized`) *before* the
final Emscripten `setStatus("")` that fires as the file-packager drains its
~thousands of per-file run-dependencies (one `removeRunDependency` per packaged
`share.data` file, each also calling `setStatus`). The page driver
(`apps/ide/ide.js`) showed "Running" on `ready`, then that one trailing
`status ""` downgraded the chip back to "Assets loaded" and it stuck there --
the runtime was actually up, but the surface looked hung (and headless tests
that wait for `#status === "Running"` timed out). Fix: `ide.js`'s `status`
handler ignores all loader status once `ioReady` is set (after `ready`) --
Emscripten's loader status only describes boot and is meaningless once Racket is
running. (`ide.js` is app surface, not part of the runtime cache key, so this is
picked up by the post-build example-merge with no relink.)

## Calling WASM-specific primitives from Racket

WASM-specific C functions (sync-XHR HTTP, pixel-buffer-to-canvas blit,
future WebSocket TCP, etc.) live in `racket/src/cs/c/wasm_*.c` and are
registered into Chez's foreign-symbol table via
`racket/src/cs/c/wasm_extras.inc` -- the same mechanism rktio uses.
The build wires this in by compiling `boot.c` with
`-DRACKET_EXTRA_FOREIGN_INC='"wasm_extras.inc"'`; `boot.c`'s
`init_foreign` then `#include`s the file after `rktio.inc` and runs
its `Sforeign_symbol(...)` calls during heap build.

Available primitives today (both reachable from Racket via the
`vm-eval` + `foreign-procedure` pattern shown below):

- `int wasm_http_get(const char *url, void *out_buf, int out_buf_len)`
  -- synchronous HTTP GET from the runtime worker; status as int32
  followed by body bytes.
- `int wasm_canvas_blit(int id, int w, int h, const void *rgba)` -- copy a
  `w*h*4` RGBA8888 buffer out of the WASM heap and `postMessage` it
  to the page; the canvas surface (`ide.js` today) renders it
  via `putImageData`. Returns 0 in a Worker, -1 in node / wherever
  `self.postMessage` is unavailable. This is the Tier 1 pixel-output
  path for everything from manual byte-pushing to the `racket/draw`
  Cairo backend. The `_argb` / `_bgra` variants accept
  `racket/draw get-argb-pixels` output and Cairo `ARGB32` memory order
  respectively, rotating channels to RGBA during the copy out.

  **Canvas id contract.** The leading `id` selects the destination canvas,
  so output can address *multiple* canvases:

  - `id == 0` -- *ephemeral*: the page appends a **fresh** `<canvas>` into
    the `#output` pane per blit (`ide.js`'s `appendCanvas`), so a run that
    draws N bitmaps reads back as N inline images. This is the REPL pict /
    bitmap-printing path.
  - `id > 0` -- *addressable*: the page creates the `<canvas>` on the first
    blit for that id, then reuses + updates it in place. Each GUI window (a
    `frame%`, see the GUI backend section) and each `web-repl` canvas-window
    owns one such id. Ids come from a single global counter,
    `wasm_canvas_alloc_id()` (shared by the GUI backend and `web-repl`, so
    the two never collide in the page's id->element map); tear a canvas down
    with `wasm_canvas_destroy(id)`, which posts `{ type:"canvas-destroy", id }`.

  For GUI windows the id doubles as the event frame-id: each id'd `<canvas>`
  carries its own input listeners that tag events with that id, so the page
  owns where the windows sit (page-managed stacking) while the backend routes
  input per window.

  The `web-repl` collection wraps the ephemeral path: `(require
  web-repl/display-bm)` then `(display-bm bm)` reads a `bitmap%` with
  `get-argb-pixels` and calls `wasm_canvas_blit_argb` with id 0. For a
  persistent, addressable canvas use `web-repl/window`:
  `(open-canvas-window w h)` allocates an id, hands back a `bitmap-dc%` to
  draw into, and `(canvas-window-flush! win)` updates that one canvas in
  place; `(close-canvas-window win)` removes it.
  (Companion helpers in the same collection: `web-repl/canvas`,
  `web-repl/dom`, `web-repl/http` -- see "A `web-repl` helper
  collection" below.)
- `int wasm_dom_eval(const char *js_src, int src_len, char *out,
  int out_cap)` -- synchronous DOM RPC. See the next subsection.

### DOM interaction (synchronous RPC via SAB)

Workers have no DOM access (no `document`, no `window`), but the
WASM runtime hosts Racket on a worker so it can `Atomics.wait`-block
inside its REPL/stdin without freezing the page's event loop.
`wasm_dom_eval` bridges the gap by using the shared linear memory
as a single-slot RPC channel:

```
worker -> page    [cmd_seq, cmd_len, cmd_buf[]]
page   -> worker  [reply_seq, reply_len, reply_buf[]]
```

Worker side (the `wasm_dom_eval` EM_JS body in
`racket/src/cs/c/wasm_dom.c`):

1. Copy the JS source string into `cmd_buf`, set `cmd_len`.
2. Atomically increment `cmd_seq` (release-publishes the data).
3. Loop on `Atomics.wait(reply_seq_addr, current)` until
   `reply_seq == cmd_seq`.
4. Copy `reply_buf[0..reply_len]` into the caller's output buffer.

Page side (an rAF loop in `ide.js`):

1. Each frame, read `cmd_seq`; if it advanced past the last value
   the page handled, decode `cmd_buf[0..cmd_len]` as UTF-8.
2. Run `eval(src)`, stringify the result.
3. Encode the result into `reply_buf`, set `reply_len`, store
   `reply_seq = cmd_seq`, `Atomics.notify` the worker.

This design preserves the worker architecture (no Asyncify cost on
everything else), gives Racket a synchronous-feeling DOM call from
its perspective, and caps per-call latency at one animation frame
(~16 ms) because the page only services commands on rAF. Reading
DOM state in a tight loop will be visibly slow at that rate; for
high-frequency UI the right answer is either a typed batch protocol
on top of the same transport or selective use of Asyncify on
specific hot paths.

#### v0 limits / future direction

`wasm_dom_eval` literally evaluates an arbitrary JS string. That is
fast to prototype with, but unsuitable for exposing to untrusted
Racket programs as-is. The clean migration path:

- Define a typed opcode list (`MAKE_ELEMENT`, `SET_TEXT`,
  `SET_ATTR`, `ON_EVENT`, `GET_ATTR`, ...).
- Encode commands as opcode + serialized args (CBOR or a compact
  custom format), replies as result-shape + bytes.
- The page-side dispatcher becomes a `switch (opcode)` over the
  typed operations rather than a JS `eval()`.
- Racket-side wrapper (`web-dom` collection?) exposes idiomatic
  Racket procedures over the typed protocol.

The transport (single-slot SAB, rAF service, `Atomics.wait`-blocked
return) does not change between v0 and the typed version -- only
the payload format and the page-side handler do. Event delivery
(page -> Racket, e.g. button clicks) reuses the existing stdin
ring with a typed framing, or adds a third dedicated ring.

A Racket-side wrapper (the `web-repl/dom` collection packages this):

```racket
(define wasm-dom-eval-raw
  (vm-eval '(foreign-procedure "wasm_dom_eval" (u8* int u8* int) int)))
(define (dom-eval js)
  (define src (string->bytes/utf-8 js))
  (define out (make-bytes 65536))
  (define n (wasm-dom-eval-raw src (bytes-length src) out (bytes-length out)))
  (bytes->string/utf-8 out #\? 0 n))

(dom-eval "document.title = 'hello'")
(define ua (dom-eval "navigator.userAgent"))
```

**The FFI access path is not `get-ffi-obj`.** Under WASM there is no
dynamic linker -- `dlopen` doesn't exist, all symbols are statically
linked into the one wasm module, and Chez's `(cs)load_shared_object`
foreign-entry is not built. `(get-ffi-obj 'name #f ...)` therefore
fails with `ffi-lib: could not load foreign library / path: [all
opened] / system error: dynamic linking not enabled` because
`ffi-lib` routes through rktio's `rktio_dll_open`, which is a stub on
Emscripten.

Reach Sforeign_symbol-registered names directly via Chez's
`foreign-procedure`, available from Racket through the
`ffi/unsafe/vm` shim that Racket itself uses for the rktio surface.
The pattern:

```racket
(require ffi/unsafe/vm)

(define wasm-http-get-raw
  (vm-eval '(foreign-procedure "wasm_http_get" (string u8* int) int)))

(define (http-get url)
  (define buf (make-bytes (* 1024 1024)))
  (define n (wasm-http-get-raw url buf (bytes-length buf)))
  (cond
    [(= n -1) (error 'http-get "transport error")]
    [(negative? n) (error 'http-get "response too large (~a bytes)" (- n))]
    [else
     (values (integer-bytes->integer buf #f #f 0 4)   ; HTTP status
             (subbytes buf 4 n))]))                    ; body

(define-values (status body) (http-get "https://api.github.com/zen"))
```

`vm-eval` runs the Chez form inside Racket's Chez runtime and returns
the resulting procedure. Bytevector-shaped args go straight through
(`bytes` IS a bytevector on CS), so allocation is `make-bytes` from
Racket. This pattern works for every Sforeign_symbol-registered
primitive without going through `ffi-lib` at all -- it's the right
recipe to give users of the WASM REPL.

### Browser GUI backend (mred) -- in progress

A `wx/wasm/` backend for `racket/gui` (mred) is being added to render to
HTML canvases: one `<canvas>` per top-level `frame%`, every widget drawn
by Racket via `racket/draw` onto a cairo image surface and blitted out with
`wasm_canvas_blit_argb` (editors/snips/picts draw through `dc<%>` so they
come for free). Each frame's blit is tagged with its frame-id (= canvas id;
see the canvas id contract above), so the page renders each window onto its
own addressable canvas, created on first blit and removed via
`wasm_canvas_destroy` when the frame hides. The page owns window placement
(page-managed stacking); `wx/wasm/queue.rkt` keeps a z-order only to decide
modal **input** grab, not which canvas paints. The runtime-level foundation
is wired into the delta; the mred backend itself + page event wiring are WIP.
See `gui-backend/README.md`.

Page->worker GUI input rides a third SAB ring, the mirror of the stdin
ring: **`racket/src/cs/c/wasm_gui_events.c`** holds a fixed-width record
ring (6 int32 per record: type, frame-id, x, y, k, mods) and exposes
`wasm_gui_events_poll(out, max)` (registered in `wasm_extras.inc`,
reachable via `vm-eval`/`foreign-procedure`; node stub returns 0). The
ring accessors `_gui_events_addr/_cap/_fields` are added to the browser
link `EXPORTED_FUNCTIONS`, and `shell-worker.js` posts their offsets to
the page in the `ready` message (`guiEvents`). `wasm_gui_events` is a
common prim (`wasm-prim-names`), linked into both surfaces.

The event-pump idle-wake is deliberately deferred: Cocoa's
`unsafe-set-sleep-in-thread!` needs OS threads this build disables, and
GTK's `unsafe-poll-ctx-fd-wakeup` depends on rktio `poll()` parking the
worker under WasmFS (unverified). The first milestone uses a periodic
~60 Hz poll of the ring (proves blit-out + event-in + the backend);
0%-idle wake (fd-wakeup or `Atomics.wait`-with-timeout) is a later
refinement once measured against a real build.

## What still has to be written

The boot harness (`racket/src/cs/c/main_em.c`) is in place, pbchunk is
wired into the link, and node boot is down to ~2 s with correct
evaluation verified. The browser shell hosts the runtime in a
dedicated Web Worker with `Atomics.wait`-blocked stdin, swapped from
an xterm to a plain textarea + scrolling output pane so the browser
handles all editing. ~319,500 Racket core-test assertions pass under
`node racket.js` (one known PRNG corner-case failure, documented
below).

### Capability gaps (concrete TODOs)

1. **PRNG large-range corner case.** `(random N)` for some `N > 2^31`
   disagrees with a native CS build. Ordinary `random` and the other
   ~76,000 number tests pass; this is a narrow wide-range corner.

   Minimal reproducer (native CS `v9.2.0.5 [cs]` is the reference):

   ```
   (random-seed 7) (random 2147483649)
   ;; native => 845508111   wasm => 330626979
   ```

   Note it is *not* a uniform "off by exactly `2^31`" as originally
   filed -- that holds for some inputs (a fresh
   `make-pseudo-random-generator` + `(random 3000000000)` is off by
   `2^31`) but not this one, and many wide-range inputs match exactly
   (e.g. with the *default* generator `(random-seed 42)` +
   `(random 3000000000)` agrees: both `315132820`). The set of
   diverging inputs has not been fully mapped.

   **Diagnosis (revised -- the earlier "32-bit signed/unsigned in the
   wide path" guess was wrong).** The Chez kernel wide-range routine
   is `pseudo-random-generator-next!` in
   `racket/src/ChezScheme/s/5_3.ss` (~line 3237), whose `random-integer`
   builds an `N`-wide result from 31-bit `random-int(s, ...)` foreign
   calls plus a rejection step. Reimplementing that exact algorithm in
   plain Racket (using `(random k)` as the `random-int` primitive) and
   tracing it produces a *byte-identical* draw/reject sequence on
   native and wasm, and on both it yields the **wasm** answer
   (`330626979`), via: first attempt `low=845508111 hi=1 =>
   maybe=2992991759 >= x => reject`, second attempt `=> 330626979`.

   So wasm is faithfully executing the `5_3.ss` wide-range wrapper; it
   is the *native* builtin that does **not** match that algorithm (it
   returns the un-rejected first low draw, `845508111`). The real
   divergence is therefore *which* implementation of `(random bignum)`
   each build dispatches to -- native reaches a different path (a
   Racket-level `random` in `racket/src/cs/rumble/random.ss`, or a
   direct primitive, that pre-empts the Chez `5_3.ss` wrapper) while
   wasm falls through to the Chez wrapper. The mrg32k3a stream itself
   and the single-digit path (`(random 2^31)`) are bit-identical
   across the two builds, so the generator core is fine.

   Next step when this is picked up: trace what `(random bignum)`
   actually binds to on native CS and why the wasm build resolves a
   different one, rather than hunting for an arithmetic bug in the
   `5_3.ss` path (there isn't one). Left as a known, low-impact
   divergence for now.

2. **`#:pool 'own` thread pool slowdown surfaced by `port.rktl`.**
   The hypothesis that `port.rktl` was tripping an unimplemented
   rktio call turned out to be wrong on bisection. Output is
   *heavily* buffered in the WASM/node pipeline (no flush until a
   buffer fills, an explicit `(flush-output)`, or process exit), so
   the test pane looked stuck while the runtime was actually still
   making progress. The slowdown is real, though: the test at
   lines 152-164 (10 threads racing `(write-bytes #"a" o)` /
   `(read-bytes 1 i)` 1000× on a shared `make-pipe`) runs in
   milliseconds with plain `(thread ...)`, but takes effectively
   forever with `(thread #:pool 'own ...)` -- it scales fine up to
   ~100 iterations per thread and falls off a cliff between 100 and
   1000. Other patterns that use `#:pool 'own` for a single small
   workload (e.g. `port.rktl`'s 137-150 silent for-loop) finish
   fine. The smoking gun is "own-pool pthread workers + many
   write/read round-trips per iteration"; the conjecture is that
   `#:pool 'own` is spinning up an OS-thread-pool worker per thread
   and we are paying a per-iteration wake/yield round-trip that on
   a real OS costs microseconds but on WASM, where we link
   `-pthread` without `PROXY_TO_PTHREAD` / `PTHREAD_POOL_SIZE`,
   either falls back to something synchronous-ish or spins on a
   broken signal.

   Action items: (a) audit `racket/src/cs/rumble`'s
   `make-pthread-parameter` / pthread-pool layer to see whether
   `#:pool 'own` actually fans out to OS threads under WASM or
   transparently degrades to cooperative; (b) if it does fan out,
   either bump `PTHREAD_POOL_SIZE` in the link or short-circuit
   `#:pool 'own` to plain `thread` on `__EMSCRIPTEN__`; (c) if it
   doesn't, find the per-iteration cost. Either way port.rktl
   itself is *correct* on WASM, just unusably slow; once this is
   addressed it should re-join the default test slice.

   **Measured**: a full run of `port.rktl` under `node racket.js`
   takes about **6m49s wall time**, all 797 value tests + 278
   exception-field tests pass. The same suite on a native build
   takes a few seconds.

3. **Persistent home via WASMFS + OPFS (shipped 2026-06).**
   The browser surface runs on **WASMFS** (`-sWASMFS=1`, replacing the
   old `-sFORCE_FILESYSTEM=1 -lidbfs.js`), with `/home/web_user`
   mounted on an **OPFS** backend. OPFS gives synchronous
   `FileSystemSyncAccessHandle` I/O **directly on the Racket pthread**,
   durable on `close()`/`flush()` -- so persistence needs *no*
   exit-window flush and *no* clean `(exit 0)`: anything Racket has
   written and closed is already on disk. The IDE's
   process-per-run (`apps/ide/ide.js` still `worker.terminate()`s on
   Run/Stop) therefore persists user files across runs for free; only
   files left *open* at terminate are lost (as with any process kill).

   **As-built wiring** (all browser-only; the node surface stays on
   legacy FS):
     - **Mount + redirect**, in C: `racket_wasm_browser_fs_init`
       (`overlay/.../wasm_shell_io.c`, called from `main_em.c` before
       `racket_boot`) does `wasmfs_create_opfs_backend()` +
       `wasmfs_create_directory("/home/web_user", ...)`, **fail-soft**
       to an in-memory dir if OPFS is unavailable or single-tab-locked
       (emscripten #24648). `wasm_shell_io.o` is linked into
       `racket-web.*` only, so `main_em.c` declares the symbol
       `__attribute__((weak))` with a no-op default for the node link.
     - **stdin (fd 0)**: `runtime-glue/wasmfs-stdin.js` (`--js-library`)
       overrides `_wasmfs_stdin_get_char` (which WASMFS's
       `StdinFile::read` loops over -- `special_files.cpp`), backed by
       the existing SAB input ring, with the *block-on-first-empty /
       `-1`-once-the-line-drains* discipline that dodges the per-char
       loop trap. It also flips the io-state flag (the old
       `shell-tty.js` job).
     - **stdout/stderr (fds 1/2)**: WASMFS's `WritingStdFile::writeToJS`
       (`special_files.cpp`) **line-buffers until `\n`/`\0`** before
       calling `emscripten_out`, which would swallow the bare REPL
       prompt and unterminated `(display ...)`. So we bypass it:
       `runtime-glue/wasmfs-console.js` (`--js-library`) exposes a
       C-callable `rkt_console_setup` that registers a write-only char
       device at `/dev/console` whose `write` pushes each byte straight
       to the SAB output ring (no newline buffering);
       `racket_wasm_browser_fs_init` calls it and `dup2`s fds 1/2 onto
       it. Two subtleties forced this shape: a JS-only `emscripten_out`
       override could *not* fix the buffering (it is upstream of that
       hook, in C); and the device must be created **on the proxied main
       pthread** (from C in `main()`), not in `preRun`, because WASMFS
       jsimpl device ops are dispatched on the calling thread against
       per-thread JS state with no proxying (`js_impl_backend.h`) -- and
       every Racket write() runs on that pthread.

   **Why not the cheaper routes** (investigated 2026-06; answers the
   old "maybe proxy-to-pthread fixed mid-run flush?" TODO -- it did
   not). The browser link uses `-sPROXY_TO_PTHREAD` (the GLib
   font-helper-thread deadlock fix -- see the link flags), so `main()`
   runs on a child pthread and, *under legacy FS*, the canonical
   Emscripten FS lives on the shell-worker main thread (pthread
   syscalls proxied there). That main thread is **parked servicing the
   proxy for the entire run**, even while Racket idles in
   `Atomics.wait` on stdin -- so a legacy `FS.syncfs` can only run at
   `preRun`/`onExit`, never mid-run. Empirically (toy build +
   Playwright): a `postMessage` flush handler never ran mid-session; a
   `setInterval` armed in `onRuntimeInitialized` fired ~2 ticks then
   went silent; and `self.addEventListener("message", ...)` *broke
   PROXY_TO_PTHREAD boot* (collides with the proxy's message channel --
   only `self.onmessage` replacement is safe). The two rejected
   alternatives: **`-sASYNCIFY=1`** + an `emscripten_sleep(0)` yield in
   the stdin read (a real ~1.5-3x runtime / ~25% size tax on every
   build), and **page-mediated write-through** (hook FS writes, ship
   bytes over a SAB ring to the always-free page, have it write
   IndexedDB -- generic but you reimplement incremental FS-op mirroring
   + delivery guarantees). OPFS sidesteps both: durability is on the
   pthread itself, no parked thread in the path.

   The migration was de-risked by three standalone `emcc` spikes
   (emsdk 5.0.7, `-sWASMFS -pthread -sPROXY_TO_PTHREAD`, headless
   Chromium), all passing: (1) OPFS from the proxied pthread persists
   across loads (off the page main thread, so the main-thread OPFS
   deadlock emscripten #20650 doesn't apply); (2) the
   `_wasmfs_stdin_get_char` override works JS-only; (3) both packaging
   paths -- `--preload-file` (boot/collects) and the separate
   `share.data`/`share.data.js` `file_packager` artifact (via
   `FS_createDataFile`/`FS_createPath`/`addRunDependency`, all present
   in WASMFS) -- still deliver files to `main()`.

   **Verify on the next real build** (not yet exercised end-to-end):
   the prompt/`display`-without-newline now reaching the page through
   the ring device; `--use-preload-cache` still functioning under
   WASMFS (kept in the browser link); a write-then-reload persistence
   round-trip; and that `racket/draw` text still renders (the GLib
   font-helper thread -- the reason `PROXY_TO_PTHREAD` exists -- under
   WASMFS). A lower-blast-radius alternative that was **not** taken
   ("Route B"): keep legacy FS + console and write a *custom legacy-FS
   OPFS backend* mounted only at the persistent path -- rejected
   because it reimplements the async-acquire-then-sync-I/O proxy that
   WASMFS provides for free.

4. **Networking, real TCP via a WebSocket-bridged `rktio_network`.**
   *Partially shipped*: the browser build has a `wasm_http_get` C
   primitive (sync XHR from the runtime worker, see
   `racket/src/cs/c/wasm_http.c`), reachable from the REPL via the
   `ffi/unsafe/vm` pattern above. Covers the HTTP / CORS-allowed
   case end-to-end.

   What it does *not* do: raw TCP, `racket/tcp`, sockets, persistent
   connections, anything POST-shaped that needs custom framing. The
   real fix is a WebSocket tunnel: a small server (~50 lines of node
   + `ws`), a JS shim on the page that owns the WebSocket and
   proxies bytes to/from per-connection shared-memory rings, and an
   `__EMSCRIPTEN__` branch in `racket/src/rktio/rktio_network.c`
   that delegates to those rings instead of calling `socket(2)`.
   With this, `(get-pure-port (string->url "..."))` would Just Work.
   Significant effort, on the order of a week, plus the
   bridge-server deployment caveat (must be locally hosted or
   target-allowlisted; otherwise it's an open relay).

   A useful intermediate alternative: a `racket/websocket` library
   that lets Racket *be* a WebSocket client (no bridge needed,
   server must speak WebSocket). Half-day; orthogonal to the bridge
   work.

5. **Native-feel line editing (libedit on WASM).** macOS / Linux
   Racket gets readline-style line editing because `readline-lib`
   FFIs against libedit/libreadline. We don't have either in the
   WASM build. Two paths: (a) port libedit (~10k LOC of BSD-licensed
   C, with termcap and signals to stub) and statically link it;
   (b) write a pure-Racket readline-equivalent that uses raw-mode
   terminal escapes. (a) is the smaller language project (~1-3
   days) and would make `(require readline)` Just Work. (b) helps
   every Racket user without readline installed and could be a new
   package, but is a bigger ergonomics undertaking. The current
   browser shell sidesteps both by using a `<textarea>`; a node
   REPL still wants this.

6. **Pre-generate `compiled/tpb32l`.** See the WIP section above
   (`precompile-target-compiled.rkt`). Once the helper handles a
   broader set of collections, the runtime can load `.zo` directly
   instead of re-expanding `.rkt` source per session, which would
   meaningfully cut warm-load time.

7. **Upstream the patches against Chez/rktio/cs.** Several files
   modified in master, all clean conditional additions that are
   behavior-preserving on every other platform:
     - `ChezScheme/c/ffi.c`, `ChezScheme/s/prims.ss`: libffi
       function-table-index boxing in the `pb` foreign-callable
       path (only fires under `__EMSCRIPTEN__`).
     - `rktio/rktio_platform.h`, `rktio/rktio_poll_set.c`,
       `rktio/rktio_process.c`: `__EMSCRIPTEN__` feature defines
       and the `RKTIO_USE_SYSCONF_FOR_FD_LIMIT` fallback branches.
     - `cs/c/boot.c`: a 4-line `#ifdef RACKET_EXTRA_FOREIGN_INC` /
       `#include` block inside `init_foreign` that lets a build
       inject extra `Sforeign_symbol` registrations alongside
       rktio's. No behavior change unless the macro is defined.
     - `cs/c/configure`: honor an explicit pb `--enable-target`
       (e.g. `--enable-target=tpb32l`) instead of overwriting
       `TARGET_MACH` with the host-derived `pb_machine_name`. Only
       changes behavior when `--enable-target` names a `pb`/`tpb`
       machine; lets the WASM build drop `--enable-mach=tpb32l` and
       the `sed 's/^MACH = tpb32l/.../' Makefile` workaround.
     - `ChezScheme/configure`: the `em)` `mdlinkflags` case now emits
       the `addFunction`/`removeFunction` exports and
       `-sALLOW_TABLE_GROWTH=1` that libffi's wasm closures need, so
       the WASM kernel build no longer has to awk-patch `mdlinkflags`
       in `Mf-config` after configure. Only affects emscripten builds.
     - `cs/c/configure[.ac]`: emit
       `PLT_CS_MACHINE_TYPE=${KERNEL_TARGET_MACH}` for *any* pb/tpb
       target (a `case "${KERNEL_TARGET_MACH}" in *pb*)` block) rather
       than only inside the `enable_pb` block. A pb target compiles
       `(machine-type)` to a constant read from `PLT_CS_MACHINE_TYPE`
       (see `rumble/system.ss`), and that is needed whether the pb
       target was reached via `--enable-pb` or via `--enable-mach=<tpb>`
       with a cross `--host`. Behavior-preserving for non-pb targets.
     - `cs/c/configure[.ac]` + `cs/c/Makefile.in`: a new `EMSCRIPTEN`
       substitution var, set `t` by an `*emscripten*` `host_os` case.
       Lets `cs/c/build.zuo` recognize a WASM target and skip the native
       `racketcs`/`gracketcs`/`embed-boot` steps, stopping at the boot
       images. The same case presets `ac_cv_sizeof_void_p=4` (wasm32 /
       tpb32l are 32-bit), since the cross sizeof bisection can't run a
       wasm test binary and otherwise computes 0 ("Something has gone
       wrong getting the pointer size"). No effect off emscripten.
     - `ac/libffi.m4` (and the generated `cs/c/configure`): skip the
       libffi `AC_TRY_LINK` when `EMSCRIPTEN=t` and treat libffi as
       present. The link test can't run in a wasm cross environment, and
       libffi is provided out-of-band (the `wasm-deps` target builds
       it; it is linked at the emcc step). Without this, `--enable-pb`
       (needed for `SCHEME_LIBFFI=yes`) fails configure with "unable to
       link to libffi". No effect off emscripten. (The kernel compile
       still needs `ffi.h` on `CPPFLAGS` -- the `wasm-deps` target builds
       the wasm libffi and `add-scheme-kernel-config` points at its
       `install/include`.)

   **Deferred: upgrade the in-tree libffi to 3.5.x.** The `wasm-deps`
   driver downloads and builds libffi 3.5.2 from upstream because the
   libffi copies vendored in this repo (`racket/src/bc/foreign/libffi`,
   and Chez's bundled copy) are 3.4.x, which uses Emscripten JS-library
   names (`generateFuncType`, `uleb128Encode`) that newer emsdk renamed,
   so they don't cross-build under a current emsdk. Once the vendored
   libffi is updated to 3.5.x upstream, the `wasm-deps` libffi recipe's
   tarball download could be dropped in favor of the in-tree source.
   That bump belongs upstream (it affects the native BC/Chez builds too),
   not on this branch.

   Branch-local build machinery (probably stays on the branch, not
   upstreamed): the `CONFIGURE_WRAPPER` knob (top-level `Makefile`,
   `main.zuo`, `racket/src/lib.zuo`) that wraps each `configure` with
   `emconfigure`, and the `EMSCRIPTEN`-gated skips in `cs/c/build.zuo`.
   Send the conditional fixes above upstream so this branch stops
   drifting from master.

### Lower priority

1. Profile and trim the **browser** shell's startup and asset
   download (the ~26 MB wasm + ~87 MB data is fine for node but
   heavy for the web): compression, streaming instantiation, lazy
   `/collects`.
2. (Stretch) Emscripten linear-memory prewarm snapshot — only if a
   sub-second cold start is needed; see the *Open* section.
3. **Re-home the `web-repl` helpers once the surfaces stabilize.** They
   exist as a collection (`racket/collects/web-repl/`, shipped by the
   automatic `/collects` preload; see "A `web-repl` helper
   collection") but that placement is provisional -- dropping helpers
   straight into core `collects` is the "works now" route, not
   necessarily where they belong long-term (a distributed package on
   the catalog? folded into a `web`/`net` collection? co-located with
   the typed DOM protocol when that lands?). Revisit when the browser
   surface API firms up; until then `racket/collects/web-repl/` is the
   one home for the helpers to evolve in.
