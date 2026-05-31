#!/usr/bin/env bash
#
# Relink (and where needed, recompile) the WASM Racket build:
#   - main_em.o, boot.o, init_rktio.o, wasm_shell_io.o (always)
#   - 30 pbchunk objects (only if missing)
#   - scheme.{js,wasm,data}                 (node target)
#   - scheme-web.{js,wasm,data} + page      (browser target)
#
# Assumes the heavy stages from build-wasm.md are already done:
#   - racket/src/rktio/build-em/librktio.a
#   - racket/src/build-libffi-em/install/{include,lib}
#   - racket/src/build-cs-tpb32l/{petite,scheme,racket}-pbchunk.boot
#     and {petite,scheme,racket}{0..9}.c chunk sources
#   - racket/src/ChezScheme/em-tpb32l/  (created by `./configure --emscripten ...`)
#   - racket/src/ChezScheme/em-tpb32l/boot/tpb32l/libkernel.a
#
# Run from anywhere; paths resolve from this script's location.
#
# Usage:
#   ./build.sh                # both node and browser
#   ./build.sh node           # node only
#   ./build.sh browser        # browser only

set -euo pipefail

target="${1:-all}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/.." && pwd)"          # racket/src/ChezScheme
src="$(cd "$chez/.." && pwd)"           # racket/src

cd "$chez"

if [ -z "${EMSDK:-}" ] && [ -f "$HOME/emsdk/emsdk_env.sh" ]; then
  # shellcheck disable=SC1091
  EMSDK_QUIET=1 source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1
fi
command -v emcc >/dev/null || { echo "emcc not on PATH; source emsdk_env.sh first" >&2; exit 1; }

# emsdk_env.sh adds upstream/emscripten to PATH but not upstream/bin.
# Recipes that scrape symbols (e.g. cairo.sh) want llvm-nm; expose it.
emcc_path=$(command -v emcc)
emsdk_upstream_bin="$(cd "$(dirname "$emcc_path")"/../bin 2>/dev/null && pwd)"
[ -n "$emsdk_upstream_bin" ] && case ":$PATH:" in
  *":$emsdk_upstream_bin:"*) ;;
  *) export PATH="$emsdk_upstream_bin:$PATH" ;;
esac

boot=em-tpb32l/boot/tpb32l
out=em-tpb32l/bin/tpb32l
rktio_a="$src/rktio/build-em/librktio.a"
cs_boot="$src/build-cs-tpb32l"

for f in "$rktio_a" "$cs_boot/racket-pbchunk.boot" "$boot/libkernel.a"; do
  [ -e "$f" ] || { echo "missing prerequisite: $f" >&2; exit 1; }
done

mkdir -p "$out"

# ---- optional deps (driven by recipes under deps/) -----------------
#
# rktio stays special-cased: it lives in-tree, and build-wasm.md §1
# builds it with the configure quirks the recipe schema would have to
# encode by hand (e.g. the @HIDE_NOT_STANDALONE@ archive rename).
# Everything else flows through deps/<name>.sh -- see deps.sh.

# shellcheck disable=SC1091
source "$here/deps.sh"

export WASM_SRC_DIR="$src"
export WASM_SHELL_DIR="$here"

DEPS=(libffi libpng pixman freetype cairo libjpeg-turbo)
# -L flags collected in any order (they apply globally), -l flags in
# reverse DEPS order: leaves of the dep tree (libffi, libpng, ...) are
# built first but must appear LAST on the wasm-ld line so that more-
# rooted libs (cairo) can pull in their referents.
DEPS_LIBDIRS=()
DEPS_LIBS=()
symbols_manifest="$boot/.wasm-deps-symbols.txt"
mkdir -p "$boot"
: > "$symbols_manifest"

for dep_file in "${DEPS[@]}"; do
  wasm_dep_reset
  # shellcheck disable=SC1090
  source "$here/deps/$dep_file.sh"
  wasm_dep_paths
  wasm_dep_fetch
  wasm_dep_build
  wasm_dep_symbols >> "$symbols_manifest"
  [ -d "$DEP_PREFIX/lib" ] && DEPS_LIBDIRS+=(-L "$DEP_PREFIX/lib")
  # Prepend so the iteration order produces the right link order.
  DEPS_LIBS=("${DEP_LINK_FLAGS[@]+"${DEP_LINK_FLAGS[@]}"}"
             "${DEPS_LIBS[@]+"${DEPS_LIBS[@]}"}")
done

echo "[gen] wasm_deps.inc + uflags"
"$here/symgen.sh" "$symbols_manifest" "$boot"
uflags_file="$boot/wasm_deps_uflags.txt"

CFLAGS=(-DPORTABLE_BYTECODE -O2 -pthread -s USE_ZLIB=1)
INCS=(-I em-tpb32l/boot/tpb32l -I em-tpb32l/c -I c/)
RKTIO_INCS=(-I "$src/rktio" -I "$src/rktio/build-em")
CS_INCS=(-I "$src/cs/c")

# ---- small object compiles (cheap; always run) ---------------------

echo "[cc]  main_em.o"
emcc "${CFLAGS[@]}" "${INCS[@]}" "${CS_INCS[@]}" -Wall -Wextra \
     -o "$boot/main_em.o" -c "$src/cs/c/main_em.c"

echo "[cc]  boot.o"
emcc "${CFLAGS[@]}" -DPBCHUNK_REGISTER \
     -DRACKET_EXTRA_FOREIGN_INC='"wasm_extras.inc"' \
     "${INCS[@]}" "${CS_INCS[@]}" "${RKTIO_INCS[@]}" \
     -o "$boot/boot.o" -c "$src/cs/c/boot.c"

echo "[cc]  wasm_http.o"
emcc "${CFLAGS[@]}" "${INCS[@]}" "${CS_INCS[@]}" \
     -o "$boot/wasm_http.o" -c "$src/cs/c/wasm_http.c"

echo "[cc]  wasm_canvas.o"
emcc "${CFLAGS[@]}" "${INCS[@]}" "${CS_INCS[@]}" \
     -o "$boot/wasm_canvas.o" -c "$src/cs/c/wasm_canvas.c"

echo "[cc]  wasm_stubs.o"
emcc "${CFLAGS[@]}" "${INCS[@]}" "${CS_INCS[@]}" \
     -o "$boot/wasm_stubs.o" -c "$src/cs/c/wasm_stubs.c"

echo "[cc]  init_rktio.o"
emcc "${CFLAGS[@]}" "${INCS[@]}" "${RKTIO_INCS[@]}" \
     -o "$boot/init_rktio.o" -c c/init_rktio.c

# ---- pbchunks (slow; reuse if already built) -----------------------

need_chunks=0
for b in petite scheme racket; do
  for i in 0 1 2 3 4 5 6 7 8 9; do
    [ -e "$boot/$b$i.o" ] || { need_chunks=1; break 2; }
  done
done

if [ "$need_chunks" = 1 ]; then
  echo "[cc]  30 pbchunks (one-time)"
  for b in petite scheme racket; do
    for i in 0 1 2 3 4 5 6 7 8 9; do
      emcc "${CFLAGS[@]}" "${INCS[@]}" -o "$boot/$b$i.o" -c "$cs_boot/$b$i.c"
    done
  done
else
  echo "[skip] pbchunks (already built)"
fi

chunks=( "$boot"/{petite,scheme,racket}{0,1,2,3,4,5,6,7,8,9}.o )

LDFLAGS_COMMON=(
  -O2 -pthread -s USE_ZLIB=1
  "${DEPS_LIBDIRS[@]+"${DEPS_LIBDIRS[@]}"}"
  "${DEPS_LIBS[@]+"${DEPS_LIBS[@]}"}"
  --preload-file "$cs_boot/petite-pbchunk.boot@petite.boot"
  --preload-file "$cs_boot/scheme-pbchunk.boot@scheme.boot"
  --preload-file "$cs_boot/racket-pbchunk.boot@racket.boot"
  --preload-file ../../collects@/collects
  --preload-file ../../etc@/etc
  --preload-file ../../share/pkgs/draw-lib@/share/pkgs/draw-lib
  --preload-file wasm-shell/share-links.rktd@/share/links.rktd
  -s EXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1
  -sALLOW_TABLE_GROWTH=1
)

# Force-link symbols the recipe manifest registers via Sforeign_symbol.
# wasm-ld would otherwise strip them before init_foreign can take
# their address. Empty when no recipe declares symbols (libffi today).
uflags_read=()
if [ -s "$uflags_file" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && uflags_read+=("$line")
  done < "$uflags_file"
fi

link_node() {
  echo "[ld]  scheme.{js,wasm,data}  (node)"
  emcc -o "$out/scheme.html" \
       "$boot/main_em.o" "$boot/boot.o" "$boot/init_rktio.o" \
       "$boot/wasm_http.o" "$boot/wasm_canvas.o" "$boot/wasm_stubs.o" \
       "${chunks[@]}" \
       "$boot/libkernel.a" em-tpb32l/lz4/lib/liblz4.a "$rktio_a" \
       --post-js wasm-shell/node-tty.js \
       "${LDFLAGS_COMMON[@]}" \
       "${uflags_read[@]+"${uflags_read[@]}"}" \
       -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset \
       -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction
}

link_browser() {
  echo "[cc]  wasm_shell_io.o"
  emcc "${CFLAGS[@]}" "${INCS[@]}" \
       -o "$boot/wasm_shell_io.o" -c "$src/cs/c/wasm_shell_io.c"

  echo "[ld]  scheme-web.{js,wasm,data}  (browser, dedicated worker)"
  emcc -o "$out/scheme-web.html" \
       "$boot/main_em.o" "$boot/boot.o" "$boot/init_rktio.o" \
       "$boot/wasm_shell_io.o" \
       "$boot/wasm_http.o" "$boot/wasm_canvas.o" "$boot/wasm_stubs.o" \
       "${chunks[@]}" \
       "$boot/libkernel.a" em-tpb32l/lz4/lib/liblz4.a "$rktio_a" \
       --pre-js  wasm-shell/idbfs-init.js \
       --post-js wasm-shell/shell-tty.js \
       "${LDFLAGS_COMMON[@]}" \
       "${uflags_read[@]+"${uflags_read[@]}"}" \
       -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset,_shell_in_addr,_shell_in_cap,_shell_out_addr,_shell_out_cap \
       -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction,HEAPU8,HEAP32,FS,addRunDependency,removeRunDependency \
       -sFORCE_FILESYSTEM=1 \
       -lidbfs.js

  if [ -f "$src/ChezScheme/install-wasm-browser-shell.rkt" ] && command -v racket >/dev/null; then
    echo "[gen] page assets"
    racket -c "$src/ChezScheme/install-wasm-browser-shell.rkt" "$out"
  elif [ -f "$src/../bin/racket" ]; then
    echo "[gen] page assets"
    "$src/../bin/racket" -c "$src/ChezScheme/install-wasm-browser-shell.rkt" "$out"
  fi
}

case "$target" in
  node)    link_node ;;
  browser) link_browser ;;
  all)     link_node; link_browser ;;
  *)       echo "unknown target: $target (use: node | browser | all)" >&2; exit 1 ;;
esac

echo "Done. Run:"
echo "  cd $chez/$out && echo '(+ 1 2)' | node scheme.js"
[ "$target" = "all" ] || [ "$target" = "browser" ] && \
  echo "  cd $chez/$out && python3 serve.py 8123  # then open http://127.0.0.1:8123/browser-shell.html"
