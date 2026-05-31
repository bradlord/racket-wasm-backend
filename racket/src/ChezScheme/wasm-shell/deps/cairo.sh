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
DEP_SYMBOLS_MODE=explicit
# Starter set of Cairo entry points -- enough to create an image
# surface, draw geometry, render text, and pull pixel data out for
# blitting to a <canvas>. Easy to grow as racket/draw's surface
# widens; each name just adds another Sforeign_symbol registration
# and a -Wl,-u flag.
DEP_SYMBOLS=(
  # Surface lifecycle + pixel access
  cairo_image_surface_create
  cairo_image_surface_create_for_data
  cairo_image_surface_get_data
  cairo_image_surface_get_stride
  cairo_image_surface_get_width
  cairo_image_surface_get_height
  cairo_format_stride_for_width
  cairo_surface_destroy
  cairo_surface_flush
  cairo_surface_status

  # Context lifecycle
  cairo_create
  cairo_destroy
  cairo_status

  # Source + paint
  cairo_set_source_rgb
  cairo_set_source_rgba
  cairo_paint

  # Geometry
  cairo_move_to
  cairo_line_to
  cairo_rectangle
  cairo_arc
  cairo_close_path
  cairo_new_path
  cairo_translate
  cairo_scale
  cairo_rotate

  # Stroke + fill
  cairo_set_line_width
  cairo_fill
  cairo_fill_preserve
  cairo_stroke
  cairo_stroke_preserve

  # Text
  cairo_select_font_face
  cairo_set_font_size
  cairo_show_text
)
