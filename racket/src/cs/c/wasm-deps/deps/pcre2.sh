# PCRE2 recipe.
#
# Required dep of GLib 2.74+. cmake-based (autotools also exists but
# we already have a cmake dispatcher; use it). 8-bit code unit is the
# only variant GLib needs.

DEP_NAME=pcre2
DEP_VERSION=10.44
DEP_SOURCE_URL=https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz
DEP_SOURCE_SHA256=86b9cb0aa3bcb7994faa88018292bc704cdbb708e785f7c74352ff6ea7d3175b
DEP_BUILD_SYSTEM=cmake
DEP_BUILD_ARGS=(
  -DPCRE2_BUILD_PCRE2_8=ON
  -DPCRE2_BUILD_PCRE2_16=OFF
  -DPCRE2_BUILD_PCRE2_32=OFF
  -DPCRE2_BUILD_TESTS=OFF
  -DPCRE2_BUILD_PCRE2GREP=OFF
  -DPCRE2_SUPPORT_JIT=OFF
)
DEP_INSTALL_LIB=libpcre2-8.a
DEP_LINK_FLAGS=(-lpcre2-8)
DEP_SYMBOLS_MODE=none
