#!/usr/bin/env bash
#
# build-wasm.md §4: cross-build racket.boot (and the pbchunk variants)
# for the tpb32l target.
#
# Host machine type is the native host (so it can run the compiler);
# target machine type is tpb32l (so racket.boot matches what Chez
# Emscripten loads). `cs/c/configure --enable-pb --enable-target=tpb32l`
# now expresses that split directly: it auto-detects the host MACH and
# keeps TARGET_MACH/KERNEL_TARGET_MACH at the requested pb machine. (It
# used to clobber an explicit pb target with the host-derived pb name,
# so this script passed --enable-mach=tpb32l and sed-rewrote MACH back
# to the host; that workaround is gone now that configure honors the
# explicit target -- see build-wasm.md's upstream-patches list.)
#
# Produces in racket/src/build-cs-tpb32l/:
#   racket.boot (~4.3 MB)
#   {petite,scheme,racket}-pbchunk.boot
#   {petite,scheme,racket}{0..9}.c   (30 pbchunk C sources)
#
# Depends on §3 output (xc-tpb32l/s/xpatch): run
# build-tpb32l-boot.sh first. This is a native build (no emcc), but
# it needs the *host's* libffi headers (XCODE_FFI). On macOS those
# come from the SDK via xcrun; override XCODE_FFI to point elsewhere.
#
# Run from anywhere; paths resolve from this script's location.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/../racket/src/ChezScheme" && pwd)"  # repo/racket/src/ChezScheme
src="$(cd "$here/../racket/src" && pwd)"              # repo/racket/src
build="$src/build-cs-tpb32l"

xpatch="$chez/xc-tpb32l/s/xpatch"
if [ ! -e "$xpatch" ]; then
  echo "missing $xpatch" >&2
  echo "run wasm-shell/build-tpb32l-boot.sh first (build-wasm.md §3)" >&2
  exit 1
fi

# Native libffi headers for the host racket.boot compile. Default to
# the macOS SDK; override XCODE_FFI for other platforms / locations.
if [ -z "${XCODE_FFI:-}" ] && command -v xcrun >/dev/null 2>&1; then
  XCODE_FFI="$(xcrun --show-sdk-path)/usr/include/ffi"
fi
if [ -n "${XCODE_FFI:-}" ] && [ -e "$XCODE_FFI/ffi.h" ]; then
  echo "[ffi] $XCODE_FFI"
else
  echo "warning: no libffi headers found (XCODE_FFI=${XCODE_FFI:-unset});" >&2
  echo "set XCODE_FFI to a dir containing ffi.h if configure fails" >&2
fi

mkdir -p "$build"
cd "$build"

echo "[cfg] build-cs-tpb32l"
# `--enable-target=tpb32l` (a pb machine) now cross-builds cleanly: the
# host MACH is auto-detected and TARGET_MACH/KERNEL_TARGET_MACH stay
# tpb32l. This used to require `--enable-mach=tpb32l` plus a post-hoc
# `sed` to put MACH back to the host; cs/c/configure now honors an
# explicit pb `--enable-target` (see build-wasm.md upstream-patches).
CPPFLAGS="${XCODE_FFI:+-I$XCODE_FFI}" ../cs/c/configure \
  --enable-pb --enable-target=tpb32l \
  --enable-scheme="$PWD/../build/cs/c"

# Make the cross-compile xpatch visible where build.zuo looks for it.
echo "[cp]  xpatch -> ChezScheme/xc-tpb32l/s/"
mkdir -p ChezScheme/xc-tpb32l/s
cp "$xpatch" ChezScheme/xc-tpb32l/s/xpatch

# bin/zuo is a Makefile target (compiles zuo/zuo.c); a fresh workarea
# has no bin/zuo yet, so build it before driving the boot build.
if [ ! -x bin/zuo ]; then
  echo "[mk]  bin/zuo"
  make bin/zuo
fi

# Build the Chez tpb32l kernel + boot files first. The racket-pbchunk
# target consumes ChezScheme/tpb32l/boot/tpb32l/{petite,scheme}.boot as
# plain inputs (they have no build rule of their own -- the `scheme`
# target produces them as a side effect via bootquick --xpatch). Skip
# this and the pbchunk build dies with
#   missing input file: "ChezScheme/tpb32l/boot/tpb32l/petite.boot".
echo "[mk]  Chez tpb32l kernel + boot (scheme target)"
bin/zuo . scheme

echo "[mk]  racket-pbchunk.boot"
# The pbchunk target stops cleanly before the host racketcs link that
# `make` would attempt (and fail on a cross-build).
bin/zuo . racket-pbchunk.boot

for f in racket.boot racket-pbchunk.boot scheme-pbchunk.boot petite-pbchunk.boot; do
  [ -e "$f" ] || { echo "$f was not produced" >&2; exit 1; }
done
echo "Done. $build/racket-pbchunk.boot and 30 pbchunk sources."
