#!/usr/bin/env bash
#
# build-wasm.md §5 (setup half): configure the Chez Emscripten workarea
# for tpb32l and build its kernel.
#
# This is the one-time setup that `build.sh` assumes already exists; it
# produces the prerequisite `build.sh` checks for:
#   ChezScheme/em-tpb32l/boot/tpb32l/libkernel.a
# After this runs, drive the object compiles + final link with build.sh.
#
# Steps:
#   1. build the WASM libffi (deps/libffi.sh) -- §5's configure links
#      against it, and build.sh's own dep loop runs too late (after its
#      libkernel.a prereq check) to satisfy that.
#   2. ./configure --emscripten ... --workarea=em-tpb32l
#   3. rewrite Mf-config's mdlinkflags (libffi wasm closures need the
#      extra emcc link flags; the stock line omits them).
#   4. bin/zuo em-tpb32l kernel  -> libkernel.a
#
# Depends on §4 (build-cs-tpb32l/racket.boot) and §3 (bin/zuo). Run
# from anywhere; paths resolve from this script's location.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/.." && pwd)"          # racket/src/ChezScheme
src="$(cd "$chez/.." && pwd)"           # racket/src

if [ -z "${EMSDK:-}" ] && [ -f "$HOME/emsdk/emsdk_env.sh" ]; then
  # shellcheck disable=SC1091
  EMSDK_QUIET=1 source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1
fi
command -v emcc >/dev/null || {
  echo "emcc not on PATH; source emsdk_env.sh first" >&2; exit 1; }

emboot="$src/build-cs-tpb32l/racket.boot"
if [ ! -e "$emboot" ]; then
  echo "missing $emboot" >&2
  echo "run wasm-shell/build-racket-boot.sh first (build-wasm.md §4)" >&2
  exit 1
fi

cd "$chez"

if [ ! -x bin/zuo ]; then
  echo "missing $chez/bin/zuo" >&2
  echo "run wasm-shell/build-tpb32l-boot.sh first (it builds bin/zuo, §3)" >&2
  exit 1
fi

# ---- 1. WASM libffi (idempotent; build.sh's dep loop skips it later) --
echo "[dep] libffi (build-libffi-em)"
# shellcheck disable=SC1091
source "$here/deps.sh"
export WASM_SRC_DIR="$src"
export WASM_SHELL_DIR="$here"
wasm_dep_reset
# shellcheck disable=SC1091
source "$here/deps/libffi.sh"
wasm_dep_paths
wasm_dep_fetch
wasm_dep_build
libffi_prefix="$DEP_PREFIX"          # $src/build-libffi-em/install

# ---- 2. configure the em-tpb32l workarea (once) ----------------------
if [ ! -e em-tpb32l/Mf-config ]; then
  echo "[cfg] em-tpb32l (--emscripten --pbarch --threads --enable-libffi)"
  CPPFLAGS="-I$libffi_prefix/include" \
  LDFLAGS="-L$libffi_prefix/lib" \
  ./configure --emscripten --pbarch --threads --enable-libffi \
              --workarea=em-tpb32l \
              --emboot="$emboot"
else
  echo "[skip] configure (em-tpb32l/Mf-config exists)"
fi

# ---- 3. patch Mf-config's mdlinkflags (idempotent) -------------------
# libffi's wasm closures need addFunction/removeFunction + table growth;
# the stock mdlinkflags line doesn't export them.
mdlinkflags='mdlinkflags=-s EXIT_RUNTIME=1 -s ALLOW_MEMORY_GROWTH=1 -sEXPORTED_FUNCTIONS=_malloc,_free,_main,_setThrew,_memcpy,_memset -sEXPORTED_RUNTIME_METHODS=getValue,setValue,UTF8ToString,stringToUTF8,addFunction,removeFunction -sALLOW_TABLE_GROWTH=1'
if grep -q '^mdlinkflags=' em-tpb32l/Mf-config; then
  awk -v repl="$mdlinkflags" \
      '/^mdlinkflags=/{print repl; next} {print}' \
      em-tpb32l/Mf-config > em-tpb32l/Mf-config.tmp
  mv em-tpb32l/Mf-config.tmp em-tpb32l/Mf-config
else
  printf '%s\n' "$mdlinkflags" >> em-tpb32l/Mf-config
fi
echo "[mf]  mdlinkflags patched"

# ---- 4. build the kernel -> libkernel.a ------------------------------
libkernel=em-tpb32l/boot/tpb32l/libkernel.a
if [ ! -e "$libkernel" ]; then
  echo "[mk]  $libkernel (bin/zuo em-tpb32l kernel)"
  bin/zuo em-tpb32l kernel
else
  echo "[skip] kernel (libkernel.a exists)"
fi

[ -e "$libkernel" ] || { echo "$libkernel was not produced" >&2; exit 1; }
echo "Done. $chez/$libkernel"
echo "Now run wasm-shell/build.sh to compile objects and link."
