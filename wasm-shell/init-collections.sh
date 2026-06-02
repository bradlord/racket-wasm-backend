#/bin/bash

cd "$(dirname "${BASH_SOURCE[0]}")"/..


CROSS_DIR="$PWD/racket/src/build-cs-tpb32l/cross-root/tpb32l"
echo "Initializing collections for cross-compilation..."

if [ -d "$CROSS_DIR/collects" ]; then
  echo "[skip] collections (already initialized)"
  exit 0
fi

git ls-files racket/collects | while read f; do
  dest="$CROSS_DIR/collects/${f#racket/collects/}"
  mkdir -p "$(dirname "$dest")"
  cp "$f" "$dest"
done
