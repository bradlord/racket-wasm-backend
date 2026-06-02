#/bin/bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT_DIR="$PWD/.."

: ${RACKET:=$ROOT_DIR/racket/bin/racket}

# Make sure the cross compiler is set up.
"$RACKET" prepare-target-cross-root.rkt

# Initialize the collections from the git source.
./init-collections.sh

# Ensure that the cross compiler is in cross mode for the expected target machine.
./racket-cross ensure-cross-mode.rkt tpb32l

# Build the collections.
./raco-cross setup --no-docs

# Install packages
./raco-cross pkg install --auto --scope installation --no-docs draw-lib
