# pixman recipe.
#
# 0.42.2 is the last autoconf release; 0.43+ is meson-only. Cairo's
# software backend bottoms out into pixman, so we'll need this once
# Cairo lands.
#
# pixman ships SIMD paths for x86/ARM that don't make sense on wasm32
# and that tend to break the configure check. --disable-mmx etc. forces
# the portable C path everywhere.

DEP_NAME=pixman
DEP_VERSION=0.42.2
DEP_SOURCE_URL=https://www.cairographics.org/releases/pixman-0.42.2.tar.gz
DEP_SOURCE_SHA256=ea1480efada2fd948bc75366f7c349e1c96d3297d09a3fe62626e38e234a625e
DEP_CONFIGURE_ARGS=(
  --enable-static
  --disable-shared
  --disable-mmx
  --disable-sse2
  --disable-ssse3
  --disable-arm-simd
  --disable-arm-neon
  --disable-arm-a64-neon
  --disable-arm-iwmmxt
  --disable-vmx
  --disable-mips-dspr2
  --disable-loongson-mmi
  --disable-gtk
  --disable-libpng
)
DEP_INSTALL_LIB=libpixman-1.a
DEP_SYMBOLS_MODE=none
