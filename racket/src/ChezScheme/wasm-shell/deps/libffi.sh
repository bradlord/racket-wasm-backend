# libffi recipe.
#
# Chez's --enable-libffi build links against libffi for the pb foreign
# call path. We don't register any symbols by name: Chez itself
# references the libffi entry points it needs, so wasm-ld keeps them.
# This recipe is the proof case for the deps/ pattern.
#
# 3.5.x is required; 3.4.x uses deprecated Emscripten JS-library names
# (generateFuncType, uleb128Encode) that newer emsdk renames.

DEP_NAME=libffi
DEP_VERSION=3.5.2
DEP_SOURCE_URL=https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz
DEP_SOURCE_SHA256=f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc
DEP_CONFIGURE_ARGS=(
  --enable-static
  --disable-shared
  --disable-docs
  --disable-multi-os-directory
)
DEP_INSTALL_LIB=libffi.a
DEP_LINK_FLAGS=(-lffi)
DEP_SYMBOLS_MODE=none
