#!/usr/bin/env bash
#
# build-deps.sh -- build the recipe-driven WASM library dependencies
# (libffi, libpng, cairo, pango, ...) and emit the artifacts the final
# link in build.sh consumes:
#
#   <boot>/wasm_deps.inc            -- foreign-symbol registrations,
#                                      included by wasm_extras.inc
#   <boot>/wasm_deps_uflags.txt     -- -Wl,-u,<sym> force-link flags
#   <boot>/.wasm-deps-linkflags.txt -- the -L/-l flags, in final link
#                                      order, one per line, read back by
#                                      build.sh
#
# Each dep flows through deps/<name>.sh -- see deps.sh. rktio stays
# special-cased: it lives in-tree, and build-wasm.md §1 builds it with
# configure quirks the recipe schema would have to encode by hand (e.g.
# the @HIDE_NOT_STANDALONE@ archive rename).
#
# build-all.sh runs this before build.sh; build.sh just consumes the
# artifacts above. Run from anywhere; paths resolve from this script's
# location.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chez="$(cd "$here/../racket/src/ChezScheme" && pwd)"  # repo/racket/src/ChezScheme
src="$(cd "$here/../racket/src" && pwd)"              # repo/racket/src

cd "$chez"

if [ -z "${EMSDK:-}" ] && [ -f "$HOME/emsdk/emsdk_env.sh" ]; then
  # shellcheck disable=SC1091
  EMSDK_QUIET=1 source "$HOME/emsdk/emsdk_env.sh" >/dev/null 2>&1
fi
command -v emcc >/dev/null || { echo "emcc not on PATH; source emsdk_env.sh first" >&2; exit 1; }

# emsdk_env.sh adds upstream/emscripten to PATH but not upstream/bin.
# Recipes that scrape symbols (e.g. cairo.sh) want llvm-nm; expose it.
emcc_path=$(command -v emcc)
emsdk_upstream_bin="$(cd "$(dirname "$emcc_path")"/../bin 2>/dev/null && pwd)"
[ -n "$emsdk_upstream_bin" ] && case ":$PATH:" in
  *":$emsdk_upstream_bin:"*) ;;
  *) export PATH="$emsdk_upstream_bin:$PATH" ;;
esac

boot=em-tpb32l/boot/tpb32l

# shellcheck disable=SC1091
source "$here/deps.sh"

export WASM_SRC_DIR="$src"
export WASM_SHELL_DIR="$here"

# Order is build-leaf → root: each dep can only reference earlier
# entries via pkg-config. Note that fontconfig needs to come before
# cairo (cairo's meson links against fontconfig when present) and
# harfbuzz before pango.
DEPS=(libffi libpng pixman freetype pcre2 expat glib libjpeg-turbo fontconfig cairo harfbuzz pango)
# -L flags collected in any order (they apply globally), -l flags in
# reverse DEPS order: leaves of the dep tree (libffi, libpng, ...) are
# built first but must appear LAST on the wasm-ld line so that more-
# rooted libs (cairo) can pull in their referents.
DEPS_LIBDIRS=()
DEPS_LIBS=()
symbols_manifest="$boot/.wasm-deps-symbols.txt"
mkdir -p "$boot"
: > "$symbols_manifest"

for dep_file in "${DEPS[@]}"; do
  wasm_dep_reset
  # shellcheck disable=SC1090
  source "$here/deps/$dep_file.sh"
  wasm_dep_paths
  wasm_dep_fetch
  wasm_dep_build
  wasm_dep_symbols >> "$symbols_manifest"
  [ -d "$DEP_PREFIX/lib" ] && DEPS_LIBDIRS+=(-L "$DEP_PREFIX/lib")
  # Prepend so the iteration order produces the right link order.
  DEPS_LIBS=("${DEP_LINK_FLAGS[@]+"${DEP_LINK_FLAGS[@]}"}"
             "${DEPS_LIBS[@]+"${DEPS_LIBS[@]}"}")
done

echo "[gen] wasm_deps.inc + uflags"
"$here/symgen.sh" "$symbols_manifest" "$boot"

# Persist the link flags for build.sh, in final link order (all -L dirs
# first, then the -l flags reverse-ordered above), one per line. build.sh
# reads them back into a single array spliced into LDFLAGS_COMMON.
linkflags_file="$boot/.wasm-deps-linkflags.txt"
{
  [ "${#DEPS_LIBDIRS[@]}" -gt 0 ] && printf '%s\n' "${DEPS_LIBDIRS[@]}"
  [ "${#DEPS_LIBS[@]}" -gt 0 ] && printf '%s\n' "${DEPS_LIBS[@]}"
} > "$linkflags_file"

echo "[ok]  deps built -> $linkflags_file"
