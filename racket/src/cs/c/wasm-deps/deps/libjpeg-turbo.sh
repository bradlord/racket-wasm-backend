# libjpeg-turbo recipe (cmake build).
#
# 3.0+ is cmake-only; this is the first cmake recipe in deps/. SIMD
# is disabled because wasm32 has no matching x86/ARM assembly. The
# build produces libjpeg.a (a "jpeg9-ish" API) and libturbojpeg.a
# (the higher-level turbo API); racket/draw uses the former.
#
# Symbols are scraped from libjpeg.a; the public C API is `jpeg_*`,
# the support helpers `jcopy_*`, `jzero_*`, `jdiv_round_up`, etc. are
# internal-but-extern and we filter them out. `jinit_*` (the per-
# component initializers) are part of the public API.

DEP_NAME=libjpeg-turbo
DEP_VERSION=3.1.0
DEP_SOURCE_URL=https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.0/libjpeg-turbo-3.1.0.tar.gz
DEP_SOURCE_SHA256=9564c72b1dfd1d6fe6274c5f95a8d989b59854575d4bbee44ade7bc17aa9bc93
DEP_BUILD_SYSTEM=cmake
DEP_BUILD_ARGS=(
  -DENABLE_SHARED=OFF
  -DENABLE_STATIC=ON
  -DREQUIRE_SIMD=OFF
  -DWITH_TURBOJPEG=OFF
  -DWITH_JAVA=OFF
  -DWITH_FUZZ=OFF
)
DEP_INSTALL_LIB=libjpeg.a
DEP_LINK_FLAGS=(-ljpeg)
DEP_SYMBOLS_MODE=scrape
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libjpeg.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && (\$3 ~ /^jpeg_/ || \$3 ~ /^jinit_/) {print \$3}" \
  | sort -u'
