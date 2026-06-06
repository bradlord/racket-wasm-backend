#!/bin/sh
# rebuild-binary-catalog.sh -- full clean rebuild of the WASM binary-only
# package catalog. Run this after changing PKGS (see build-wasm.md,
# "Binary-only package preload"). It performs the four stages that must
# happen in order; skipping or reordering them reproduces the failure
# modes documented in build-wasm.md (fasl 'tpb32l, missing man pages,
# undeclared dependencies):
#
#   1. clear the binary catalog + the installed package tree, so the
#      bootstrap does a clean *source* install (the catalog-present or
#      already-installed states would otherwise short-circuit it);
#   2. source bootstrap -- installs PKGS from source, cross-compiles, and
#      regenerates build/zo (the host-loadable bytecode the next two
#      stages depend on). Ships a large .data;
#   3. strip the binary-only catalog from that source tree;
#   4. binary consume -- installs the stripped .zo-only tree and ships the
#      small .data.
#
# Build vars (SCHEME / RACKET / PKGS / WASM_DEPS) are read from buildit.sh's
# active (uncommented) `make wasm` line, so PKGS lives in one place. Any of
# them can be overridden from the environment, e.g.:
#
#   PKGS="draw-lib pict" ./rebuild-binary-catalog.sh
#
# Pass -n / --dry-run to print the resolved config and the stages without
# running them.

set -e

cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

DRY=0
case "${1:-}" in
  -n|--dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: $0 [-n|--dry-run]" >&2; exit 2 ;;
esac

# --- read build vars from buildit.sh's active (uncommented) make wasm line ---
active_cmd=$(awk '
  /^[[:space:]]*#/ { next }                 # skip comment lines
  /make[[:space:]]+wasm/ { grab=1 }
  grab { printf "%s ", $0; if ($0 !~ /\\[[:space:]]*$/) exit }  # until no trailing backslash
' buildit.sh)

parse() {  # $1 = VAR name -> value from the make line (quoted or bare)
  printf ' %s\n' "$active_cmd" \
    | grep -oE "[[:space:]]$1=(\"[^\"]*\"|'[^']*'|[^[:space:]]*)" \
    | head -1 \
    | sed -E "s/^[[:space:]]*$1=//; s/^[\"']//; s/[\"']\$//"
}

SCHEME="${SCHEME:-$(parse SCHEME)}"
RACKET="${RACKET:-$(parse RACKET)}"
PKGS="${PKGS:-$(parse PKGS)}"
WASM_DEPS="${WASM_DEPS:-$(parse WASM_DEPS)}"

# buildit.sh writes paths with a literal $HOME; expand it.
SCHEME=$(eval echo "$SCHEME")
RACKET=$(eval echo "$RACKET")

MACH_FLAGS="-MCR $(pwd)/build/zo:"

for v in SCHEME RACKET PKGS WASM_DEPS; do
  eval "val=\${$v}"
  [ -n "$val" ] || { echo "error: could not determine $v -- set it in the environment or buildit.sh" >&2; exit 1; }
done

echo "Resolved config (from buildit.sh, override via env):"
echo "  SCHEME    = $SCHEME"
echo "  RACKET    = $RACKET"
echo "  PKGS      = $PKGS"
echo "  WASM_DEPS = $WASM_DEPS"
echo "  -MCR root = $(pwd)/build/zo"
echo

run() {  # echo + run (or just echo under --dry-run)
  echo "+ $*"
  [ "$DRY" = 1 ] || "$@"
}
run_make() {  # $1 = make target
  run make "$1" \
      SCHEME="$SCHEME" RACKET="$RACKET" PKGS="$PKGS" WASM_DEPS="$WASM_DEPS" \
      SETUP_MACHINE_FLAGS="$MACH_FLAGS"
}

if [ "$DRY" = 1 ]; then
  echo "(dry run -- nothing will be executed)"
  echo
else
  EMSDK_ENV="${EMSDK_ENV:-$HOME/emsdk/emsdk_env.sh}"
  # shellcheck disable=SC1090
  . "$EMSDK_ENV" >/dev/null
fi

echo "==> [1/4] clearing binary catalog + installed package tree"
run rm -rf racket/src/.wasm-pkgs-cache
run rm -rf racket/share/pkgs racket/share/links.rktd racket/share/info-cache.rktd
echo

echo "==> [2/4] source bootstrap (installs PKGS from source, regenerates build/zo)"
run_make wasm
echo

echo "==> [3/4] stripping binary-only catalog"
run_make wasm-binary-pkgs
echo

echo "==> [4/4] binary consume (ships the .zo-only image)"
run_make wasm
echo

if [ "$DRY" = 1 ]; then
  echo "Dry run complete."
  exit 0
fi

echo "Done."
data=racket/src/build/cs/c/wasm/scheme.data
[ -f "$data" ] && ls -lh "$data" | awk '{print "  scheme.data =", $5}'
if command -v node >/dev/null 2>&1; then
  echo "  smoke test ((+ 4 5) -> expect 9):"
  ( cd racket/src/build/cs/c/wasm && echo ' (+ 4 5)' | node scheme.js ) || echo "  (smoke test failed)"
fi
