# expat recipe.
#
# FontConfig depends on expat (XML parsing for fonts.conf). cmake build.

DEP_NAME=expat
DEP_VERSION=2.6.2
DEP_SOURCE_URL=https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz
DEP_SOURCE_SHA256=ee14b4c5d8908b1bec37ad937607eab183d4d9806a08adee472c3c3121d27364
DEP_BUILD_SYSTEM=cmake
DEP_BUILD_ARGS=(
  -DEXPAT_BUILD_DOCS=OFF
  -DEXPAT_BUILD_EXAMPLES=OFF
  -DEXPAT_BUILD_TESTS=OFF
  -DEXPAT_BUILD_TOOLS=OFF
  -DEXPAT_SHARED_LIBS=OFF
)
DEP_INSTALL_LIB=libexpat.a
DEP_LINK_FLAGS=(-lexpat)
DEP_SYMBOLS_MODE=scrape
DEP_SYMBOLS_SCRAPE='llvm-nm --defined-only --extern-only lib/libexpat.a 2>/dev/null \
  | awk "\$2 ~ /^[TBR]\$/ && \$3 ~ /^XML_/ {print \$3}" \
  | sort -u'
