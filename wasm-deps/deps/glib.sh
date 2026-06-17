# GLib recipe.
#
# Picks up libffi, zlib, and pcre2 through the accumulated
# PKG_CONFIG_PATH. iconv is provided by the Emscripten sysroot (we set
# tests=false and exclude gobject-introspection, GIO-related testing,
# nls, etc. -- they're not used by racket/draw's pango/cairo path).
#
# GLib's executables (gspawn helper, etc.) are disabled because they
# need fork/exec which isn't available on wasm32-emscripten.

DEP_NAME=glib
DEP_VERSION=2.82.4
DEP_SOURCE_URL=https://download.gnome.org/sources/glib/2.82/glib-2.82.4.tar.xz
DEP_SOURCE_SHA256=37dd0877fe964cd15e9a2710b044a1830fb1bd93652a6d0cb6b8b2dff187c709
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  -Dtests=false
  -Dinstalled_tests=false
  -Dnls=disabled
  -Dman=false
  -Dgtk_doc=false
  -Dlibmount=disabled
  -Dselinux=disabled
  -Dsystemtap=false
  -Ddtrace=false
  -Dxattr=false
)
DEP_INSTALL_LIB=libglib-2.0.a
DEP_LINK_FLAGS=(-lgio-2.0 -lgmodule-2.0 -lgobject-2.0 -lglib-2.0)

# GIO's meson.build errors out if it can't find res_query() during
# configure -- wasm32-emscripten doesn't ship a DNS resolver. We
# patch the check to a no-op so the build proceeds; runtime DNS calls
# will fail if anything actually tries them (racket/draw's pango path
# does not).
wasm_dep_patch() {
  # Fix GObject function-pointer-cast signature mismatches that wasm's
  # typed call_indirect rejects (text/Pango traps otherwise). Backported
  # from the Fluendo glib WASM fork; see deps/glib-fpcast.patch and
  # build-wasm.md "Text / Pango". Idempotent: the marker (the new
  # class_data arg on g_object_do_class_init) is only present once
  # applied. `$here` is the wasm-deps dir (set by build-deps.sh before
  # this recipe is sourced); wasm_dep_patch runs with cwd = dep source.
  if ! grep -q "g_object_do_class_init (GObjectClass \*class," gobject/gobject.c; then
    patch -p1 < "$here/deps/glib-fpcast.patch"
  fi

  # The fork's patch fixes class_init/default_init via the G_DEFINE_*
  # macros, but G_IMPLEMENT_INTERFACE can't adapt a consumer's 1-arg
  # iface_init -- so type_iface_vtable_iface_init_Wm() still calls it as
  # a 2-arg GInterfaceInitFunc and wasm's typed call_indirect traps (the
  # racket/draw -> Pango font path, PangoCairoFontMap interface). Every
  # iface_init on this stack is genuinely 1-arg (interface_data unused),
  # so call it through its real signature. Glib-only -- fixes all
  # consumers without patching them. See build-wasm.md.
  if ! grep -q "wasm: 1-arg iface_init ABI" gobject/gtype.c; then
    sed -i.bakif \
      's|iholder->info->interface_init (vtable, iholder->info->interface_data);|((void (*) (gpointer)) iholder->info->interface_init) (vtable); /* wasm: 1-arg iface_init ABI */|' \
      gobject/gtype.c
  fi

  # GIO needs res_query() (DNS resolver) which wasm32-emscripten
  # doesn't provide -- relax the configure-time error so the library
  # builds. The actual link references are skipped below.
  if grep -q "Could not find res_query" gio/meson.build; then
    sed -i.bak \
      "s|error('Could not find res_query()')|warning('res_query() not available -- wasm32 stub')|" \
      gio/meson.build
  fi
  # gcompletion.c assigns strncmp directly to a GCompletionStrncmpFunc
  # field; the field expects unsigned int but strncmp uses size_t,
  # which is unsigned long under emcc's libc. clang 18+ promotes this
  # to an error. Cast through the field type.
  if [ -f glib/deprecated/gcompletion.c ] && \
     grep -q "gcomp->strncmp_func = strncmp;" glib/deprecated/gcompletion.c; then
    sed -i.bak \
      "s|gcomp->strncmp_func = strncmp;|gcomp->strncmp_func = (GCompletionStrncmpFunc)strncmp;|" \
      glib/deprecated/gcompletion.c
  fi
  # emcc declares kqueue/kevent in libc but doesn't ship sys/event.h,
  # so cc.has_function passes but the actual compile fails. Force
  # HAVE_KQUEUE / HAVE_KEVENT off everywhere so the kqueue branches
  # are skipped at preprocess time.
  if [ -f meson.build ]; then
    # Remove kqueue / kevent from the function-detection list, and
    # set the have_func_* vars to false up front so later references
    # don't fail with "Unknown variable".
    sed -i.bak2 -E "/^[[:space:]]*'(kqueue|kevent)',[[:space:]]*$/d" meson.build
    # Add the false assignments right after the function-list loop.
    if ! grep -q "have_func_kqueue = false" meson.build; then
      awk '/^foreach f : functions$/{found=1} found && /^endforeach$/{print; print "have_func_kqueue = false"; print "have_func_kevent = false"; found=0; next} {print}' meson.build > meson.build.new && \
        mv meson.build.new meson.build
    fi
  fi

  # g_list_free_full, g_slist_free_full, g_queue_free_full/clear_full,
  # g_async_queue_unref all cast GDestroyNotify (1-arg) to GFunc (2-arg)
  # for their internal foreach calls.  The GFunc trampoline is never
  # actually needed -- just iterate directly and call the 1-arg
  # GDestroyNotify without the cast.  These fire as soon as any non-empty
  # list/queue is freed (e.g. pango_layout_check_lines frees baseline_shifts
  # via g_list_free_full on every layout check).  See build-wasm.md "Text / Pango".

  if ! grep -q "wasm: g_list_free_full direct" glib/glist.c; then
    python3 - <<'PYEOF' glib/glist.c
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    "  g_list_foreach (list, (GFunc) free_func, NULL);\n  g_list_free (list);",
    "  GList *l; /* wasm: g_list_free_full direct -- avoids GFunc arity trap */\n"
    "  for (l = list; l; l = l->next)\n"
    "    free_func (l->data);\n"
    "  g_list_free (list);")
open(path, "w").write(src)
PYEOF
  fi

  if ! grep -q "wasm: g_slist_free_full direct" glib/gslist.c; then
    python3 - <<'PYEOF' glib/gslist.c
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    "  g_slist_foreach (list, (GFunc) free_func, NULL);\n  g_slist_free (list);",
    "  GSList *l; /* wasm: g_slist_free_full direct -- avoids GFunc arity trap */\n"
    "  for (l = list; l; l = l->next)\n"
    "    free_func (l->data);\n"
    "  g_slist_free (list);")
open(path, "w").write(src)
PYEOF
  fi

  if ! grep -q "wasm: g_queue_free_full direct" glib/gqueue.c; then
    python3 - <<'PYEOF' glib/gqueue.c
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    "  g_queue_foreach (queue, (GFunc) free_func, NULL);\n  g_queue_free (queue);",
    "  GList *l; /* wasm: g_queue_free_full direct -- avoids GFunc arity trap */\n"
    "  for (l = queue->head; l; l = l->next)\n"
    "    free_func (l->data);\n"
    "  g_queue_free (queue);")
src = src.replace(
    "  if (free_func != NULL)\n    g_queue_foreach (queue, (GFunc) free_func, NULL);\n\n  g_queue_clear (queue);",
    "  if (free_func != NULL) { /* wasm: g_queue_clear_full direct -- avoids GFunc arity trap */\n"
    "    GList *l;\n"
    "    for (l = queue->head; l; l = l->next)\n"
    "      free_func (l->data);\n"
    "  }\n\n  g_queue_clear (queue);")
open(path, "w").write(src)
PYEOF
  fi

  if ! grep -q "wasm: async_queue item_free direct" glib/gasyncqueue.c; then
    python3 - <<'PYEOF' glib/gasyncqueue.c
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace(
    "      if (queue->item_free_func)\n"
    "        g_queue_foreach (&queue->queue, (GFunc) queue->item_free_func, NULL);",
    "      if (queue->item_free_func) { /* wasm: async_queue item_free direct -- avoids GFunc arity trap */\n"
    "        GList *l;\n"
    "        for (l = queue->queue.head; l; l = l->next)\n"
    "          queue->item_free_func (l->data);\n"
    "      }")
open(path, "w").write(src)
PYEOF
  fi
}
DEP_SYMBOLS_MODE=scrape
# GLib's public symbols use g_, G_, _g_ prefixes; we want the public
# g_* set (and a few G_-prefixed constants that show up as TBR). Skip
# the _g_ internals.
DEP_SYMBOLS_SCRAPE='for f in lib/libglib-2.0.a lib/libgobject-2.0.a lib/libgmodule-2.0.a lib/libgio-2.0.a; do
    [ -f "$f" ] && llvm-nm --defined-only --extern-only "$f" 2>/dev/null
  done | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^g_/ {print \$3}" \
  | sort -u'
