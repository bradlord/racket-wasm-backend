#!/usr/bin/env bash
#
# Run a slice of the Racket core test suite under the WASM/node build.
#
# Each .rktl in pkgs/racket-test-core/tests/racket/ is a flat script
# meant to be `load`ed inside a session that already evaluated
# testing.rktl (which defines `Section`, `test`, `report-errs`, etc.).
# The shell version of the test driver isn't available in the preloaded
# /collects, so we concatenate testing.rktl + the target test and pipe
# it through stdin, then grep for the summary line.
#
# Usage:
#   ./run-tests.sh              # default slice
#   ./run-tests.sh list hash    # specific tests
#
# Runs against the orchestrator's clone (.work/racket) by default; point
# RACKET_WASM_CLONE at a different built tree to override.
#
# Exits 0 iff every test that returned a summary passed.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
clone="${RACKET_WASM_CLONE:-$repo_root/.work/racket}"

racket_js="$clone/racket/src/build/cs/c/wasm/racket.js"
tests_dir="$clone/pkgs/racket-test-core/tests/racket"

[ -f "$racket_js" ]                      || { echo "racket.js not built: $racket_js" >&2; exit 1; }
[ -f "$tests_dir/testing.rktl" ]         || { echo "test harness missing: $tests_dir/testing.rktl" >&2; exit 1; }

DEFAULT=(
  control     # delimited continuations, prompts, shift/control
  contmark    # continuation marks
  generator   # generators (call/cc plumbing)
  list        # racket/list
  hash        # racket/hash
  string      # racket/string
  bytes       # racket/bytes
  for         # iteration / sequences
  number      # arithmetic (~75k tests)
  fixnum      # fixnum ops (~105k tests)
  flonum      # flonum ops (~94k tests)
  math        # generic math
  chaperone   # impersonators / contracts
  error       # exceptions / raise
  stxparam    # syntax parameters
)

[ "$#" -gt 0 ] && tests=("$@") || tests=("${DEFAULT[@]}")

work="$(mktemp -d "${TMPDIR:-/tmp}/wasm-rktest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail=0
total_pass=0
for t in "${tests[@]}"; do
  src="$tests_dir/$t.rktl"
  if [ ! -f "$src" ]; then
    printf "%-14s SKIP (no %s)\n" "$t" "$src"
    continue
  fi

  combined="$work/$t.rktl"
  {
    cat "$tests_dir/testing.rktl"
    tail -n +2 "$src"   # drop the (load-relative "loadtest.rktl") line
    printf '\n(printf "==DONE== %%s pass=%%s err=%%s accum=%%s\\n" %s\n' \
           "'$t (length errs) (length accum-errs)"
    # extra closing paren for the printf arg list
    printf ' (void))\n'
  } > "$combined"

  out="$work/$t.out"
  if ! node "$racket_js" < "$combined" >"$out" 2>&1; then
    printf "%-14s ERROR (node exit)\n" "$t"
    fail=$((fail + 1))
    continue
  fi

  summary="$(grep -E 'Performed|==DONE==' "$out" | tr -d '\r')"
  if grep -q 'Passed all tests' "$out"; then
    perf=$(grep -oE 'Performed [0-9]+ expression tests' "$out" | head -1 | grep -oE '[0-9]+')
    total_pass=$((total_pass + ${perf:-0}))
    printf "%-14s pass (%s tests)\n" "$t" "${perf:-?}"
  elif grep -q 'Errors were' "$out"; then
    perf=$(grep -oE 'Performed [0-9]+ expression tests' "$out" | head -1 | grep -oE '[0-9]+')
    errs=$(grep -oE 'Errors were \[[0-9]+\]' "$out" | grep -oE '[0-9]+')
    total_pass=$((total_pass + ${perf:-0} - ${errs:-0}))
    printf "%-14s PART (%s tests, %s failing)  -- see %s\n" "$t" "${perf:-?}" "${errs:-?}" "$out"
    fail=$((fail + 1))
  else
    printf "%-14s NO SUMMARY  -- see %s\n" "$t" "$out"
    fail=$((fail + 1))
  fi
done

printf "\ntotal passing: %s\n" "$total_pass"
[ "$fail" -eq 0 ] || printf "%s suite(s) had failures.\n" "$fail"
exit "$fail"
