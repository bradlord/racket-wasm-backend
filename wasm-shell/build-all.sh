#!/bin/bash 

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

./build-rktio.sh
# The recipe-driven native deps moved into the stock build tree
# (racket/src/cs/c/wasm-deps/). Invoke the relocated driver, writing its
# artifacts into the chez boot dir the legacy build.sh reads from, and
# building the full draw stack (what the old in-script DEPS list did).
../racket/src/cs/c/wasm-deps/build-deps.sh \
  --src ../racket/src \
  --out ../racket/src/ChezScheme/em-tpb32l/boot/tpb32l \
  --deps draw
./build-tpb32l-boot.sh
./build-racket-boot.sh
./build-em-kernel.sh
./build-racket-collections.sh
./build.sh
