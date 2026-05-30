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
the calling thread: in a browser that is the page's main thread, and
Racket's blocking REPL stdin read would freeze the event loop (the page
goes unresponsive). The browser build fixes this with
`-sPROXY_TO_PTHREAD`, which runs `main()` on a worker thread and leaves
the page responsive.

Because `main()` is off the main thread, stdin/stdout must cross a
thread boundary. The build uses shared linear memory
(`WebAssembly.Memory({shared:true})`, already required by the pthread
build), so two ring buffers carry console bytes:

- `racket/src/cs/c/wasm_shell_io.c` reserves the rings in the shared
  heap and exports their addresses.
- `racket/src/ChezScheme/wasm-shell/shell-tty.js` is linked in with
  `emcc --post-js`. It runs inside every thread's module instance and
  replaces the TTY `get_char`/`put_char` ops: `get_char` blocks on the
  input ring with `Atomics.wait` (safe on the worker), `put_char`
  pushes each byte into the output ring (no newline buffering, so the
  REPL prompt appears immediately).
- `browser-shell.js` runs on the page: it polls the output ring each
  animation frame and writes to xterm, and writes typed lines into the
  input ring followed by `Atomics.notify`.

Build the browser runtime (after the object files from §5 exist) by
adding `wasm_shell_io.o`, the `--post-js`, the ring exports, and
`-sPROXY_TO_PTHREAD` to the link, with a distinct output name so the
node `scheme.*` build is left intact:

```sh
cd racket/src/ChezScheme
source $EMSDK/emsdk_env.sh

emcc -DPORTABLE_BYTECODE \
     -I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/ -O2 -pthread \
     -o em-tpb32l/boot/tpb32l/wasm_shell_io.o -c ../cs/c/wasm_shell_io.c

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
     -s PROXY_TO_PTHREAD=1 -s PTHREAD_POOL_SIZE=8 -s PTHREAD_POOL_SIZE_STRICT=0 \
     -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset,_shell_in_addr,_shell_in_cap,_shell_out_addr,_shell_out_cap \
     -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction,HEAPU8,HEAP32 \
     -sALLOW_TABLE_GROWTH=1 \
     -lffi
```

Install the page assets next to the generated `scheme-web.*`:

```sh
./../../bin/racket -c ./install-wasm-browser-shell.rkt ./em-tpb32l/bin/tpb32l
```

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
- This cannot be validated under node: node's main thread bootstraps the
  PROXY_TO_PTHREAD worker with a synchronous `Atomics.wait`, which a
  headless harness can't drive; the browser uses the async path. Test in
  a browser.

stdin and the EAGAIN/ESPIPE subtlety: under `-sPROXY_TO_PTHREAD` the
filesystem syscalls are proxied to the **main thread** (MEMFS is
per-thread JS state), so the TTY `get_char` actually runs on the main
browser thread. It therefore must NOT block: `Atomics.wait` is illegal
on the main thread and throws, which Emscripten reports as `ESPIPE`
(errno 29) -- rktio then treats it as a fatal "error reading from stream
port" and the REPL loops on the error. `shell-tty.js` instead reads the
input ring non-blockingly and returns `undefined` when empty; Emscripten
maps that to `EAGAIN` (Emscripten/WASI errno 6), which rktio handles as a
clean would-block and retries. Returning `null` must be avoided -- it
reads as EOF and ends the REPL.

Known limitation (busy-poll): because the TTY reports readable to
`poll`/`select` even when the ring is empty, Racket's scheduler retries
the (proxied) read continuously while idling at the prompt, so a CPU core
can spin between keystrokes. It is functional but not power-friendly. The
clean fix is to drop PROXY_TO_PTHREAD and instead host the runtime in a
plain Web Worker, where `get_char` *can* block on `Atomics.wait` (the FS
is local to that worker, not proxied) -- a genuinely blocking read with
no polling. That is the recommended next step if the spin matters.

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

## What still has to be written

The boot harness (`racket/src/cs/c/main_em.c`) is in place, pbchunk is
wired into the link, and node boot is down to ~2 s with correct
evaluation verified. Remaining work, roughly in order:

1. Profile and trim the **browser** shell's startup and asset download
   (the ~26 MB wasm + ~87 MB data is fine for node but heavy for the
   web): compression, streaming instantiation, lazy `/collects`.
2. Verify first-class continuations work end-to-end *through Racket*
   (not just at the Chez pb level).
3. (Stretch) Emscripten linear-memory prewarm snapshot — only if a
   sub-second cold start is needed; see the *Open* section.
