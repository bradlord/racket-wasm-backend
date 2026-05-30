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

### 1. Cross-compile rktio for WebAssembly

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

### 2. Cross-compile libffi 3.5.2 for WebAssembly

```sh
cd racket/src/
mkdir -p build-libffi-em && cd build-libffi-em
curl -sL https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz | tar xz
mv libffi-3.5.2 src
cd src && mkdir -p build && cd build
source $EMSDK/emsdk_env.sh
emconfigure ../configure \
  --host=wasm32-unknown-emscripten \
  --enable-static --disable-shared --disable-docs \
  --disable-multi-os-directory \
  --prefix=$PWD/../../install
emmake make -j4
make install
```

The library appears at `racket/src/build-libffi-em/install/lib/libffi.a`
with headers in `.../include/`.

### 3. Generate tpb32l boot files and cross-compiler `xpatch`

The Racket `thread` layer uses `make-pthread-parameter`, so the target
must be a **threaded** pb variant: `tpb32l`. The cross-compiler is
generated from the native `tarm64osx` (or whatever the host machine
type is) Chez built by `make cs`, *not* from a basic-pb host scheme —
the latter trips Chez's cp0 optimizer with `unexpected context ...
call current-thread/in-racket` on `thread.sls`.

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
Chez Emscripten will load). The configure script doesn't expose this
cleanly when `--enable-pb --enable-mach=tpb32l` are passed together —
it sets `MACH = tpb32l` and tries to use a tpb32l host scheme. The
workaround is to configure normally and then edit `MACH` in the
generated Makefile to be the native host:

```sh
cd racket/src
mkdir -p build-cs-tpb32l && cd build-cs-tpb32l
CPPFLAGS="-I$XCODE_FFI" ../cs/c/configure \
  --enable-pb --enable-mach=tpb32l --enable-target=tpb32l \
  # --disable-pbchunk \
  --enable-scheme=$PWD/../build/cs/c
# (Adjust XCODE_FFI / CPPFLAGS for your platform's libffi headers.)

# Force cross-build: host is native, target is tpb32l.
sed -i.bak 's/^MACH = tpb32l/MACH = tarm64osx/' Makefile

# Make the cross-compile xpatch visible where build.zuo looks for it:
mkdir -p ChezScheme/xc-tpb32l/s
cp ../ChezScheme/xc-tpb32l/s/xpatch ChezScheme/xc-tpb32l/s/xpatch

make
```

The `make` succeeds through all CS layers — chezpart, rumble, thread,
io, regexp, schemify, linklet, expander, main — and writes
`racket.boot` (~4.3 MB) to the workarea root. The final
`bootstrap-racket` step fails cosmetically (`relative-path?: not a
path string: ""`) but by then `racket.boot` is already written, so the
error is non-blocking.

### 5. Build Chez Emscripten for tpb32l with libffi and the rktio link

Once everything above (rktio, libffi, host pb, `racket.boot`) exists, the
whole compile-and-link of the WASM runtime is automated by

```sh
racket/src/ChezScheme/wasm-shell/build.sh           # node + browser
racket/src/ChezScheme/wasm-shell/build.sh node      # node only
racket/src/ChezScheme/wasm-shell/build.sh browser   # browser only
```

The script (re)compiles `main_em.o`, `boot.o`, `init_rktio.o`, and (on
first run) the 30 pbchunk objects, then links `scheme.{js,wasm,data}`
and/or `scheme-web.{js,wasm,data}` and installs the page assets. It is
the supported entry point — the rest of this section explains what it
runs and why, so the recipe can be reproduced or modified by hand.

The Chez Emscripten workarea has to be configured once before the
script can be used:

```sh
cd racket/src/ChezScheme
source $EMSDK/emsdk_env.sh

CPPFLAGS="-I$PWD/../build-libffi-em/install/include" \
LDFLAGS="-L$PWD/../build-libffi-em/install/lib" \
./configure --emscripten --pbarch --threads --enable-libffi \
            --workarea=em-tpb32l \
            --emboot=$PWD/../build-cs-tpb32l/racket.boot

# libffi's wasm closures need a few extra link flags. Edit
# em-tpb32l/Mf-config and replace the mdlinkflags line with:
#   mdlinkflags=-s EXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1 \
#       -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset \
#       -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction \
#       -sALLOW_TABLE_GROWTH=1
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

The browser shell in `racket/src/ChezScheme/wasm-shell/` loads Racket
into an xterm.js terminal. It needs a **separate, browser-specific
build** of the runtime, because the node `scheme.js` runs `main()` on
the calling thread: in a browser that would be the page's main thread,
and Racket's blocking REPL stdin read would freeze the event loop.

The page therefore hosts the runtime in a dedicated Web Worker it
spawns itself (`shell-worker.js`); `main()` runs on that worker's own
thread, free to block on stdin, while the page stays responsive. The
two threads exchange console bytes through ring buffers in the
module's *shared* linear memory (`-pthread` makes
`WebAssembly.Memory({shared:true})`, even though Racket never spawns
pthreads of its own):

- `racket/src/cs/c/wasm_shell_io.c` reserves the rings in the shared
  heap and exports their addresses.
- `racket/src/ChezScheme/wasm-shell/shell-tty.js` is linked in with
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
racket/src/ChezScheme/wasm-shell/build.sh browser
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

`racket/src/ChezScheme/wasm-shell/run-tests.sh` runs a slice of the
checked-in Racket core tests (the `.rktl` files in
`pkgs/racket-test-core/tests/racket/`) under the WASM/node build. Each
`.rktl` is a flat script that expects to be `load`ed inside a session
that already evaluated `testing.rktl`, so the script concatenates the
two and pipes them through `node scheme.js`, then greps for the per-test
summary line.

```sh
racket/src/ChezScheme/wasm-shell/run-tests.sh             # default slice
racket/src/ChezScheme/wasm-shell/run-tests.sh list hash   # by name
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

2. **rktio gaps surfaced by `port.rktl`.** `port.rktl` is excluded
   from `run-tests.sh`'s default slice because it hangs. Triage:
   which rktio entry points does it exercise that aren't implemented
   for Emscripten? Likely culprits are file-change notifications,
   subprocess, and anything that calls into platform features rktio
   marks as unsupported. Each gap is an `RKTIO_ERROR_UNSUPPORTED`
   stub or a real implementation; finishing them broadens what real
   Racket code runs.

3. **Persistent home via IDBFS.** Mount Emscripten's IDBFS at
   `/home/web_user` (or wherever) in `main_em.c`, with a sync hook
   on exit / idle so writes survive a reload. ~20 lines plus a
   `preRun` in the page. Lets the in-browser REPL keep a
   `~/.racketrc`, saved files, and (eventually) a `.zo` cache. This
   is the gateway feature for `raco` to make sense in the browser.

4. **Networking via a WebSocket-bridged `rktio_network`.** Real TCP
   isn't possible from a browser; a WebSocket tunnel back to a
   small server can pretend to be one. The work is in
   `racket/src/rktio/rktio_network.c` plus a JS shim. With this
   `racket/tcp` would work, which is a prerequisite for the
   package manager and for any web-shaped demo. Significant
   effort, on the order of a week.

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

7. **Upstream the patches against Chez/rktio.** The 5 files
   modified in master (`ChezScheme/c/ffi.c`, `ChezScheme/s/prims.ss`,
   `rktio/rktio_platform.h`, `rktio/rktio_poll_set.c`,
   `rktio/rktio_process.c`) are clean conditional additions,
   behavior-preserving on every other platform. Send them upstream
   so this branch stops drifting from master.

### Lower priority

1. Profile and trim the **browser** shell's startup and asset
   download (the ~26 MB wasm + ~87 MB data is fine for node but
   heavy for the web): compression, streaming instantiation, lazy
   `/collects`.
2. (Stretch) Emscripten linear-memory prewarm snapshot — only if a
   sub-second cold start is needed; see the *Open* section.
