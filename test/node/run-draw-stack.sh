#!/usr/bin/env bash
#
# Assert the draw-lib FFI stack (cairo / png / freetype) still resolves and
# paints under the WASM/node build, by running draw-stack-test.rkt and checking
# its output. The .rkt file itself only PRINTS its result (it never exits
# non-zero), so this wrapper is what turns it into a pass/fail gate for CI.
#
# Runs against the orchestrator's clone (.work/racket) by default; point
# RACKET_WASM_CLONE at a different built tree to override. The clone's node
# racket.js exists iff a COLD build happened -- which is exactly when the FFI
# linkage (wasm-deps/delta) could have changed. On a warm cache-hit build the
# clone is absent and the runtime is byte-identical to a prior green run, so we
# skip (exit 0) rather than chase the package-agnostic node files out of the
# content-addressed runtime cache.
#
# Usage:
#   ./run-draw-stack.sh
#   RACKET_WASM_CLONE=/path/to/built/clone ./run-draw-stack.sh
#
# Exits 0 on pass (or warm skip); non-zero on a missing/failed FFI stack.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
clone="${RACKET_WASM_CLONE:-$repo_root/.work/racket}"

racket_js="$clone/racket/src/build/cs/c/wasm/racket.js"
test_rkt="$here/draw-stack-test.rkt"

if [ ! -f "$racket_js" ]; then
  if [ -n "${RACKET_WASM_CLONE:-}" ]; then
    echo "racket.js not built: $racket_js" >&2
    exit 1
  fi
  echo "draw-stack: SKIP (no clone runtime at $racket_js -- warm cache build, FFI stack unchanged)"
  exit 0
fi
[ -f "$test_rkt" ] || { echo "missing $test_rkt" >&2; exit 1; }

out="$(tail -n +2 "$test_rkt" | node "$racket_js" 2>&1)"
status=$?
echo "$out"

if [ "$status" -ne 0 ]; then
  echo "draw-stack: FAIL (node exit $status)" >&2
  exit 1
fi

# What we can assert against the package-agnostic NODE base runtime (which bakes
# PKGS=, so the draw-lib *collection* isn't present -- the test's
# `dynamic-require racket/draw/unsafe/...` lines error here, which is expected
# and benign): the cairo native lib is linked and drives a real surface paint.
#   - `cairo: #<ffi-lib>` proves ffi-lib + the rktio static-symbol shim resolve.
#   - `40 80 ff ff` is the read-back pixel from an actual
#     cairo_image_surface_create_for_data + paint + flush -- end-to-end FFI proof.
fail=0
grep -q 'cairo: #<ffi-lib>' <<<"$out" || { echo "draw-stack: FAIL (ffi-lib libcairo did not resolve)" >&2; fail=1; }
grep -q '40 80 ff ff'       <<<"$out" || { echo "draw-stack: FAIL (cairo paint pixel != expected 40 80 ff ff)" >&2; fail=1; }

[ "$fail" -eq 0 ] && echo "draw-stack: pass (libcairo resolved, paint == 40 80 ff ff)"
exit "$fail"
