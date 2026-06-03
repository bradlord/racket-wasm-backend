# Building Racket for WebAssembly (Emscripten)

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
- A working native Racket CS build of the same source tree. Run
  `make cs` from the repository root once. This produces:
  - `racket/bin/racket` (the host Racket used during the cross-build),
  - `racket/src/build/cs/c/ChezScheme/tarm64osx/...` (the native Chez
    used as the cross-compiler host),
  - `racket/src/build/cs/c/ChezScheme/pb/...` (a host-side basic-pb
    Chez used for bootquick).
- libffi source tarball (release 3.5.x). 3.5.2 is known to work; older
  3.4.x versions use deprecated Emscripten JS-library names
  (`generateFuncType`, `uleb128Encode`) that newer emsdk renames.

## Build sequence

The full pipeline is six stages. All paths below are relative to the
repository root. The work directories that get created live under
`racket/src/` and are gitignored.

### Integrated entry point: `make wasm`

The whole pipeline is wired into the build system as a target:

```sh
make wasm
```

`make wasm` bounces through `main.zuo`'s `wasm` target to
`wasm-shell/build.zuo`, which checks prerequisites and runs the per-stage
scripts below in order. It assumes a prior native `make cs`, an active
emsdk, and a one-time `wasm-shell/build-deps.sh` (the recipe-driven
library deps stay a manual prerequisite for now -- `make wasm` checks for
their output and fails with guidance if absent). Individual stages are
also targets, e.g. `bin/zuo wasm-shell/build.zuo em-kernel`.

`wasm-shell/build-all.sh` runs the same stage scripts directly and stays
available for working outside the build system. The remainder of this
section documents what each stage does.

### 1. Cross-compile rktio for WebAssembly

Scripted as `wasm-shell/build-rktio.sh`. The manual steps:

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

### 2. Optional libraries (libffi, future Cairo/Pango/etc.)

Optional cross-compiled libraries are built by their own stage,
`wasm-shell/build-deps.sh` (run by `build-all.sh` ahead of the
boot/kernel stages, since the deps are independent of them), through a
recipe system rooted at `wasm-shell/deps/`. Each `deps/<name>.sh` is a
shell file that sets a handful of `DEP_*` variables (source URL +
sha256, configure args, archive name, link flags, optional list of C
symbols to register with `Sforeign_symbol`); `deps.sh` provides the
shared fetch / configure / `emmake` / cache logic, and `symgen.sh`
emits `wasm_deps.inc` + `wasm_deps_uflags.txt` (`-Wl,-u` flags so
wasm-ld retains symbols nothing else references). The first recipe is
`deps/libffi.sh`; tarballs land in `racket/src/.wasm-cache/` and
builds in `racket/src/build-<name>-em/` (the same layout the old
manual step used, so existing instructions in §5 still point at the
right paths).

`build-deps.sh` also writes the resolved `-L`/`-l` flags, in final link
order, to `<boot>/.wasm-deps-linkflags.txt`; the later `build.sh` link
stage reads that file (plus `wasm_deps_uflags.txt`) rather than
re-running the recipe loop, so the two scripts share no in-memory state.

The driver picks up new deps from a `DEPS=(...)` list near the top of
`build-deps.sh`. Recipe schema in brief:

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

Meson recipes use `wasm-shell/wasm-emscripten.cross` as their
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
generated from the native `tarm64osx` (or whatever the host machine
type is) Chez built by `make cs`, *not* from a basic-pb host scheme —
the latter trips Chez's cp0 optimizer with `unexpected context ...
call current-thread/in-racket` on `thread.sls`.

Scripted as `wasm-shell/build-tpb32l-boot.sh` (auto-detects the native
host machine type and skips the `pb-host` rebuild if present). The
manual steps:

```sh
cd racket/src/ChezScheme
# A native basic-pb host workarea, needed only to invoke bootquick:
./configure --pb --workarea=pb-host && make
# Cross-build pb32l boot files and the xpatch using tarm64osx as host:
bin/zuo pb-host bootquick \
  --host-scheme ../build/cs/c/ChezScheme/tarm64osx/bin/tarm64osx/scheme \
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

Scripted as `wasm-shell/build-racket-boot.sh` (depends on §3's xpatch;
defaults `XCODE_FFI` to the macOS SDK's `ffi.h` via `xcrun`, override the
env var elsewhere). The manual steps:

```sh
cd racket/src
mkdir -p build-cs-tpb32l && cd build-cs-tpb32l
CPPFLAGS="-I$XCODE_FFI" ../cs/c/configure \
  --enable-pb --enable-target=tpb32l \
  # --disable-pbchunk \
  --enable-scheme=$PWD/../build/cs/c
# (Adjust XCODE_FFI / CPPFLAGS for your platform's libffi headers.)
# Yields MACH=<native host>, TARGET_MACH=tpb32l -- no Makefile sed.

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
whole compile-and-link of the WASM runtime is automated by

```sh
wasm-shell/build.sh           # node + browser
wasm-shell/build.sh node      # node only
wasm-shell/build.sh browser   # browser only
```

The script (re)compiles `main_em.o`, `boot.o`, `init_rktio.o`, and (on
first run) the 30 pbchunk objects, then links `scheme.{js,wasm,data}`
and/or `scheme-web.{js,wasm,data}` and installs the page assets. It is
the supported entry point — the rest of this section explains what it
runs and why, so the recipe can be reproduced or modified by hand.

The Chez Emscripten workarea has to be configured once before the
script can be used. The setup half below -- build the WASM libffi,
configure the workarea, patch `mdlinkflags`, and build `libkernel.a` --
is scripted as `wasm-shell/build-em-kernel.sh` (it builds libffi itself
so `configure --enable-libffi` is satisfied even when this stage is run
on its own, independently of the `build-deps.sh` recipe loop). The
manual steps:

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
`scheme-web.{js,wasm,data}` binary backs every browser surface (the
REPL today; a playground POC; future doc widgets / embeds / canvas
GUIs). Per-surface code is just an HTML+JS pair that drives the same
worker with a different init payload.

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
  command line. `[]` runs the interactive REPL (the browser-shell
  case); `["-u","/tmp/main.rkt"]` runs a module and exits (the
  playground case); `["-e","(form)"]` evaluates an expression; etc.
- `files` -- `{ "/abs/path": "<text>" }` written into MEMFS during
  `preRun` (before `main()`). The playground uses this to drop the
  user's source at `/tmp/main.rkt` before the runtime starts.
- `idbfs` -- whether to mount `/home/web_user` on IDBFS. The REPL
  wants persistence (`true`); transient playground runs do not
  (`false`). `idbfs-init.js` checks `Module._idbfsEnabled` and skips
  the mount when off; `shell-worker`'s `onExit` likewise skips
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
- `wasm-shell/shell-worker.js` is the worker bootstrap: it sets up
  `self.Module`, `importScripts("./scheme-web.js")` synchronously,
  and on `onRuntimeInitialized` posts the shared `HEAPU8.buffer`
  (a `SharedArrayBuffer`) plus the ring offsets back to the page.
- `browser-shell.js` runs on the page: it spawns the worker via
  `new Worker("./shell-worker.js")`, receives the buffer/offsets,
  polls the output ring each animation frame and writes typed lines
  into the input ring followed by `Atomics.notify`.

Build the browser runtime via the same script as the node one (it
adds `wasm_shell_io.o`, the `--post-js shell-tty.js`, and the ring
exports, and installs the page assets):

```sh
wasm-shell/build.sh browser
```

The underlying link is:

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
     -s EXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1 \
     -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset,_shell_in_addr,_shell_in_cap,_shell_out_addr,_shell_out_cap \
     -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction,HEAPU8,HEAP32 \
     -sALLOW_TABLE_GROWTH=1 \
     -lffi
```

Notably absent: `-sPROXY_TO_PTHREAD` and the pthread-pool flags. The
earlier design used `PROXY_TO_PTHREAD` so Emscripten itself spawned the
runtime thread, but that ran the *filesystem* on the page's main
thread (MEMFS is per-thread JS state), forcing `get_char` to be
non-blocking and the runtime to busy-poll between keystrokes. By
owning the worker ourselves, the FS and `main()` share a thread,
`get_char` truly blocks on `Atomics.wait`, and the runtime idles at 0%
CPU.

Serve with **COOP/COEP headers** — `SharedArrayBuffer` is unavailable
without cross-origin isolation, so a plain `python3 -m http.server`
will not start the runtime. `wasm-shell/serve.py` sets the headers:

```sh
cd racket/src/ChezScheme/em-tpb32l/bin/tpb32l
python3 serve.py 8123
# browse to http://127.0.0.1:8123/browser-shell.html
```

Notes / status:

- Output (stdout and stderr) is currently merged into one ring and
  rendered without color; the input ring is line-buffered on the page.
- The shell loads xterm.js from cdnjs.
- This cannot be validated under node: a headless harness can't drive
  the page+worker handshake. Test in a browser.

### Playground

`playground.html` + `playground.js` reuse the same `scheme-web.*`
artifact as the REPL. Lifecycle is **process-per-run**: each click of
*Run* spawns a fresh worker, posts
`{argv:["-u","/tmp/main.rkt"], files:{"/tmp/main.rkt": <editor text>},
idbfs:false}`, lets `main()` execute the user's module, and tears the
worker down on `exit`. A second Run spawns another worker. Cold start
is ~2 s (same as the REPL boot); program output streams through the
existing stdout ring while it runs, and a stdin textarea pipes lines
into the existing input ring for programs that `read-line`.

The lifecycle alternative -- one persistent worker that does a
custodian shutdown + fresh namespace per Run -- would get sub-second
re-runs but is harder to keep clean; deferred. Process-per-run matches
the latency users expect from comparable playgrounds (Rust, Go).

Serve and visit `http://127.0.0.1:8123/playground.html` alongside the
REPL.

### WIP: pre-generate `compiled/tpb32l`

This part is still in progress, but there is now a helper script for
pre-generating target-specific compiled files in machine-specific
subdirectories such as `compiled/tpb32l`.

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

We ship one such file at `wasm-shell/share-links.rktd` and preload it
plus each declared package via emcc `--preload-file` directives in
`build.sh`:

```sh
--preload-file ../../share/pkgs/draw-lib@/share/pkgs/draw-lib
--preload-file wasm-shell/share-links.rktd@/share/links.rktd
```

### Adding a new package

1. Pick the package's repo path under `racket/share/pkgs/`. Check its
   `info.rkt` for `(define deps ...)` -- any non-`#:platform`-gated
   entry is a transitive package you also need.
2. Add a `--preload-file ../../share/pkgs/<name>@/share/pkgs/<name>`
   entry to `LDFLAGS_COMMON` in `build.sh`.
3. Add `(root (#"pkgs" #"<name>"))` to `wasm-shell/share-links.rktd`.
4. Relink (`build.sh browser` or `node`). The new package is now
   on the collection path.

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
library and relink. `wasm-shell/deps/cairo.sh` is the template for
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
  to the page; the canvas surface (playground.js today) renders it
  via `putImageData`. Returns 0 in a Worker, -1 in node / wherever
  `self.postMessage` is unavailable. This is the Tier 1 pixel-output
  path for everything from manual byte-pushing to a future
  `racket/draw` Cairo backend.
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

Page side (an rAF loop in `browser-shell.js` and `playground.js`):

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

A Racket-side wrapper in the playground demo:

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

1. **PRNG large-range corner case.** `(random N prng)` for
   `N > 2^31` returns a value off by exactly `2^31` from the
   reference. A 32-bit signed/unsigned interpretation specific to
   `tpb32l` in the wide-range path of the PRNG; ordinary `random`
   and the other ~76,000 number tests pass. Self-contained,
   probably a one-line fix once located (look in the pb/wasm path of
   `racket/src/cs/rumble/random.ss` or wherever the random
   wide-range branch lives).

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

7. **Upstream the patches against Chez/rktio/cs.** Eight files
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
   Send them upstream so this branch stops drifting from master.

### Lower priority

1. Profile and trim the **browser** shell's startup and asset
   download (the ~26 MB wasm + ~87 MB data is fine for node but
   heavy for the web): compression, streaming instantiation, lazy
   `/collects`.
2. (Stretch) Emscripten linear-memory prewarm snapshot — only if a
   sub-second cold start is needed; see the *Open* section.
