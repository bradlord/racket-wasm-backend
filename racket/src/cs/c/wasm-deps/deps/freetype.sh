# FreeType recipe.
#
# Cairo's font path needs FreeType; FreeType in turn picks up zlib
# (Emscripten bundles) and libpng (deps/libpng.sh) automatically via
# the accumulated PKG_CONFIG_PATH.
#
# HarfBuzz is deliberately disabled here: FreeType and HarfBuzz have
# a circular optional dep (HarfBuzz->FreeType for glyph outlines;
# FreeType->HarfBuzz for OpenType auto-hinting), so the canonical
# build order is FreeType (without HarfBuzz) -> HarfBuzz -> FreeType
# (with HarfBuzz). Cairo only needs the first pass; Pango will need
# the second, which we'll handle in Phase D.

DEP_NAME=freetype
DEP_VERSION=2.13.3
DEP_SOURCE_URL=https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz
DEP_SOURCE_SHA256=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  -Dzlib=external
  -Dpng=enabled
  -Dharfbuzz=disabled
  -Dbzip2=disabled
  -Dbrotli=disabled
  -Dtests=disabled
)
# autotools rejected: the make rules build `apinames` (a symbol-list
# generator) with the target compiler, so under emcc it becomes a
# wasm module that can't run on the host to emit ftexport.sym. Meson
# uses native_dep_tools / build_machine for such helpers and handles
# the cross-build cleanly.
DEP_INSTALL_LIB=libfreetype.a
DEP_LINK_FLAGS=(-lfreetype)
DEP_SYMBOLS_MODE=scrape
# FreeType's public API uses two prefixes: FT_ for the main API and
# TT_ for the TrueType-specific subset. Pulled together so racket/draw
# can reach either.
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libfreetype.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && (\$3 ~ /^FT_/ || \$3 ~ /^TT_/) {print \$3}" \
  | sort -u'
