#!/bin/bash
# Check that bench-pairs.sh gives each case the verdict of its A/A pair and its main/branch pairs.
# Run by `make test-hooks`.
set -uo pipefail
pairs="$(cd "$(dirname "$0")" && pwd)/bench-pairs.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# One log line per case, in the format of the benches: "<Suite>Benchmark <case>: p50 ... p95 ...".
log() { # log <file> <p95 ms of case a> <p95 ms of case b>
  printf 'XBenchmark a: p50 0.001 seconds, p95 %s seconds\nXBenchmark b: p50 0.001 seconds, p95 %s seconds\n' \
    "$(echo "$2 / 1000" | bc -l)" "$(echo "$3 / 1000" | bc -l)" > "$1"
}
log "$tmp/aa-1.log" 10 10
log "$tmp/aa-2.log" 10.2 10
log "$tmp/main-1.log" 10 10
log "$tmp/branch-1.log" 10.3 13
log "$tmp/main-2.log" 10.1 10
log "$tmp/branch-2.log" 10.2 13.5
out="$("$pairs" --compare "$tmp" 2>&1)"
grep -q '^VERIFIED XBenchmark a$' <<< "$out" || { echo "FAIL: a case in the rule is VERIFIED: $out"; failures=$((failures + 1)); }
grep -q '^NOT VERIFIED XBenchmark b$' <<< "$out" || { echo "FAIL: a case over the rule in each pair is NOT VERIFIED: $out"; failures=$((failures + 1)); }

# The A/A pair of main moves more than the rule: no verdict from the branch numbers.
log "$tmp/aa-2.log" 13 10
out="$("$pairs" --compare "$tmp" 2>&1)"
grep -q '^INCONCLUSIVE XBenchmark a (A/A' <<< "$out" || { echo "FAIL: an A/A spread over the rule is INCONCLUSIVE: $out"; failures=$((failures + 1)); }

# Over the rule in one pair only: INCONCLUSIVE, not a pick of the clean pair.
log "$tmp/aa-2.log" 10 10
log "$tmp/branch-2.log" 10.2 10.1
out="$("$pairs" --compare "$tmp" 2>&1)"
grep -q '^INCONCLUSIVE XBenchmark b (1 of 2 pairs' <<< "$out" || { echo "FAIL: one pair over the rule is INCONCLUSIVE: $out"; failures=$((failures + 1)); }

# bench.sh has no Makefile line of its own: its test runs here.
bash "$(dirname "$0")/bench.test.sh" || failures=$((failures + 1))

[[ $failures -eq 0 ]] && echo "bench-pairs tests: all passed"
exit $((failures > 0))
