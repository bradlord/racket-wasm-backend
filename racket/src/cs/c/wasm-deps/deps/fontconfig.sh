# FontConfig recipe.
#
# Needs expat (XML config parsing) and FreeType (font introspection).
# Pulled in by Pango; racket/draw reaches Fc* via Pango's font lookups.
#
# We disable the cache builder and doc generation, and skip the
# fontconfig tools (fc-cache, fc-list, fc-match -- they need fork+exec
# we don't have on wasm32).

DEP_NAME=fontconfig
DEP_VERSION=2.15.0
DEP_SOURCE_URL=https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz
DEP_SOURCE_SHA256=63a0658d0e06e0fa886106452b58ef04f21f58202ea02a94c39de0d3335d7c0e
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  -Ddoc=disabled
  -Ddoc-pdf=disabled
  -Ddoc-txt=disabled
  -Ddoc-man=disabled
  -Ddoc-html=disabled
  -Dtests=disabled
  -Dtools=disabled
  -Dnls=disabled
  -Dcache-build=disabled
)
DEP_INSTALL_LIB=libfontconfig.a
DEP_LINK_FLAGS=(-lfontconfig)
DEP_SYMBOLS_MODE=scrape
# Public symbols are Fc-prefixed (Fc.. is the official API; FcFoo) plus
# a few Fc-config setters that are TBR rather than T.
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libfontconfig.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^Fc[A-Z]/ {print \$3}" \
  | sort -u'

wasm_dep_patch() {
  # emcc declares random_r/initstate_r/etc. via the libc headers but
  # doesn't define them; cc.has_function passes, FontConfig sets
  # HAVE_RANDOM_R, then fccompat.c fails to compile because struct
  # random_data isn't a complete type. Remove from the detection
  # list so HAVE_RANDOM_R stays unset.
  if grep -q "'random_r'" meson.build; then
    sed -i.bak -E "/^[[:space:]]*\['random_r'\],?[[:space:]]*$/d" meson.build
  fi
}
