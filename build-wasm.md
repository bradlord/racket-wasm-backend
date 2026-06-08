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
> | `make wasm-binary-pkgs` (the 4-stage catalog) | `racket build/main.rkt rebuild-binary-catalog` |
> | serve the output dir | `racket build/main.rkt serve [port]` (over `dist/`) |
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
  under `node scheme.js`. The cost is binary size: `scheme.wasm` grows
  ~1 MB → ~26 MB and `scheme.data` ~47 MB → ~87 MB (irrelevant for the
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
make wasm SCHEME=<native-threaded-host-scheme> RACKET=<host-racket>
```

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

- the **node** REPL -- `scheme.{js,wasm,data}` (run with
  `echo '(+ 1 2)' | node scheme.js`); and
- the **browser** runtime -- `scheme-web.{js,wasm,data}` (adds the
  browser-only `wasm_shell_io.o`, the SAB/DOM exports, IDBFS, and the
  `idbfs-init.js`/`shell-tty.js` glue baked in via `--pre`/`--post-js`).

**The link emits only the runtime, not the page.** As of the
runtime/surface decoupling (project roadmap Phase 0), the `wasm` target no
longer stages any page assets next to the binary. The host-side glue
(`shell-worker.js`, the COOP/COEP dev server `serve.rkt`) and the page
**surface** (`ide.html`/`.js`, the DrRacket-like IDE) live **repo-side**, not
in the clone -- under `runtime-glue/` and `apps/ide/public/` respectively -- and
the orchestrator's `collect-outputs` (`build/stages.rkt`) copies them into
`dist/` alongside the runtime. This is the seam that lets a different surface
ship against the same runtime binary without re-linking; see the project
roadmap. Serve `dist/` with `racket serve.rkt 8123` (sets the COOP/COEP
headers `SharedArrayBuffer` needs) and open `ide.html`.

The browser-link flags live in the `wasm` target itself.
`racket/src/ChezScheme/install-wasm-browser-shell.rkt` is a **legacy**,
unused-by-`make wasm` script that still lists the old in-clone asset names; it
is not part of the decoupled path and is no longer kept in sync.

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
`(provide app)` a hash of those fields (`'pkgs 'wasm-libs 'public 'local-pkgs`);
`read-app-manifest` normalizes it and `run-app-manifest` builds it.
`racket build/main.rkt app <dir>` builds into `<dir>/dist` (override `--dest`).
`examples/hello/` is the minimal example: a non-IDE page that seeds a `main.rkt`
into MEMFS, runs it (`argv ["-u" "/tmp/main.rkt"]`), and drains its stdout from
the output ring -- the smallest counterpart to `ide.js`.

**The IDE is just an app (dogfood).** There is no bespoke IDE build:
`racket build/main.rkt build` builds **`apps/ide`** through this same path
(`cmd-build` -> `run-app-manifest ide-app-dir` -> `make-wasm-racket`). The IDE's
package / native-dep / surface config lives in `apps/ide/app.rkt` (the single
source of truth -- `build/config.rkt` no longer hardcodes a default package
set), and its page is `apps/ide/public/{ide.html,ide.js}`. The binary-catalog
rebuild (`build/pkgs.rkt`) reads the same manifest, so the IDE's package set is
defined in exactly one place. To ship a different surface or dep set, write an
app and `build` it -- the IDE has no privileged path.

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
(`build/config.rkt`). The binary-catalog path still injects it into the stripped
catalog (`inject-local-packages!`, `build/pkgs.rkt`), since that flow installs
from the catalog rather than via `LOCAL_PKGS`.

#### Runtime cache (build isolation)

The runtime binary + package payload are fully determined by the **pinned
upstream SHA**, a **hash of the delta** (`patches/` + `overlay/` +
`overlay-local/`), the native-dep selection (**`WASM_DEPS`**), and the package
set (**`PKGS`**) -- *not* by the page surface. `build/cache.rkt` hashes those
into a short **build-key** and caches the runtime set (`runtime-output-names`)
under `.work/runtime-cache/<key>/`. `build-runtime` (`build/stages.rkt`) checks
it first:

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

> Note: `make wasm` already ships packages *out of the link* (share.data), so a
> `PKGS`-only change never relinks even on a cache miss -- it reinstalls +
> repacks. The cache adds the cross-config isolation on top of that.

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
have been removed; `wasm-shell/` retains only the browser runtime assets
and glue it still serves (`ide.*`, `shell-worker.js`, `serve.rkt`,
`idbfs-init.js`, `node-tty.js`, `node-locate-file.js`,
`shell-tty.js`) plus the two WASM test files (`run-tests.sh`,
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
   (`racket/src/cs/c/wasm-deps/`) is folded in as the `wasm-deps` zuo
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
   (`scheme.{js,wasm,data}`) and the **browser** `scheme-web.*` variant
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

Cross-compiled native libraries are built by a recipe driver rooted at
`racket/src/cs/c/wasm-deps/`. In the stock build this is the **`wasm-deps`
zuo target** (`cs/c/build.zuo`), which `main.zuo` runs before the kernel
`build` (the Chez kernel's `ffi.c` needs libffi's headers). Drive it via
make:

```sh
make wasm SCHEME=... RACKET=...                 # libffi only (default)
make wasm WASM_DEPS="draw" SCHEME=... RACKET=... # + the cairo/pango stack
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

(The recipes live under `cs/c/wasm-deps/`; the `wasm-deps` target runs
them automatically before the kernel build, since `ffi.c` needs libffi's
headers.)

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

Meson recipes use `cs/c/wasm-deps/wasm-emscripten.cross` as their
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
**both** `scheme.{js,wasm,data}` (node) and `scheme-web.{js,wasm,data}`
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
     -o em-tpb32l/bin/tpb32l/scheme.html \
     em-tpb32l/boot/tpb32l/main_em.o \
     em-tpb32l/boot/tpb32l/boot.o \
     em-tpb32l/boot/tpb32l/init_rktio.o \
     em-tpb32l/boot/tpb32l/{petite,scheme,racket}{0,1,2,3,4,5,6,7,8,9}.o \
     em-tpb32l/boot/tpb32l/libkernel.a \
     em-tpb32l/lz4/lib/liblz4.a \
     ../rktio/build-em/librktio.a \
     -L ../build-libffi-em/install/lib \
     --extern-pre-js wasm-shell/node-locate-file.js \
     --post-js wasm-shell/node-tty.js \
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

`wasm-shell/node-tty.js` is the node analogue of `shell-tty.js`: it
overrides Emscripten's default TTY `get_char` to do a real `fs.readSync`
on node's stdin and return `undefined` (EAGAIN) on a would-block rather
than letting the default path leak EAGAIN out as EIO (errno 29). Without
it, `node scheme.js` with a non-blocking stdin (e.g. `child_process.spawn`,
or any non-piped invocation) loops on `error reading from stream port`.

`wasm-shell/node-locate-file.js` fixes data-file resolution under node so
that `node path/to/scheme.js` works from any directory, not just from
inside the build dir. The trap: Emscripten's internal `locateFile(path)`
resolves against `scriptDirectory` (the dir of `scheme.js`), which is why
`scheme.wasm` always loads -- but the `--preload-file` data loader does
**not** go through it. It reads `Module["locateFile"]` directly and, when
that hook is unset, falls back to the bare relative string `"scheme.data"`,
which `fs.readFileSync` resolves against the *process CWD*. So a plain
`echo ... | node racket/src/build/cs/c/wasm/scheme.js` dies with
`ENOENT: ... open 'scheme.data'`. The shim defines `Module["locateFile"]`
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
echo '(+ 1 2)' | node scheme.js
```

With `main_em.c` linked in, you will see Chez's Petite banner print,
then `racket.boot` begin loading, then a long sequence of libffi calls
into rktio succeed, and the boot-arguments struct is now populated so
startup proceeds past the old `expected ... to start` error.

With pbchunk wired in (below), boot is fast: `echo '(+ 4 2)' | node
scheme.js` returns `6` in **~2 seconds** wall time (down from ~5
minutes of pure interpretation), e.g.:

```
$ /usr/bin/time -p node scheme.js <<< '(+ 4 2)'
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

The browser shell in `wasm-shell/` is a
**shared runtime + per-surface host** design: one
`scheme-web.{js,wasm,data}` binary backs every browser surface. Today
there is one surface -- `ide.html`/`ide.js`, the DrRacket-like IDE (see
"IDE page" below) -- but the architecture is deliberately surface-
agnostic (future doc widgets / embeds / canvas GUIs are just another
HTML+JS pair that drives the same worker with a different init
payload).

It needs a **separate, browser-specific build** of the runtime,
because the node `scheme.js` runs `main()` on the calling thread: in a
browser that would be the page's main thread, and Racket's blocking
REPL stdin read would freeze the event loop.

#### Per-surface init protocol

`shell-worker.js` no longer loads the runtime at top level. It waits
for an `init` message from the page, then sets `self.Module` and
`importScripts("./scheme-web.js")`. The init payload lets the page
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
- `files` -- `{ "/abs/path": "<text>" }` written into MEMFS during
  `preRun` (before `main()`). The IDE uses this to drop the editor's
  source at `/tmp/main.rkt` before the runtime starts.
- `idbfs` -- whether to mount `/home/web_user` on IDBFS. A persistent
  surface passes `true`; the IDE's transient process-per-run passes
  `false`. `idbfs-init.js` checks `Module._idbfsEnabled` and skips the
  mount when off; `shell-worker`'s `onExit` likewise skips
  `FS.syncfs(false)` when off.

The rings (`wasm_shell_io.c`), `shell-tty.js`, and `idbfs-init.js`
stay surface-agnostic.

The page therefore hosts the runtime in a dedicated Web Worker it
spawns itself (`shell-worker.js`); `main()` runs on that worker's own
thread, free to block on stdin, while the page stays responsive. The
two threads exchange console bytes through ring buffers in the
module's *shared* linear memory (`-pthread` makes
`WebAssembly.Memory({shared:true})`, even though Racket never spawns
pthreads of its own):

- `racket/src/cs/c/wasm_shell_io.c` reserves the rings in the shared
  heap and exports their addresses.
- `wasm-shell/shell-tty.js` is linked in with
  `emcc --post-js`. It replaces the TTY `get_char`/`put_char` ops:
  `get_char` blocks on the input ring with `Atomics.wait` (legal on
  the runtime worker), `put_char` pushes each byte into the output
  ring (no newline buffering, so the REPL prompt appears immediately).
  While parked in that `Atomics.wait` it sets the `shell_io_state` flag
  to `1` (and back to `0` once input arrives) so the page can show a
  "waiting for input" affordance -- see "IDE page".
- `wasm-shell/shell-worker.js` is the worker bootstrap: it sets up
  `self.Module`, `importScripts("./scheme-web.js")` synchronously,
  and on `onRuntimeInitialized` posts the shared `HEAPU8.buffer`
  (a `SharedArrayBuffer`) plus the ring offsets back to the page.
- `ide.js` runs on the page: it spawns the worker via
  `new Worker("./shell-worker.js")`, receives the buffer/offsets,
  polls the output ring each animation frame and writes typed lines
  into the input ring followed by `Atomics.notify`.

`make wasm`'s `wasm` target builds the browser runtime alongside the
node one (it adds `wasm_shell_io.o`, the `--post-js shell-tty.js`, and
the ring exports). It does **not** stage the page assets -- those
(`shell-worker.js`, `serve.rkt`, the surface `ide.*`) are copied into
`dist/` from the repo by the orchestrator's `collect-outputs`, not from the
clone (see the runtime/surface split note near the top). The underlying link is
(the example paths below predate the move to `build/cs/c/wasm/`, but the
flags are what the `wasm` target emits):

```sh
emcc -O2 -pthread -s USE_ZLIB=1 \
     -o em-tpb32l/bin/tpb32l/scheme-web.html \
     em-tpb32l/boot/tpb32l/main_em.o \
     em-tpb32l/boot/tpb32l/boot.o \
     em-tpb32l/boot/tpb32l/init_rktio.o \
     em-tpb32l/boot/tpb32l/wasm_shell_io.o \
     em-tpb32l/boot/tpb32l/{petite,scheme,racket}{0,1,2,3,4,5,6,7,8,9}.o \
     em-tpb32l/boot/tpb32l/libkernel.a \
     em-tpb32l/lz4/lib/liblz4.a \
     ../rktio/build-em/librktio.a \
     -L ../build-libffi-em/install/lib \
     --post-js wasm-shell/shell-tty.js \
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
payload from IDB instead of re-fetching `scheme-web.data` over the
network on every load. The cache self-invalidates when the package size
changes, so a rebuild that alters the preload set transparently refreshes
it. The node surface has no persistent IndexedDB to cache into, so the
flag is omitted there. (The browser's *package* tree no longer rides in
`scheme-web.data` — it ships as a separate `share.data`/`share.data.js`
that caches itself the same way; see "Packages as a separate data file".)

Notably absent: `-sPROXY_TO_PTHREAD` and the pthread-pool flags. The
earlier design used `PROXY_TO_PTHREAD` so Emscripten itself spawned the
runtime thread, but that ran the *filesystem* on the page's main
thread (MEMFS is per-thread JS state), forcing `get_char` to be
non-blocking and the runtime to busy-poll between keystrokes. By
owning the worker ourselves, the FS and `main()` share a thread,
`get_char` truly blocks on `Atomics.wait`, and the runtime idles at 0%
CPU.

Serve with **COOP/COEP headers** — `SharedArrayBuffer` is unavailable
without cross-origin isolation, so a plain static server will not start
the runtime. `wasm-shell/serve.rkt` (staged next to the build output)
sets the headers:

```sh
cd racket/src/build/cs/c/wasm
racket serve.rkt 8123
# browse to http://127.0.0.1:8123/ide.html
```

Notes / status:

- Output (stdout and stderr) is currently merged into one ring and
  rendered without color; the input ring is line-buffered on the page.
- The page is a plain `<textarea>` + scrolling `<pre>`, not a terminal
  emulator -- the browser handles all editing; `ide.js` strips the few
  ANSI CSI sequences Racket emits.
- This cannot be validated under node: a headless harness can't drive
  the page+worker handshake. Test in a browser.

### IDE page

`ide.html` + `ide.js` is a single DrRacket-like page: a **Definitions**
editor on the left, an **Interactions** pane (output + REPL + the
program's stdin) on the right. It replaces the earlier split
`browser-shell` (bare REPL) and `playground` (run-a-module) pages --
one surface now does both.

Lifecycle is **process-per-run**. The Interactions pane is inert until
*Run*; a Run click:

1. Tears down any existing worker and clears the output.
2. Spawns a fresh worker with
   `{argv:[], files:{"/tmp/main.rkt": <editor text>}, idbfs:false}` -- a
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
   - `(enter! (file "/tmp/main.rkt"))` -- instantiates the module (its
     body runs -- output streams in) **and** switches the REPL's
     current namespace to the module's, so every top-level definition
     is in scope. That is exactly DrRacket's Run: run the definitions,
     then a REPL that sees them (not just the `provide`d names a plain
     `-i -t` would expose).

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
parses *all* its top-level forms up front via `current-read-interaction`,
and hands them to the REPL one at a time from a `pending` queue (no extra
`> ` between forms of one submission). Because the submission's bytes are
fully drained before any form runs, a `read-line` during evaluation
blocks for a *fresh* submission rather than eating the rest of the line.
That is DrRacket's separation: submitted expressions and the input a
running program reads are distinct streams in effect, even though they
ride the same ring. `(foo)(foo)` now prompts twice, once per `foo`.

**Waiting-for-input affordance.** Because the program's `read-line` and
the REPL's own prompt-read are the same fd, they are indistinguishable
at the I/O layer -- there is no way to label one block "stdin" and the
other "REPL". Instead a single honest signal covers both: `shell-tty.js`
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

Serve and visit `http://127.0.0.1:8123/ide.html`.

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

`wasm-shell/run-tests.sh` runs a slice of the
checked-in Racket core tests (the `.rktl` files in
`pkgs/racket-test-core/tests/racket/`) under the WASM/node build. Each
`.rktl` is a flat script that expects to be `load`ed inside a session
that already evaluated `testing.rktl`, so the script concatenates the
two and pipes them through `node scheme.js`, then greps for the per-test
summary line.

```sh
wasm-shell/run-tests.sh             # default slice
wasm-shell/run-tests.sh list hash   # by name
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

## Performance vs. native Racket CS

`wasm-shell/perf-bench.rktl` is a single-threaded, CPU-bound
microbenchmark shared by both runtimes. It is timed *internally* with
`current-process-milliseconds` / `current-inexact-milliseconds`, so the
WASM runtime's large startup and `.data` mount cost is excluded -- the
numbers below are steady-state compute only. Run it by piping the script
through either runtime's stdin REPL:

```sh
# native host racket
racket < wasm-shell/perf-bench.rktl | grep BENCH
# WASM under node (from the build dir)
node racket/src/build/cs/c/wasm/scheme.js < wasm-shell/perf-bench.rktl | grep BENCH
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
links entry ships automatically. (The old `wasm-shell/share-links.rktd` +
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

The general fix is the **binary-only package preload** (next section): a
`binary-lib` strip drops `build-deps` from every package's `info.rkt`, so
a clean install from the binary catalog resolves only runtime `deps` --
no per-package work. **Use that, not a vendored trim.**

Historically (before the binary preload existed) the only lever was to
**vendor a hand-trimmed copy** as a local package: drop `build-deps` from
the copy's `info.rkt` so it shadows the upstream catalog entry. The lone
example was **`datalog`** (`pkgs/datalog/`), whose `build-deps`
(`racket-doc`, `scribble-lib`, `rackunit-lib`) were the entire bloat. That
vendored fork has been **removed** -- `datalog` now installs from the
upstream catalog and the binary strip prunes its build-deps like any other
package. Don't reintroduce per-package vendoring for build-dep trimming.

### Binary-only package preload

The default preload ships every package as **source**: each `.rkt` rides
next to its `.zo`, and the source install pulls each package's
**build-deps** (docs/tests) as well as its runtime deps. An opt-in
two-step flow strips the shipped tree to `.zo`-only and prunes build-deps
across all packages at once (replacing the per-package `datalog`
hand-vendoring described above), shrinking `scheme*.data`. Measured on a
`draw`-stack build, it cut
`scheme*.data` from ~177 MB to ~62 MB (~65%).

The mechanism reuses `pkg/strip`'s `generate-stripped-directory` in
`'binary-lib` mode, which operates on an **already-compiled** package
directory (it copies `compiled/`, never recompiles) and: drops a
`.rkt`/`.ss` wherever a sibling `compiled/<name>.zo` exists; drops
`tests`/`scribblings`/`doc`/`.scrbl`/`.dep`; strips `test`/`doc`/`srcdoc`
submodules out of each `.zo`; and **drops `build-deps`** from the emitted
`info.rkt`. Because the cross build writes the tpb32l `.zo` straight into
`compiled/` (no machine subdir), strip's default `compiled-dir`
(`(car (use-compiled-file-paths))` = `"compiled"`) matches and the source
is dropped -- no `use-compiled-file-paths` parameterization needed.

**The two steps:**

1. **Bootstrap (normal `make wasm`).** Installs `PKGS`+required as source
   into `share/pkgs` and cross-compiles them to `compiled/` (tpb32l). This
   is the only run that pays the build-dep fetch/compile cost.
2. **`make wasm-binary-pkgs`** (manual; runs
   `racket/src/build-wasm-binary-pkgs.rkt` via the host `RACKET`). It
   enumerates every installed package in the in-tree installation scope
   (via `pkg/lib` with `current-pkg-scope` pointed at `share/pkgs`, so
   both catalog-copied and linked-in-place packages are covered), strips
   each into `racket/src/.wasm-pkgs-cache/pkgs/<name>`, builds a
   dirs-catalog at `.wasm-pkgs-cache/catalog` (no `--link`: install must
   *copy* into `share/pkgs` so the wholesale preload picks it up), and
   writes a `manifest.rktd`. The cache lives outside `build/` (like
   `.wasm-cache`), so `make clean` keeps it.

   The script must run in the **cross-compiler** context: `pkg/strip`'s
   `fixup-zo` reads each package `.zo` (to strip test/doc submodules), and
   tpb32l compiled fasl is machine-specific -- a plain host racket can't
   read it. `make wasm-binary-pkgs` supplies the same cross flags `raco
   setup` uses; the equivalent manual invocation (from the repo root) is:

   ```sh
   <host-racket> -G build/config \
                 -MCR racket/src/build/cs/c/compiled:build/zo: \
                 --cross-compiler tpb32l racket/src/build/cs/c \
                 racket/src/build-wasm-binary-pkgs.rkt
   ```

   The `build/zo` root is load-bearing: `generate-stripped-directory`
   loads each package's `info.rkt` via `get-info/full` (it *executes* it
   on the host), and the per-package `compiled/info_rkt.zo` under
   `share/pkgs` is tpb32l -- unloadable on the host. `build/zo` holds the
   machine-independent copy and must precede the trailing `:` (= `'same`,
   the tpb32l tree). Without it the strip dies with `fasl-read:
   incompatible fasl-object machine-type 'tpb32l` (the exact package that
   trips it depends on which `info_rkt.zo` are present, so it can appear
   to "work" for one package set and fail for another).

   (The bare host racket -- not the tree's collects via `-X` -- supplies
   `pkg/strip`/`pkg/lib`/`pkg/dirs-catalog`, so the make target passes the
   exe with an otherwise-empty argument set.)

Thereafter every `make wasm` **consumes** the cache: `install-base-pkgs`
(`main.zuo`) sees `.wasm-pkgs-cache/catalog`, **clears** `share/pkgs`
(taking the `pkgs.rktd` db), `share/links.rktd`, and
`share/info-cache.rktd`, then clean-installs `PKGS`+required from the
binary catalog as the **sole** `--catalog`, `--deps search-auto`,
`--no-setup`, and **without** `--skip-installed`. This is a deliberate
clean install, *not* an additive `--catalog` prepend: the bootstrap left
the full source + build-only tree installed, and `--skip-installed` over
it would skip everything and prune nothing. With the binary catalog as
sole source and `build-deps` stripped from every entry's `info.rkt`,
`search-auto` walks only runtime `deps` -- build-only packages are never
fetched, and the resulting `share/pkgs` is `.zo`-only. When the cache is
absent, `install-base-pkgs` falls back to the source install verbatim.

**Traps / notes:**

- `strip-binary-compile-info` defaults to `#t`, which makes strip
  `managed-compile-zo` the rewritten `info.rkt` with the **host**
  compiler -- that would inject a host-machine `info_rkt.zo` into a
  tpb32l package. The script parameterizes it to `#f` and keeps
  `info.rkt` as source; the cross `raco setup` in `wasm-setup` compiles
  it for tpb32l (it is read only by setup/pkg tooling, never at program
  runtime). The script also passes `generate-stripped-directory`
  `#:check-status? #f` to skip the built/binary precondition, since these
  are source installs we cross-compiled ourselves.
- Dependency resolution reads `deps`/`build-deps` straight from the
  staged package's `info.rkt` (`get-all-deps*` in `pkg/private/metadata`,
  `package-dependencies` in `pkg/private/collects`), so pruning happens
  **iff** the installed package is the stripped binary version -- which is
  exactly why consumption must be a clean install, not a prepend.
- **`undeclared dependency detected … for build: rackunit-lib` is
  expected noise, not a failure.** The cross `raco setup` redirects
  compiled output to `build/zo` (`-MCR`, `get-mcr-args` in `main.zuo`),
  keyed by absolute source path. The bootstrap compiled each package
  *from source* into `build/zo`, so its `.dep` records build-only imports
  from `(module+ test (require rackunit))`-style submodules. The consumed
  binary `info.rkt` has `build-deps` stripped, so setup's dependency check
  finds those imports undeclared and prints a `--- summary of package
  problems ---` listing them. These are **warnings**: setup does not fail
  on undeclared deps (no `--check-pkg-deps`), the build completes, and the
  shipped `share/pkgs` (stripped, no test submodules) is correct. Leave
  them be.
- **Do NOT delete the `build/zo` package mirrors to silence those
  warnings.** It looks tempting, but that machine-independent bytecode is
  the *only host-loadable* copy of each package: `raco setup` runs
  collection installers on the host via `dynamic-require`
  (`do-install-part`, `setup-core.rkt`). The installed `share/pkgs/.../
  compiled/*.zo` is tpb32l (target-only) -- loading it on the host throws
  `fasl-read: incompatible fasl-object machine-type 'tpb32l`, a *fatal*
  setup error. The bootstrap's `build/zo` must survive into the consume
  step. (If it is gone -- e.g. someone cleared it -- redo a source
  bootstrap `make wasm` to regenerate it, then re-run
  `make wasm-binary-pkgs` and consume.)
- Cache invalidation is manual: re-run `make wasm-binary-pkgs` when `PKGS`
  or the tree version changes (the `manifest.rktd` records both). `make
  wasm` does not auto-rebuild it.
- **List `-lib` packages in `PKGS`, not metapackages.** A metapackage
  like `pict` (vs `pict-lib`) or `draw` (vs `draw-lib`) is a catalog-only
  entry that just `implies` an implementation package plus a `-doc`
  package; it has no directory of its own. The strip catalogs
  directory-bearing packages, so the metapackage name never enters the
  binary catalog and the consume fails with `raco pkg install: cannot
  find package on catalogs / package: pict`. Worse, the metapackage drags
  its `-doc` sibling and that doc's entire build-dep closure into the
  source bootstrap (e.g. `pict` pulls in ~88 packages: typed-racket,
  drracket-tool, web-server, htdp-lib, …) -- all stripped back out, but
  slow and pointless. Use the `-lib` implementation package, matching the
  existing `draw-lib` choice.
- **Changing `PKGS` is a four-stage clean rebuild**, because the catalog
  must be stripped from a fresh *source* tree: (1) clear
  `racket/src/.wasm-pkgs-cache` and `racket/share/{pkgs,links.rktd,
  info-cache.rktd}`; (2) source bootstrap (`make wasm`, catalog absent);
  (3) `make wasm-binary-pkgs`; (4) binary consume (`make wasm`, catalog
  present). The clearing in (1) is load-bearing -- with the catalog
  present the bootstrap takes the binary branch, and with the old tree
  still installed `--skip-installed` keeps it, so either way the source
  tree the strip needs never gets built. The repo-root
  `rebuild-binary-catalog.sh` runs all four stages in order, reading
  `PKGS`/`SCHEME`/`RACKET`/`WASM_DEPS` from `buildit.sh`'s active `make
  wasm` line (override via the environment; `-n`/`--dry-run` prints the
  plan without building).
- This supersedes the `datalog` build-dep trimming: with binary install
  as the path, the vendored `pkgs/datalog/` copy has been removed and
  `datalog` installs from the upstream catalog like any other package, its
  build-deps pruned by the strip.

### Packages as a separate data file

The package tree is the part of the preload that changes most often (every
`PKGS` edit), and re-linking just to repackage it is the slow step. So **both**
surfaces ship the package payload as a **separate Emscripten data file** —
`share.data` + its loader `share.data.js`, produced by `file_packager.py` —
instead of baking it into the emcc link. Changing packages then means:
re-install + repack (`pack-pkgs`), **no relink**.

The split (in `cs/c/build.zuo`, the `wasm` target): the link preloads only
`core-preloads` (boot images + `/collects` + `/etc`, which change only on a
Racket-version rebuild) into the MEMFS, for both the node (`scheme.*`) and
browser (`scheme-web.*`) surfaces. The package tree is no longer referenced in
the link at all.

The orchestrator's `pack-share-data` (`build/stages.rkt`) runs `file_packager.py`
against the installed tree to emit `share.data`/`share.data.js` into the wasm
out dir: the wholesale `/share/pkgs`, `/share/links.rktd`, and every in-tree
`/pkgs/<name>` the links file points at (the `links-pkgs-roots` parse of
`links.rktd` for `(up up #"pkgs" #"name")` entries — formerly in `build.zuo`,
now living **only** here). It is wired into both `build` and
`rebuild-binary-catalog` (after the link, before `collect-outputs`), and exposed
standalone as `racket build/main.rkt pack-pkgs` for the repack-without-relink
path.

Both surfaces emit and share **one** `share.data`/`share.data.js` pair; the
generated loader is environment-aware (browser `fetch` vs node `readFileSync`),
and `Module.locateFile` resolves `share.data` next to the script in either case.
It is **not** built with `--use-preload-cache`: the package payload is small
(~10MB — the browser already caches the big core `.data` via the link's own
`--use-preload-cache`, and re-fetches `share.data` through the ordinary HTTP
cache), and the IndexedDB cache path throws under node (no `indexedDB`), dumping
a stack trace on every boot. Caching this tier buys little and isn't worth that.

Runtime wiring loads `share.data.js` so its loader pushes onto `Module.preRun`
and gates `run()` via `addRunDependency` until `share.data` is in MEMFS — so
`/share/pkgs` is present before `main()`, exactly as when it was in-link:

- **Browser:** `shell-worker.js` does `importScripts("./share.data.js")`
  **before** `importScripts("./scheme-web.js")`. The loader runs in the worker's
  global scope, where its self-declared `var Module` binds to the `self.Module`
  the worker set up.
- **Node:** `scheme.js`'s `Module` is module-scoped (not global) and there is no
  `importScripts`, so the baked-in `--pre-js` `node-load-share.js` reproduces the
  worker's environment: it puts this module's `Module` and `require` on
  `globalThis`, then runs `./share.data.js` via **indirect** `eval` (global
  scope). Direct eval would not do — the loader's own `var Module` would shadow
  ours and disconnect. Loading at runtime (not as another `--pre-js` payload) is
  what keeps the packages out of the link.

Two runtime methods the externally-loaded loader reaches by name —
`FS_createPath` and `FS_createDataFile` — plus `addRunDependency` /
`removeRunDependency` are added to each link's `-sEXPORTED_RUNTIME_METHODS` (the
browser already exported the latter two for IDBFS; the in-link core loader uses
minified locals and needs none exported). If `file_packager` emits a reference to
a method not yet exported, boot aborts with an "X is not exported" error — add it
to that list and rebuild.

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
  installs it as a prelude). Duck-typed on `get-argb-pixels`, so it
  pulls in `racket/class` but not `racket/draw`.
- `web-repl` (`main.rkt`) re-provides all five.

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
library and relink. `cs/c/wasm-deps/deps/cairo.sh` is the template for
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

> **Text rendering -- see branch `wasm-text-fonts-wip`.** Drawing
> (geometry) works as above, but *text* (`get-text-extent`, `draw-text`,
> `pict`'s `text`) is a separate, harder story explored on that branch.
> It is **not merged** here because it does not fully land in the browser,
> but the investigation is substantial and worth not losing. Summary of
> progress there:
>
> - **Root-caused and fixed three independent function-pointer / signature
>   mismatches** -- all tolerated by native ABIs, all rejected by wasm's
>   typed `call_indirect`, each hidden behind the previous: GObject
>   `class_init` cast (GLib; fixed via a backport of the Fluendo glib WASM
>   fork's fpcast patch), GObject `iface_init` cast (GLib; a `gtype.c`
>   call-site patch), and `cairo_font_options_copy` mis-bound 2-arg vs 1
>   (draw-lib; a genuine latent upstream Racket bug). After these, text
>   *executes*.
> - **Provisioned fontconfig** (a `fonts.conf` + DejaVu Sans + the
>   `FONTCONFIG_*`/`HOME` env), so **under node text renders reliably**.
> - **Still hangs in the browser**, and *not* for a signature reason: the
>   font path makes GLib spawn a helper thread and `g_cond_wait`s for it,
>   but `shell-worker.js` runs the module inside a Web Worker that then
>   blocks synchronously, so Emscripten can never spawn/handshake the child
>   thread (node can, hence node works). `-sPTHREAD_POOL_SIZE` made it
>   worse (startup hang). The real fixes are architectural
>   (`-sPROXY_TO_PTHREAD`, or de-threading GLib on the font path) and are
>   the open work. The branch's `build-wasm.md` has the full write-up,
>   symbolicated stacks, and the per-fix detail.

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
- `int wasm_canvas_blit(int w, int h, const void *rgba)` -- copy a
  `w*h*4` RGBA8888 buffer out of the WASM heap and `postMessage` it
  to the page; the canvas surface (`ide.js` today) renders it
  via `putImageData`. Returns 0 in a Worker, -1 in node / wherever
  `self.postMessage` is unavailable. This is the Tier 1 pixel-output
  path for everything from manual byte-pushing to a future
  `racket/draw` Cairo backend. The `_argb` / `_bgra` variants accept
  `racket/draw get-argb-pixels` output and Cairo `ARGB32` memory order
  respectively, rotating channels to RGBA during the copy out.

  The page renders `{ type:"canvas" }` messages by appending a *fresh*
  `<canvas>` into the `#output` pane per blit (`ide.js`'s
  `appendCanvas`), so a run that draws N bitmaps reads back as N images
  interleaved with its text output -- no single global canvas. The
  `web-repl` collection wraps this: `(require web-repl/display-bm)`
  then `(display-bm bm)` reads a `bitmap%` with `get-argb-pixels` and
  calls `wasm_canvas_blit_argb`, dropping one image into the output per
  call.
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

## What still has to be written

The boot harness (`racket/src/cs/c/main_em.c`) is in place, pbchunk is
wired into the link, and node boot is down to ~2 s with correct
evaluation verified. The browser shell hosts the runtime in a
dedicated Web Worker with `Atomics.wait`-blocked stdin, swapped from
an xterm to a plain textarea + scrolling output pane so the browser
handles all editing. ~319,500 Racket core-test assertions pass under
`node scheme.js` (one known PRNG corner-case failure, documented
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

   **Measured**: a full run of `port.rktl` under `node scheme.js`
   takes about **6m49s wall time**, all 797 value tests + 278
   exception-field tests pass. The same suite on a native build
   takes a few seconds.

3. **Persistent home via IDBFS, properly (transparent flush).**
   v0 is *shipped*: `/home/web_user` is mounted on IDBFS in
   `wasm-shell/idbfs-init.js` (`--pre-js`); the boot path runs
   `FS.syncfs(true)` so any previous session's files are present
   when Racket starts; a "Save & Restart" button on the page sends
   `(exit 0)` to the runtime over the input ring, the worker's
   event loop is finally free during `Module.onExit` and runs
   `FS.syncfs(false)`, the page tears down the worker and respawns
   a fresh one. Works, but REPL state is lost on every save.

   The structural cause is that the runtime worker's JS event loop
   is monopolized by `main()` -- our blocking `Atomics.wait` inside
   `shell-tty.js`'s `stream_ops.read` never returns to the event
   loop, so async IDB callbacks queued by `FS.syncfs(false)` cannot
   fire while Racket is alive. Transparent persistence (no
   restart) needs one of:
     - **`-sASYNCIFY=1`** plus a small `emscripten_sleep(0)` yield
       inside `shell-tty.js`'s read; ~1.5-3× runtime slowdown,
       ~25% larger wasm; *the right small-cost fix*.
     - **WASMFS + OPFS** via `wasmfs_create_opfs_backend()`; would
       give synchronous `FileSystemSyncAccessHandle` I/O from the
       worker, no Asyncify needed. Requires rewriting stdin/stdout
       because WASMFS replaces the legacy JS FS layer that our
       `shell-tty.js` overrides (see the trial in commit history
       for details).

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
