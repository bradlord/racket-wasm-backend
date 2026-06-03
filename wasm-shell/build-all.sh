#!/bin/bash 

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

./build-rktio.sh
./build-deps.sh
./build-tpb32l-boot.sh
./build-racket-boot.sh
./build-em-kernel.sh
./build-racket-collections.sh
./build.sh
