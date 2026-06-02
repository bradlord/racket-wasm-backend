#!/usr/bin/env bash
#
# build-wasm.md §3: generate tpb32l boot files and the cross-compiler
# xpatch.
#
# Racket's thread layer uses make-pthread-parameter, so the target
# must be the *threaded* pb variant tpb32l. The cross-compiler is
# generated from the native host Chez (tarm64osx etc.) built by
# `make cs`, NOT from a basic-pb host -- the latter trips cp0 with
# "unexpected context ... call current-thread/in-racket" on
# thread.sls.
#
# Produces:
#   ChezScheme/xc-tpb32l/boot/tpb32l/{petite,scheme}.boot
#   ChezScheme/xc-tpb32l/s/xpatch
# and copies the two boot files into ChezScheme/boot/tpb32l/ where
# Chez's `--emscripten` configure (§5) expects them.
#
# This stage is a native build (no emcc needed). Run `make cs` from
# the repo root first so the host Chez exists.
#
# Run from anywhere; paths resolve from this script's location.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/.." && pwd)"          # racket/src/ChezScheme
src="$(cd "$chez/.." && pwd)"           # racket/src

# Auto-detect the native threaded host machine (tarm64osx on Apple
# silicon, ta6osx on Intel, ...). It is the t<arch> dir under the
# Chez built by `make cs` -- never the "pb" or "boot" dirs.
host_scheme="$(ls "$src"/build/cs/c/ChezScheme/t*/bin/t*/scheme 2>/dev/null | head -n1 || true)"
if [ -z "$host_scheme" ]; then
  echo "no native host Chez under $src/build/cs/c/ChezScheme/t*/" >&2
  echo "run \`make cs\` from the repo root first (build-wasm.md prereqs)" >&2
  exit 1
fi
host_mach="$(basename "$(dirname "$host_scheme")")"
echo "[host] $host_mach ($host_scheme)"

cd "$chez"

# A native basic-pb host workarea, needed only to invoke bootquick.
# Skip the slow configure+make if it is already built.
if [ ! -e pb-host/boot/pb/scheme.boot ]; then
  echo "[cfg] pb-host workarea"
  ./configure --pb --workarea=pb-host
  echo "[mk]  pb-host"
  make
else
  echo "[skip] pb-host (already built)"
fi

echo "[gen] tpb32l boot + xpatch (bootquick)"
bin/zuo pb-host bootquick --host-scheme "$host_scheme" tpb32l

for f in xc-tpb32l/boot/tpb32l/petite.boot \
         xc-tpb32l/boot/tpb32l/scheme.boot \
         xc-tpb32l/s/xpatch; do
  [ -e "$f" ] || { echo "bootquick did not produce $f" >&2; exit 1; }
done

# Place the boot files where `./configure --emscripten` (§5) looks.
echo "[cp]  boot files -> boot/tpb32l/"
mkdir -p boot/tpb32l
cp xc-tpb32l/boot/tpb32l/petite.boot boot/tpb32l/
cp xc-tpb32l/boot/tpb32l/scheme.boot boot/tpb32l/

echo "Done."
echo "  xc-tpb32l/boot/tpb32l/{petite,scheme}.boot"
echo "  xc-tpb32l/s/xpatch    (consumed by build-racket-boot.sh, §4)"
