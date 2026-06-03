# host-scheme.sh -- shared detection of a native *threaded* host Chez
# Scheme for the WASM cross-build (tpb32l boot + racket.boot stages).
#
# Source this and call `find_host_scheme <racket/src dir>`; it echoes the
# path to the first native threaded `scheme` executable it finds, or
# nothing (and returns non-zero) if none exists. Threaded (`t*`) is
# required: the cross-compiler is generated from a threaded host so cp0
# doesn't trip on thread.sls (build-wasm.md §3).
#
# Two layouts are searched, in order:
#   1. <src>/build/cs/c/ChezScheme/t*/bin/t*/scheme   (from `make cs`)
#   2. <src>/ChezScheme/t*/bin/t*/scheme              (from build-chez-host.sh)

find_host_scheme() {
  local src="$1" s
  for s in "$src"/build/cs/c/ChezScheme/t*/bin/t*/scheme \
           "$src"/ChezScheme/t*/bin/t*/scheme; do
    # The glob is unquoted on purpose; if it doesn't match, the literal
    # pattern is left and the -x test fails, so we just skip it.
    if [ -x "$s" ]; then
      echo "$s"
      return 0
    fi
  done
  return 1
}
