#!/bin/bash
# Check that bench-pairs.sh gives each case the verdict of its A/A pair and its main/branch pairs,
# and that --compare refuses logs whose provenance is not one clean commit per side with the bench
# inputs of HEAD. Run by `make test-hooks`.
set -uo pipefail
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A repo with the bench inputs and a copy of the script: --compare checks the branch commit of the
# logs against HEAD of the tree that holds the script.
r="$tmp/repo"
mkdir -p "$r/scripts" "$r/Sources" "$r/Tests" "$r/docs"
cp "$(dirname "$0")/bench-pairs.sh" "$r/scripts/"
for f in Sources/A.swift Tests/T.swift Package.swift Package.resolved scripts/bench.sh docs/d.md; do echo x > "$r/$f"; done
g() { git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q
commit() { g add -A && g commit -qm "$1"; }
commit base
pairs="$r/scripts/bench-pairs.sh"
branch="$(g rev-parse HEAD)"
main=0123456789abcdef0123456789abcdef01234567

# The commit line of bench.sh, then one log line per case, in the format of the benches:
# "<Suite>Benchmark <case>: p50 ... p95 ...". The aa-* and main-* logs name $main, the branch-*
# logs name $branch, each on a clean tree.
log() { # log <file> <p95 ms of case a> <p95 ms of case b>
  local c="$main"
  [[ "${1##*/}" != branch-* ]] || c="$branch"
  printf 'bench: commit %s tree clean filter X\nXBenchmark a: p50 0.001 seconds, p95 %s seconds\nXBenchmark b: p50 0.001 seconds, p95 %s seconds\n' \
    "$c" "$(echo "$2 / 1000" | bc -l)" "$(echo "$3 / 1000" | bc -l)" > "$1"
}
mkdir "$tmp/v"
log "$tmp/v/aa-1.log" 10 10
log "$tmp/v/aa-2.log" 10.2 10
log "$tmp/v/main-1.log" 10 10
log "$tmp/v/branch-1.log" 10.3 13
log "$tmp/v/main-2.log" 10.1 10
log "$tmp/v/branch-2.log" 10.2 13.5
out="$("$pairs" --compare "$tmp/v" 2>&1)"
grep -q '^VERIFIED XBenchmark a$' <<< "$out" || fail "a case in the rule is VERIFIED: $out"
grep -q '^NOT VERIFIED XBenchmark b$' <<< "$out" || fail "a case over the rule in each pair is NOT VERIFIED: $out"

# The A/A pair of main moves more than the rule: no verdict from the branch numbers.
log "$tmp/v/aa-2.log" 13 10
out="$("$pairs" --compare "$tmp/v" 2>&1)"
grep -q '^INCONCLUSIVE XBenchmark a (A/A' <<< "$out" || fail "an A/A spread over the rule is INCONCLUSIVE: $out"

# Over the rule in one pair only: INCONCLUSIVE, not a pick of the clean pair.
log "$tmp/v/aa-2.log" 10 10
log "$tmp/v/branch-2.log" 10.2 10.1
out="$("$pairs" --compare "$tmp/v" 2>&1)"
grep -q '^INCONCLUSIVE XBenchmark b (1 of 2 pairs' <<< "$out" || fail "one pair over the rule is INCONCLUSIVE: $out"

# A side with no sample (a filter that matched no test), or a bench that failed, gives exit 1.
mkdir "$tmp/none"
for f in aa-1 aa-2 main-1 branch-1; do : > "$tmp/none/$f.log"; done
out="$("$pairs" --compare "$tmp/none" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no bench sample in aa-1.log'* ]] || fail "no sample: exit $code: $out"
cp "$tmp"/v/*.log "$tmp/none/"
: > "$tmp/none/branch-2.log"
out="$("$pairs" --compare "$tmp/none" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no bench sample in branch-2.log'* ]] || fail "a branch side with no sample: exit $code: $out"
cp "$tmp/v/branch-2.log" "$tmp/none/"
echo 'main-1: the bench failed' > "$tmp/none/load.txt"
out="$("$pairs" --compare "$tmp/none" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'main-1: the bench failed'* ]] || fail "a failed bench: exit $code: $out"

# Provenance: the pairs give the verdict only when the aa-* and main-* logs name one commit, the
# branch-* logs name one commit, each log ran on a clean tree, and the branch commit has the
# Sources, Tests, Package.swift, Package.resolved, and scripts/bench.sh of HEAD. A set in the
# rule exits 0; each case below changes one log or HEAD and expects exit 1 with the reason.
log "$tmp/v/branch-1.log" 10.3 10.2
mkdir "$tmp/p"
# refused <name> <reason>: --compare of $tmp/p exits 1 with "NOT VERIFIED: <reason>".
refused() {
  out="$("$pairs" --compare "$tmp/p" 2>&1)"
  code=$?
  [[ $code -eq 1 ]] && grep -qF "NOT VERIFIED: $2" <<< "$out" || fail "$1: exit $code: $out"
}
fresh() { rm -f "$tmp/p"/*; cp "$tmp"/v/*.log "$tmp/p/"; }
line() { # line <log> <new first line>
  { echo "$2"; sed 1d "$tmp/p/$1"; } > "$tmp/p/x" && mv "$tmp/p/x" "$tmp/p/$1"
}
fresh
out="$("$pairs" --compare "$tmp/p" 2>&1)"
[[ $? -eq 0 ]] || fail "a set in the rule with good provenance: $out"
line branch-2.log "bench: commit 1111111111111111111111111111111111111111 tree clean filter X"
refused 'branch logs of two commits' 'the branch logs name 2 commits'
fresh
line main-2.log "bench: commit 1111111111111111111111111111111111111111 tree clean filter X"
refused 'aa and main logs of two commits' 'the aa and main logs name 2 commits'
fresh
line branch-1.log "bench: commit $branch tree dirty filter X"
refused 'a branch log on a dirty tree' 'branch-1.log ran on a dirty tree'
fresh
line main-1.log "bench: commit $main tree dirty filter X"
refused 'a main log on a dirty tree' 'main-1.log ran on a dirty tree'
fresh
line aa-1.log 'XBenchmark a: p50 0.001 seconds, p95 0.01 seconds'
refused 'a log with no commit line' 'no bench commit line in aa-1.log'
fresh
echo y > "$r/docs/d.md"
commit docs
out="$("$pairs" --compare "$tmp/p" 2>&1)"
[[ $? -eq 0 ]] || fail "a branch commit that differs from HEAD only in docs/: $out"
echo y > "$r/Sources/A.swift"
commit sources
refused 'a branch commit with other Sources' 'the branch commit differs from HEAD in Sources'
branch="$(g rev-parse HEAD)"
log "$tmp/v/branch-1.log" 10.3 10.2
log "$tmp/v/branch-2.log" 10.2 10.1
fresh
echo y > "$r/Package.resolved"
commit resolved
refused 'a branch commit with another Package.resolved' 'the branch commit differs from HEAD in Package.resolved'
branch="$(g rev-parse HEAD)"
log "$tmp/v/branch-1.log" 10.3 10.2
log "$tmp/v/branch-2.log" 10.2 10.1
fresh
echo y > "$r/scripts/bench.sh"
commit bench
refused 'a branch commit with another bench script' 'the branch commit differs from HEAD in scripts/bench.sh'
# The main side and the branch side name one commit: an A/A comparison, not a verdict.
branch="$(g rev-parse HEAD)"
log "$tmp/v/branch-1.log" 10.3 10.2
log "$tmp/v/branch-2.log" 10.2 10.1
fresh
for f in aa-1 aa-2 main-1 main-2; do line "$f.log" "bench: commit $branch tree clean filter X"; done
refused 'the same commit on both sides' 'the main and branch logs name the same commit'

# A pair run refuses an out folder in a git tree that git does not ignore (its logs would make the
# tree dirty), before it makes the folder or runs a bench.
out="$("$pairs" "$r" X 1 "$r/pairs-out" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == *'is in a git tree and git does not ignore it'* ]] || fail "an out folder in a tree: exit $code: $out"
[[ ! -e "$r/pairs-out" ]] || fail 'an out folder in a tree: the folder was made'

# bench.sh has no Makefile line of its own: its test runs here.
bash "$(dirname "$0")/bench.test.sh" || failures=$((failures + 1))
# with-lock.sh has no Makefile line of its own either (a Makefile change makes the push class bundle).
bash "$(dirname "$0")/with-lock.test.sh" || failures=$((failures + 1))

[[ $failures -eq 0 ]] && echo "bench-pairs tests: all passed"
exit $((failures > 0))
