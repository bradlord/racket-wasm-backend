# deps.sh -- shared recipe support for the WASM build.
#
# A recipe file under deps/<name>.sh is a plain shell script that the
# driver sources after wasm_dep_reset. Each recipe sets:
#
#   DEP_NAME            short tag, e.g. libffi
#   DEP_VERSION         human-readable version (for logging/state)
#   DEP_SOURCE_URL      https://... tarball; downloaded once per sha256
#   DEP_SOURCE_SHA256   pinned sha256 of the tarball
#   DEP_BUILD_SYSTEM    "autotools" (default) | "meson"
#   DEP_BUILD_ARGS      bash array; passed to ../configure (autotools)
#                       or to `meson setup` (meson). Conventions differ
#                       (`--foo=bar` vs `-Dfoo=bar`); the recipe writes
#                       the form its build system expects.
#   DEP_INSTALL_LIB     archive filename in install/lib (e.g. libffi.a)
#   DEP_LINK_FLAGS      bash array; spliced into the final emcc link
#                       (e.g. -lffi)
#   DEP_SYMBOLS_MODE    none | explicit | scrape (default: none)
#   DEP_SYMBOLS         bash array of C symbols (explicit mode)
#   DEP_SYMBOLS_SCRAPE  shell snippet evaluated from DEP_PREFIX; emits
#                       one symbol name per line on stdout (scrape mode)
#
# The driver then calls (in order):
#   wasm_dep_reset
#   source deps/<name>.sh
#   wasm_dep_paths
#   wasm_dep_fetch
#   wasm_dep_build
#   wasm_dep_symbols    # appended to the manifest
#
# Paths the driver sets before sourcing:
#   WASM_SRC_DIR        absolute path to racket/src
#   WASM_SHELL_DIR      absolute path to wasm-shell/ (cross file lives here)
#   WASM_CACHE_DIR      tarball cache (default $WASM_SRC_DIR/.wasm-cache)
#
# wasm_dep_build also accumulates PKG_CONFIG_PATH after each successful
# install, so later deps' configure/meson can see earlier deps' .pc
# files (Cairo needs to find pixman, etc.).
#
# Not handled here:
#   - rktio (in-tree, has its own quirks; built directly by build-wasm.md §1)
#   - libffi 3.4.x compat: we pin a known-good 3.5.x recipe.
#   - cmake-based deps (libjpeg-turbo 2.x+): not needed yet.

# ----------------------------------------------------------------------

wasm_dep_reset() {
  unset DEP_NAME DEP_VERSION DEP_SOURCE_URL DEP_SOURCE_SHA256
  unset DEP_INSTALL_LIB DEP_SYMBOLS_MODE DEP_SYMBOLS_SCRAPE
  DEP_BUILD_SYSTEM=autotools
  DEP_BUILD_ARGS=()
  DEP_LINK_FLAGS=()
  DEP_SYMBOLS=()
  DEP_SYMBOLS_MODE=none
}

# Derive the paths every other function uses, after the recipe is sourced.
wasm_dep_paths() {
  : "${WASM_SRC_DIR:?WASM_SRC_DIR must be set by the driver}"
  : "${DEP_NAME:?recipe missing DEP_NAME}"
  WASM_CACHE_DIR="${WASM_CACHE_DIR:-$WASM_SRC_DIR/.wasm-cache}"
  DEP_ROOT="$WASM_SRC_DIR/build-${DEP_NAME}-em"
  DEP_SRC="$DEP_ROOT/src"
  DEP_BUILD="$DEP_SRC/build"
  DEP_PREFIX="$DEP_ROOT/install"
  DEP_STATE="$DEP_PREFIX/.wasm-dep-state"
  if [ -n "${DEP_SOURCE_URL:-}" ]; then
    : "${DEP_SOURCE_SHA256:?recipe missing DEP_SOURCE_SHA256}"
    DEP_CACHE="$WASM_CACHE_DIR/${DEP_NAME}-${DEP_SOURCE_SHA256:0:12}.tar.gz"
  fi
}

# Hash everything that should invalidate the build.
wasm_dep_manifest_hash() {
  { printf '%s\n' "$DEP_VERSION" "$DEP_SOURCE_SHA256" "$DEP_INSTALL_LIB"
    printf '%s\n' "$DEP_BUILD_SYSTEM"
    printf '%s\n' "${DEP_BUILD_ARGS[@]+"${DEP_BUILD_ARGS[@]}"}"
  } | shasum -a 256 | awk '{print $1}'
}

_wasm_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

wasm_dep_fetch() {
  # Source-less recipes (e.g. for libraries Emscripten already bundles
  # via -s USE_FOO=1) contribute symbols + link flags only.
  [ -z "${DEP_SOURCE_URL:-}" ] && return 0
  mkdir -p "$WASM_CACHE_DIR"
  if [ ! -f "$DEP_CACHE" ]; then
    echo "[$DEP_NAME] fetch $DEP_SOURCE_URL"
    curl -fsSL "$DEP_SOURCE_URL" -o "$DEP_CACHE.partial"
    local actual
    actual=$(_wasm_sha256 "$DEP_CACHE.partial")
    if [ "$actual" != "$DEP_SOURCE_SHA256" ]; then
      rm -f "$DEP_CACHE.partial"
      echo "[$DEP_NAME] sha256 mismatch: got $actual, want $DEP_SOURCE_SHA256" >&2
      return 1
    fi
    mv "$DEP_CACHE.partial" "$DEP_CACHE"
  fi
  if [ ! -d "$DEP_SRC" ]; then
    echo "[$DEP_NAME] extract"
    rm -rf "$DEP_SRC.partial"
    mkdir -p "$DEP_SRC.partial"
    tar -xzf "$DEP_CACHE" -C "$DEP_SRC.partial" --strip-components=1
    mv "$DEP_SRC.partial" "$DEP_SRC"
  fi
}

wasm_dep_build() {
  [ -z "${DEP_SOURCE_URL:-}" ] && { _wasm_dep_register_pkgconfig; return 0; }
  local manifest
  manifest=$(wasm_dep_manifest_hash)
  if [ -f "$DEP_STATE" ] && [ -f "$DEP_PREFIX/lib/$DEP_INSTALL_LIB" ] \
     && [ "$(cat "$DEP_STATE")" = "$manifest" ]; then
    echo "[$DEP_NAME] up to date"
    _wasm_dep_register_pkgconfig
    return 0
  fi
  rm -rf "$DEP_BUILD" "$DEP_PREFIX"
  case "${DEP_BUILD_SYSTEM:-autotools}" in
    autotools) _wasm_dep_build_autotools ;;
    meson)     _wasm_dep_build_meson ;;
    *) echo "[$DEP_NAME] unknown DEP_BUILD_SYSTEM: $DEP_BUILD_SYSTEM" >&2
       return 1 ;;
  esac
  printf '%s' "$manifest" > "$DEP_STATE"
  _wasm_dep_register_pkgconfig
}

_wasm_jobs() {
  (command -v nproc >/dev/null && nproc) \
    || (command -v sysctl >/dev/null && sysctl -n hw.ncpu) \
    || echo 4
}

_wasm_dep_build_autotools() {
  echo "[$DEP_NAME] configure (autotools)"
  mkdir -p "$DEP_BUILD"
  ( cd "$DEP_BUILD" && emconfigure ../configure \
      --host=wasm32-unknown-emscripten \
      --prefix="$DEP_PREFIX" \
      "${DEP_BUILD_ARGS[@]+"${DEP_BUILD_ARGS[@]}"}" )
  echo "[$DEP_NAME] build"
  ( cd "$DEP_BUILD" && emmake make -j"$(_wasm_jobs)" && make install )
}

_wasm_dep_build_meson() {
  : "${WASM_SHELL_DIR:?WASM_SHELL_DIR must be set by the driver}"
  local cross="$WASM_SHELL_DIR/wasm-emscripten.cross"
  [ -f "$cross" ] || { echo "[$DEP_NAME] missing cross file: $cross" >&2; return 1; }
  echo "[$DEP_NAME] configure (meson)"
  meson setup "$DEP_BUILD" "$DEP_SRC" \
    --cross-file "$cross" \
    --prefix "$DEP_PREFIX" \
    --default-library=static \
    --buildtype=release \
    -Dpkgconfig.relocatable=true \
    "${DEP_BUILD_ARGS[@]+"${DEP_BUILD_ARGS[@]}"}"
  echo "[$DEP_NAME] build"
  meson compile -C "$DEP_BUILD" -j "$(_wasm_jobs)"
  meson install -C "$DEP_BUILD"
}

# Make this dep's pkg-config files visible to later deps' configure /
# meson setup. Cairo finds pixman this way, etc.
_wasm_dep_register_pkgconfig() {
  local pcdir="$DEP_PREFIX/lib/pkgconfig"
  if [ -d "$pcdir" ]; then
    case ":${PKG_CONFIG_PATH:-}:" in
      *":$pcdir:"*) ;;
      *) export PKG_CONFIG_PATH="$pcdir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" ;;
    esac
  fi
}

# Emit one C symbol per line on stdout. Recipes pick their mode.
wasm_dep_symbols() {
  case "${DEP_SYMBOLS_MODE:-none}" in
    none)     ;;
    explicit) printf '%s\n' "${DEP_SYMBOLS[@]+"${DEP_SYMBOLS[@]}"}" ;;
    scrape)   ( cd "$DEP_PREFIX" && eval "$DEP_SYMBOLS_SCRAPE" ) ;;
    *)        echo "[$DEP_NAME] unknown DEP_SYMBOLS_MODE: $DEP_SYMBOLS_MODE" >&2
              return 1 ;;
  esac
}
