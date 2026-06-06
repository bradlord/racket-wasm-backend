# Pango recipe.
#
# Text layout, sitting on top of Cairo + FreeType + HarfBuzz + GLib +
# FontConfig. racket/draw reaches Pango through Cairo (`pangocairo`).

DEP_NAME=pango
DEP_VERSION=1.54.0
DEP_SOURCE_URL=https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz
DEP_SOURCE_SHA256=8a9eed75021ee734d7fc0fdf3a65c3bba51dfefe4ae51a9b414a60c70b2d1ed8
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  -Dcairo=enabled
  -Dfreetype=enabled
  -Dfontconfig=enabled
  -Dxft=disabled
  -Dintrospection=disabled
  -Dlibthai=disabled
  -Dbuild-testsuite=false
  -Dbuild-examples=false
  -Ddocumentation=false
  -Dgtk_doc=false
)
DEP_INSTALL_LIB=libpango-1.0.a
DEP_LINK_FLAGS=(-lpangocairo-1.0 -lpangoft2-1.0 -lpango-1.0 -lfribidi)
DEP_SYMBOLS_MODE=scrape
DEP_SYMBOLS_SCRAPE='for f in lib/libpango-1.0.a lib/libpangocairo-1.0.a lib/libpangoft2-1.0.a; do
    if [ -f "$f" ]; then llvm-nm --defined-only --extern-only "$f" 2>/dev/null || true; fi
  done | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^pango_/ {print \$3}" \
  | sort -u'
