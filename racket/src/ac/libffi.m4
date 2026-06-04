if test "${enable_libffi}" = "yes" ; then
 if test "${enable_foreign}" = "yes" ; then
  AC_MSG_CHECKING([for libffi])

  # Try to get flags form pkg-config:
  libffi_config_prog="pkg-config libffi"
  libffi_config_preflags=`$libffi_config_prog --cflags-only-I  2> /dev/null`
  if test "$?" = 0 ; then
    libffi_config_cflags=`$libffi_config_prog --cflags-only-other  2> /dev/null`
    if test "$?" = 0 ; then
      libffi_config_libs=`$libffi_config_prog --libs  2> /dev/null`
      if test "$?" != 0 ; then
        libffi_config_preflags=""
        libffi_config_cflags=""
        libffi_config_libs="-lffi"
      fi
    else
      libffi_config_preflags=""
      libffi_config_cflags=""
      libffi_config_libs="-lffi"
    fi
  else
    libffi_config_preflags=""
    libffi_config_cflags=""
    libffi_config_libs="-lffi"
  fi

  OLD_CFLAGS="${CFLAGS}"
  OLD_LIBS="${LIBS}"
  CFLAGS="${CFLAGS} ${libffi_config_preflags} ${libffi_config_cflags}"
  LIBS="${LIBS} ${libffi_config_libs}"
  if test "${EMSCRIPTEN}" = "t" ; then
    # Cross-compiling for WebAssembly: an AC_TRY_LINK can't run, and
    # libffi is provided out-of-band (the `wasm-deps` build target,
    # cs/c/wasm-deps/build-deps.sh, builds it; it is linked at the emcc
    # step). Assume it is available, but drop
    # -lffi from LIBS: there is no wasm libffi for configure's own test
    # links, and leaving it in breaks the rktio sub-configure's
    # "C compiler works" check (wasm-ld: unable to find library -lffi).
    have_libffi=yes
    LIBS="${OLD_LIBS}"
  else
    AC_TRY_LINK([#include <ffi.h>],
                [ffi_cif cif; ]
                [ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 0, &ffi_type_void, NULL);],
               have_libffi=yes,
               have_libffi=no)
  fi
  AC_MSG_RESULT($have_libffi)
  if test "${have_libffi}" = "no" ; then
    CFLAGS="${OLD_CFLAGS}"
    LIBS="${OLD_LIBS}"
    echo "${libffi_unavailable_message}"
    if test "${complain_if_libffi_fails}" = "yes" ; then
       echo configure: unable to link to libffi
       exit 1
    fi
  else
    CFLAGS="${OLD_CFLAGS}"
    PREFLAGS="${PREFLAGS} ${libffi_config_preflags}"
    COMPFLAGS="${COMPFLAGS} ${libffi_config_cflags}"
    echo "Using installed libffi"
    OWN_LIBFFI="OFF"
  fi
 fi
fi
