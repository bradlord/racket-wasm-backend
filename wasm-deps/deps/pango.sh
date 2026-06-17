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

wasm_dep_patch() {
  # Fix function-pointer-cast signature mismatches that WASM's typed
  # call_indirect rejects. Pango casts 1-arg functions to 2-arg GFunc /
  # GCopyFunc types in several places on the racket/draw text path; add
  # thin wrappers with the correct 2-arg signatures instead.
  # See build-wasm.md "Text / Pango" for context.
  #
  # Each fix: (a) insert a static wrapper function near the call site,
  # (b) replace the (GFoo)real_fn cast with the wrapper name.
  # Idempotency guard: the wrapper names are unique; grep checks before
  # applying.  Uses Python because sed multi-line insertion is not
  # portable across GNU/BSD sed.

  # pango-attributes.c: pango_attribute_copy (i32->i32) cast to GCopyFunc (i32,i32->i32)
  if ! grep -q "pango_attribute_copy_gcopy" pango/pango-attributes.c; then
    python3 - <<'PYEOF' pango/pango-attributes.c
import sys
path = sys.argv[1]
src = open(path).read()
wrapper = (
    "static gpointer\n"
    "pango_attribute_copy_gcopy (gconstpointer src, gpointer data)\n"
    "{\n"
    "  return pango_attribute_copy ((const PangoAttribute *) src);\n"
    "}\n"
    "\n"
)
src = src.replace(
    "/**\n * pango_attr_list_copy:",
    wrapper + "/**\n * pango_attr_list_copy:")
src = src.replace(
    "(GCopyFunc)pango_attribute_copy",
    "pango_attribute_copy_gcopy")
open(path, "w").write(src)
PYEOF
  fi

  # pangocairo-font.c: free_metrics_info (i32->void) cast to GFunc (i32,i32->void)
  if ! grep -q "free_metrics_info_gfunc" pango/pangocairo-font.c; then
    python3 - <<'PYEOF' pango/pangocairo-font.c
import sys
path = sys.argv[1]
src = open(path).read()
wrapper = (
    "static void\n"
    "free_metrics_info_gfunc (gpointer info, gpointer data)\n"
    "{\n"
    "  free_metrics_info (info);\n"
    "}\n"
    "\n"
)
src = src.replace(
    "void\n_pango_cairo_font_private_finalize",
    wrapper + "void\n_pango_cairo_font_private_finalize")
src = src.replace(
    "(GFunc)free_metrics_info",
    "free_metrics_info_gfunc")
open(path, "w").write(src)
PYEOF
  fi

  # pangofc-font.c: free_metrics_info (i32->void) cast to GFunc (i32,i32->void)
  if ! grep -q "free_metrics_info_gfunc" pango/pangofc-font.c; then
    python3 - <<'PYEOF' pango/pangofc-font.c
import sys
path = sys.argv[1]
src = open(path).read()
wrapper = (
    "static void\n"
    "free_metrics_info_gfunc (gpointer info, gpointer data)\n"
    "{\n"
    "  free_metrics_info (info);\n"
    "}\n"
    "\n"
)
src = src.replace(
    "static void\npango_fc_font_finalize",
    wrapper + "static void\npango_fc_font_finalize")
src = src.replace(
    "(GFunc)free_metrics_info",
    "free_metrics_info_gfunc")
open(path, "w").write(src)
PYEOF
  fi

  # pango-context.c: pango_item_free (i32->void) cast to GFunc (i32,i32->void)
  if ! grep -q "pango_item_free_gfunc" pango/pango-context.c; then
    python3 - <<'PYEOF' pango/pango-context.c
import sys
path = sys.argv[1]
src = open(path).read()
wrapper = (
    "static void\n"
    "pango_item_free_gfunc (gpointer item, gpointer data)\n"
    "{\n"
    "  pango_item_free (item);\n"
    "}\n"
    "\n"
)
src = src.replace(
    "PangoFontMetrics *\npango_context_get_metrics",
    wrapper + "PangoFontMetrics *\npango_context_get_metrics")
src = src.replace(
    "(GFunc)pango_item_free",
    "pango_item_free_gfunc")
open(path, "w").write(src)
PYEOF
  fi

  # pango-item.c: pango_attribute_destroy (i32->void) cast to GFunc (i32,i32->void)
  if ! grep -q "pango_attribute_destroy_gfunc" pango/pango-item.c; then
    python3 - <<'PYEOF' pango/pango-item.c
import sys
path = sys.argv[1]
src = open(path).read()
wrapper = (
    "static void\n"
    "pango_attribute_destroy_gfunc (gpointer attr, gpointer data)\n"
    "{\n"
    "  pango_attribute_destroy (attr);\n"
    "}\n"
    "\n"
)
src = src.replace(
    "/**\n * pango_item_free:",
    wrapper + "/**\n * pango_item_free:")
src = src.replace(
    "(GFunc)pango_attribute_destroy",
    "pango_attribute_destroy_gfunc")
open(path, "w").write(src)
PYEOF
  fi

  # pango-markup.c: pango_attribute_destroy (i32->void) cast to GFunc (i32,i32->void)
  if ! grep -q "pango_attribute_destroy_gfunc" pango/pango-markup.c; then
    python3 - <<'PYEOF' pango/pango-markup.c
import sys
path = sys.argv[1]
src = open(path).read()
wrapper = (
    "static void\n"
    "pango_attribute_destroy_gfunc (gpointer attr, gpointer data)\n"
    "{\n"
    "  pango_attribute_destroy (attr);\n"
    "}\n"
    "\n"
)
src = src.replace(
    "static void\nopen_tag_free",
    wrapper + "static void\nopen_tag_free")
src = src.replace(
    "(GFunc) pango_attribute_destroy",
    "pango_attribute_destroy_gfunc")
open(path, "w").write(src)
PYEOF
  fi
}

DEP_SYMBOLS_MODE=scrape
DEP_SYMBOLS_SCRAPE='for f in lib/libpango-1.0.a lib/libpangocairo-1.0.a lib/libpangoft2-1.0.a; do
    if [ -f "$f" ]; then llvm-nm --defined-only --extern-only "$f" 2>/dev/null || true; fi
  done | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^pango_/ {print \$3}" \
  | sort -u'
