#!/usr/bin/env bash
#
# build-wasm.md §1: cross-compile rktio for WebAssembly.
#
# Produces racket/src/rktio/build-em/librktio.a (~388 KB), the
# statically linked rktio the WASM kernel links against.
#
# This stage uses rktio's *own* autoconf configure -- NOT the
# top-level racket/src/configure (which recurses into cs/c/configure
# and fails with "Platform is not supported natively by Racket CS")
# and NOT cs/c/configure (which demands a WASM libffi). rktio links
# no libffi; if you see a libffi or machine-type error here you are
# running the wrong configure. The `cd build-em` below is what makes
# `../configure` resolve to rktio/configure.
#
# Run from anywhere; paths resolve from this script's location.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/../racket/src/ChezScheme" && pwd)"  # repo/racket/src/ChezScheme
src="$(cd "$here/../racket/src" && pwd)"              # repo/racket/src
rktio="$src/rktio"

if [ -z "${EMSDK:-}" ] && [ -f "$HOME/emsdk/emsdk_env.sh" ]; then
  # shellcheck disable=SC1091
  EMSDK_QUIET=1 source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1
fi
command -v emconfigure >/dev/null || {
  echo "emconfigure not on PATH; source emsdk_env.sh first" >&2; exit 1; }

build="$rktio/build-em"
mkdir -p "$build"
cd "$build"

echo "[cfg] rktio (../configure = $rktio/configure)"
emconfigure ../configure --host=wasm32-unknown-emscripten --disable-pthread

echo "[mk]  librktio.a"
emmake make librktio.a

# configure leaves an unsubstituted standalone-build token in the
# archive name; rename it to the plain librktio.a the link step wants.
if [ -e '@HIDE_NOT_STANDALONE@librktio.a' ]; then
  mv '@HIDE_NOT_STANDALONE@librktio.a' librktio.a
fi

[ -e librktio.a ] || { echo "librktio.a was not produced" >&2; exit 1; }
echo "Done. $build/librktio.a ($(wc -c < librktio.a | tr -d ' ') bytes)"
