# Cairo recipe.
#
# Cairo 1.18.x is meson-only. Picks up pixman, FreeType, libpng, and
# zlib through the accumulated PKG_CONFIG_PATH; everything else is
# explicitly disabled because (a) the platform backends (xlib, xcb,
# quartz, dwrite) make no sense for wasm32, (b) FontConfig and GLib
# come later in Phase D, and (c) auto-features can otherwise resolve
# to host libraries even with PKG_CONFIG_LIBDIR scoping (Cairo's
# meson.build probes some via cc.find_library).
#
# CAIRO_FORMAT_ARGB32 stores native-endian int32 in memory, i.e. on
# little-endian (which wasm32 is) the bytes are B G R A. Callers that
# hand the buffer to wasm_canvas_blit (which expects R G B A for the
# page's putImageData) need a channel swap. Cairo's image surface is
# what `cairo_image_surface_get_data()` returns.

DEP_NAME=cairo
DEP_VERSION=1.18.4
DEP_SOURCE_URL=https://www.cairographics.org/releases/cairo-1.18.4.tar.xz
DEP_SOURCE_SHA256=445ed8208a6e4823de1226a74ca319d3600e83f6369f99b14265006599c32ccb
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  # Font backends
  -Dfreetype=enabled
  -Dfontconfig=disabled
  -Ddwrite=disabled
  # Surface backends
  -Dpng=enabled
  -Dquartz=disabled
  -Dxcb=disabled
  -Dxlib=disabled
  -Dxlib-xcb=disabled
  -Dtee=enabled
  -Dzlib=enabled
  # Misc deps + dev tooling
  -Dglib=disabled
  -Dspectre=disabled
  -Dsymbol-lookup=disabled
  -Dlzo=disabled
  -Dgtk2-utils=disabled
  -Dtests=disabled
  -Dgtk_doc=false
)
DEP_INSTALL_LIB=libcairo.a
DEP_LINK_FLAGS=(-lcairo)
# Scrape every public `cairo_*` entry point from libcairo.a. racket/draw
# pulls ~hundreds of these (it ffi-libs many platform-specific surfaces
# whose ffi-defines fire regardless of (system-type)); hand-listing
# them is brittle. llvm-nm comes from emsdk's PATH (sourced before
# build.sh runs); the `[TBR]` filter keeps text/bss/rodata external
# definitions (i.e., the public API and constant tables Racket may
# reach by name).
DEP_SYMBOLS_MODE=scrape
# Cairo's internal helpers are named `_cairo_*` (a Cairo convention,
# not a macOS BSD nm prefix). Filter for public API (`^cairo_`,
# strictly no leading underscore) and skip internals.
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libcairo.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^cairo_/ {print \$3}" \
  | sort -u'
