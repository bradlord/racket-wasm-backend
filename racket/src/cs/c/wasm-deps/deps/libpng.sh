# libpng recipe.
#
# Depends on zlib, which Emscripten bundles via -s USE_ZLIB=1 (already
# in LDFLAGS_COMMON). The configure script picks up Emscripten's zlib
# headers + symbols from the sysroot, so no zlib recipe is needed.
#
# Symbols are not registered here: Cairo (Tier 2 / Phase B) will pull
# in libpng's public API by linking against -lpng16 and by registering
# the symbols racket/draw's bitmap-IO path actually calls. For now we
# just build the archive so Cairo's later configure can find it.

DEP_NAME=libpng
DEP_VERSION=1.6.46
DEP_SOURCE_URL=https://download.sourceforge.net/libpng/libpng-1.6.46.tar.gz
DEP_SOURCE_SHA256=c2b8ffb46f48331416e01f9e5c7169c7a2e08ad766b742742644e5fdf192e4a1
DEP_BUILD_ARGS=(
  --enable-static
  --disable-shared
)
DEP_INSTALL_LIB=libpng16.a
DEP_LINK_FLAGS=(-lpng16)
DEP_SYMBOLS_MODE=scrape
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libpng16.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^png_/ {print \$3}" \
  | sort -u'
