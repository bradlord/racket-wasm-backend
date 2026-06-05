#!/bin/sh

source ~/emsdk/emsdk_env.sh
#   make wasm SCHEME=$HOME/oss/cz/bin/tarm64osx/scheme \
#       CONFIGURE_WRAPPER=emconfigure \
#       RACKET=$HOME/oss/minimal-racket/bin/racket PKGS=draw-lib \
#       CS_CROSS_SUFFIX=-cross \
#       CONFIGURE_ARGS="--enable-pb --enable-mach=tpb32l --host=wasm32-unknown-emscripten"
# make wasm SCHEME=$HOME/oss/cz/bin/tarm64osx/scheme \
#     CONFIGURE_WRAPPER=emconfigure \
#     RACKET=$HOME/oss/minimal-racket/bin/racket PKGS=draw-lib WASM_DEPS="draw" \
#     CS_CROSS_SUFFIX=-cross SETUP_MACHINE_FLAGS="-MCR `pwd`/build/zo:" \
#     CONFIGURE_ARGS="--enable-pb --enable-mach=tpb32l --host=wasm32-unknown-emscripten"

# Args:
# CONFIGURE_WRAPPER should be set by the target, so can probably be removed
# CONFIGURE_ARGS should be set by the target, so can probably be removed
# I think we need CS_CROSS_SUFFIX, but we should probably set it automatically in the target
# Ditto for SETUP_MACHINE_FLAGS and , but maybe we need to be override them?
# I want to get RACKET=auto working, but CONFIGURE_WRAPPER and CONFIGURE_ARGS may be interering
# make wasm SCHEME=$HOME/oss/cz/bin/tarm64osx/scheme \
#     CONFIGURE_WRAPPER=emconfigure \
#     RACKET=$HOME/oss/minimal-racket/bin/racket PKGS= WASM_DEPS= \
#     CS_CROSS_SUFFIX=-cross SETUP_MACHINE_FLAGS="-MCR `pwd`/build/zo:" \
#     CONFIGURE_ARGS="--enable-pb --enable-mach=tpb32l --host=wasm32-unknown-emscripten" && (cd racket/src/build/cs/c/wasm && echo ' (+ 4 5)' | node scheme.js)

# Can experiment with PREFIX and DESTIR. We need to manually ready PREFIX in wasm task. It looks like build-deps gets confused by DESTDIR, so i have up for now.
make wasm SCHEME=$HOME/oss/cz/bin/tarm64osx/scheme \
    RACKET=$HOME/oss/minimal-racket/bin/racket PKGS=draw-lib WASM_DEPS="draw" \
    SETUP_MACHINE_FLAGS="-MCR `pwd`/build/zo:" \
     && (cd racket/src/build/cs/c/wasm && echo ' (+ 4 5)' | node scheme.js)
# make wasm SCHEME=$HOME/oss/cz/bin/tarm64osx/scheme \
#     RACKET=$HOME/oss/minimal-racket/bin/racket PKGS= WASM_DEPS= \
#     CS_CROSS_SUFFIX=-cross SETUP_MACHINE_FLAGS="-MCR `pwd`/build/zo:" \
#     PREFIX=/racket DESTDIR=`pwd`/build/wasm \
#     CONFIGURE_ARGS="--enable-pb --enable-mach=tpb32l --host=wasm32-unknown-emscripten" && (cd racket/src/build/cs/c/wasm && echo ' (+ 4 5)' | node scheme.js)
# make wasm SCHEME=$HOME/oss/cz/bin/tarm64osx/scheme \
#     CONFIGURE_WRAPPER=emconfigure \
#     RACKET=$HOME/oss/minimal-racket/bin/racket PKGS=draw-lib \
#     CS_CROSS_SUFFIX=-cross SETUP_MACHINE_FLAGS="-MCR `pwd`/build/zo:" \
#     CONFIGURE_ARGS="--enable-pb --enable-mach=tpb32l --host=wasm32-unknown-emscripten"
