#!/usr/bin/env bash
#
# build-deps.sh -- build the recipe-driven WASM library dependencies
# (libffi always, plus an optional user-selected set) and emit the
# artifacts the final emcc link consumes:
#
#   <out>/wasm_deps.inc            -- foreign-symbol registrations,
#                                     included by wasm_extras.inc
#   <out>/wasm_deps_uflags.txt     -- -Wl,-u,<sym> force-link flags
#   <out>/.wasm-deps-linkflags.txt -- the -L/-l flags, in final link
#                                     order, one per line
#
# Each dep flows through deps/<name>.sh -- see deps.sh. rktio stays
# special-cased: it lives in-tree and is built by the stock build's
# setup-rktio (build.zuo), not here.
#
# Driven by the stock build's `wasm-deps` zuo target (build.zuo). Usage:
#
#   build-deps.sh --src <racket/src> --out <artifact-dir> [--deps "<list>"]
#
# --deps is a space-separated list of recipe names, plus the group alias
# `draw` which expands to the full cairo/pango stack. libffi is always
# built first (the Chez kernel's ffi.c needs its headers, and the rest
# of the dep tree links against it). An empty/absent --deps builds libffi
# only.
#
# Recipes build into <src>/build-<name>-em/install (a cache outside the
# stock build dir, so `make clean` of build/ doesn't discard them).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- args ----------------------------------------------------------
src=""
out=""
deps_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src)  src="$2";  shift 2 ;;
    --out)  out="$2";  shift 2 ;;
    --deps) deps_arg="${2:-}"; shift 2 ;;
    *) echo "build-deps.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$src" ] || { echo "build-deps.sh: --src <racket/src> is required" >&2; exit 2; }
[ -n "$out" ] || { echo "build-deps.sh: --out <artifact-dir> is required" >&2; exit 2; }
src="$(cd "$src" && pwd)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# ---- emsdk on PATH -------------------------------------------------
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

# ---- dep set resolution --------------------------------------------
#
# Canonical build order, build-leaf -> root: each dep can only reference
# earlier entries via pkg-config. fontconfig must precede cairo (cairo's
# meson links against fontconfig when present) and harfbuzz must precede
# pango. libffi is the leaf everything else can rely on.
ALL_DEPS=(libffi libpng pixman freetype pcre2 expat glib libjpeg-turbo fontconfig cairo harfbuzz pango)
# The `draw` group: everything racket/draw's Cairo/Pango FFI stack needs.
DRAW_GROUP=(libpng pixman freetype pcre2 expat glib libjpeg-turbo fontconfig cairo harfbuzz pango)

# Collect the requested recipe names into a set, expanding group aliases.
# libffi is always requested.
declare -A want=( [libffi]=1 )
for tok in $deps_arg; do
  case "$tok" in
    ""|libffi) ;;
    draw) for d in "${DRAW_GROUP[@]}"; do want[$d]=1; done ;;
    *)
      # Validate against the known recipe set.
      known=0
      for d in "${ALL_DEPS[@]}"; do [ "$d" = "$tok" ] && known=1 && break; done
      if [ "$known" = 0 ]; then
        echo "build-deps.sh: unknown dep '$tok' (known: ${ALL_DEPS[*]}; group: draw)" >&2
        exit 2
      fi
      want[$tok]=1 ;;
  esac
done

# Materialize the build list in canonical order.
DEPS=()
for d in "${ALL_DEPS[@]}"; do
  [ "${want[$d]:-}" = 1 ] && DEPS+=("$d")
done

echo "[deps] building: ${DEPS[*]}"

# ---- build loop ----------------------------------------------------
# shellcheck disable=SC1091
source "$here/deps.sh"

export WASM_SRC_DIR="$src"
export WASM_SHELL_DIR="$here"   # holds wasm-emscripten.cross (meson recipes)

# -L flags collected in any order (they apply globally); -l flags in
# reverse DEPS order: leaves of the dep tree (libffi, libpng, ...) are
# built first but must appear LAST on the wasm-ld line so more-rooted
# libs (cairo) can pull in their referents.
DEPS_LIBDIRS=()
DEPS_LIBS=()
symbols_manifest="$out/.wasm-deps-symbols.txt"
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
"$here/symgen.sh" "$symbols_manifest" "$out"

# Persist the link flags for the link step, in final link order (all -L
# dirs first, then the -l flags reverse-ordered above), one per line.
linkflags_file="$out/.wasm-deps-linkflags.txt"
{
  [ "${#DEPS_LIBDIRS[@]}" -gt 0 ] && printf '%s\n' "${DEPS_LIBDIRS[@]}"
  [ "${#DEPS_LIBS[@]}" -gt 0 ] && printf '%s\n' "${DEPS_LIBS[@]}"
} > "$linkflags_file"

echo "[ok]  deps built -> $linkflags_file"
