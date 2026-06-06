# HarfBuzz recipe.
#
# Text shaping. Needs FreeType (glyph outlines) and (optionally) GLib;
# we pick up both through the accumulated PKG_CONFIG_PATH. cairo,
# icu, graphite2, and the various host backends are disabled.

DEP_NAME=harfbuzz
DEP_VERSION=8.5.0
DEP_SOURCE_URL=https://github.com/harfbuzz/harfbuzz/releases/download/8.5.0/harfbuzz-8.5.0.tar.xz
DEP_SOURCE_SHA256=77e4f7f98f3d86bf8788b53e6832fb96279956e1c3961988ea3d4b7ca41ddc27
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  -Dfreetype=enabled
  -Dglib=enabled
  -Dgobject=disabled
  -Dcairo=disabled
  -Dchafa=disabled
  -Dicu=disabled
  -Dgraphite=disabled
  -Dgraphite2=disabled
  -Dcoretext=disabled
  -Ddirectwrite=disabled
  -Dgdi=disabled
  -Dtests=disabled
  -Dintrospection=disabled
  -Ddocs=disabled
  -Dutilities=disabled
  -Dbenchmark=disabled
)
DEP_INSTALL_LIB=libharfbuzz.a
DEP_LINK_FLAGS=(-lharfbuzz)
DEP_SYMBOLS_MODE=scrape
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libharfbuzz.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^hb_/ {print \$3}" \
  | sort -u'
