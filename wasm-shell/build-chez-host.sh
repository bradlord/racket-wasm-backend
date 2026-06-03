#!/usr/bin/env bash
#
# Build just the native *threaded* host Chez Scheme that the WASM
# cross-build needs (the tpb32l boot + racket.boot stages run the host
# compiler), without a full `make cs` (which also builds racket.boot, the
# racketcs executable, and installs packages + docs).
#
# This is the standalone Chez build the "Solo Chez Build" CI workflow does
# (.github/workflows/chez-build.yml): pb boot files are committed under
# racket/src/ChezScheme/boot/pb and `enableFrompb=yes` is the configure
# default, so `./configure --threads && make` bootstraps a native threaded
# Chez via pb in one step -- no `make fetch-pb`, no explicit machine type.
#
# Idempotent: if a native threaded host Chez already exists (from a prior
# `make cs` or a prior run of this script), it is left alone.
#
# Run from anywhere; paths resolve from this script's location.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/../racket/src/ChezScheme" && pwd)"  # repo/racket/src/ChezScheme
src="$(cd "$here/../racket/src" && pwd)"              # repo/racket/src

# shellcheck disable=SC1091
source "$here/host-scheme.sh"

if existing="$(find_host_scheme "$src")"; then
  echo "[skip] host Chez already present: $existing"
  exit 0
fi

cd "$chez"

echo "[cfg] host Chez (./configure --threads; bootstrap via committed boot/pb)"
./configure --threads

echo "[mk]  host Chez"
make

host_scheme="$(find_host_scheme "$src" || true)"
if [ -z "$host_scheme" ]; then
  echo "host Chez build did not produce a native threaded scheme under" >&2
  echo "  $chez/t*/bin/t*/  -- check the configure/make output above" >&2
  exit 1
fi
echo "Done. $host_scheme"
