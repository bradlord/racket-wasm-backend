# pixman recipe.
#
# 0.43+ is meson-only; this is our meson proof case. Cairo 1.18+
# requires pixman >= 0.40.0, so a modern pixman works for any Cairo
# version we land. All SIMD options are auto-detected by meson and
# correctly skipped on wasm32 (no x86/ARM/MIPS code paths), so we
# don't need the long --disable-mmx/sse/neon list the autotools
# recipe used to need.

DEP_NAME=pixman
DEP_VERSION=0.44.2
DEP_SOURCE_URL=https://www.cairographics.org/releases/pixman-0.44.2.tar.gz
DEP_SOURCE_SHA256=6349061ce1a338ab6952b92194d1b0377472244208d47ff25bef86fc71973466
DEP_BUILD_SYSTEM=meson
DEP_BUILD_ARGS=(
  -Dtests=disabled
  -Ddemos=disabled
  -Dlibpng=disabled
  -Dgtk=disabled
)
DEP_INSTALL_LIB=libpixman-1.a
DEP_LINK_FLAGS=(-lpixman-1)
DEP_SYMBOLS_MODE=none
