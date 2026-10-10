#!/bin/bash
# Run the make targets of a check with -k, so a red target does not skip the later targets. When
# the only red targets are test and test-slow-push, rerun only their failed Swift tests with
# test-filter.sh --exact, after the load wait of check-changed.sh: up to 3 tries, or 1 try with
# CHECK_RISK=yes. A later try reruns each test with a failed line or with no pass line in the last
# try. The names of test-slow-push rerun with DIRIGIBLE_SLOW_TESTS=1 and --no-parallel. A pass on
# a rerun prints the flake line and appends '<HEAD> <name> load <1-min load>' to dirigible-flakes
# in the git common dir: the load at the end of the check, not at the failure. land.sh writes a
# flake row for each line, and flake-triage.md still applies (decision 0028).
# No rerun, and exit 1: another red target, a not-remade target other than check, a crash, an
# issue of no test, a test process that ended before its report (scripts/swift-test.sh: the tests
# after the end did not run), or a red target with no failed test line.
# Usage: [CHECK_RISK=yes] scripts/run-checks.sh <make args>
#        scripts/run-checks.sh --flakes   print the lines of dirigible-flakes (nothing with no file)
#          and run no make. The guardrail hook blocks each other write to the file.
# The check-changed target of the Makefile and land.sh call it. scripts/run-checks.test.sh tests it.
set -euo pipefail
if [[ "${1:-}" == --flakes ]]; then
    cat "$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes" 2>/dev/null || true
    exit 0
fi
# A stamped run (BASE set by make check-changed BASE=<ref>, which exports it, or by the land.sh
# delta) marks the tree while it runs: .githooks/pre-commit refuses a commit while the mark is
# live, because a commit makes the pass stamp useless. The mark is a file of the run pid in
# dirigible-check-running of the git dir. It holds the start time of the pid, so a reused pid is
# not live. The EXIT trap removes the mark, and the loop removes a stale mark.
mark=""
if [[ -n "${BASE:-}" ]]; then
    marks="$(git rev-parse --path-format=absolute --git-dir)/dirigible-check-running"
    mkdir -p "$marks"
    for f in "$marks"/*; do
        [[ -e $f ]] || continue
        p="${f##*/}"
        { kill -0 "$p" 2>/dev/null && [[ "$(cat "$f")" == "$(ps -o lstart= -p "$p")" ]]; } || rm -f "$f"
    done
    mark="$marks/$$"
    ps -o lstart= -p $$ > "$mark"
fi
here="$(cd "$(dirname "$0")" && pwd)"
log="$(mktemp)"
trap 'rm -f "$log" "$log".* ${mark:+"$mark"}' EXIT

# GNU Make 3.81 writes the Error and not-remade lines to stderr: 2>&1 keeps them in order.
if "${MAKE:-make}" -k "$@" 2>&1 | tee "$log"; then exit 0; fi
# The load at the end of the check: make -k runs the later targets after a red test.
load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"

no_rerun() { echo "run-checks: no rerun: $1" >&2; exit 1; }
prefix='^make(\[[0-9]+\])?: '
failed='✘ Test [A-Za-z_][A-Za-z0-9_]*[(][^)]*[)]( with [0-9]+ test cases)? failed after'
# blocked <log>: the reason that a log names no rerunnable test, or nothing.
blocked() {
    if grep -qF 'Exited with unexpected signal' "$1"; then echo 'a test process crashed'
    elif grep -qF '✘ Test «unknown»' "$1"; then echo 'an issue of no test'
    elif grep -qF 'the test process ended before its report' "$1"; then echo 'a test process ended before its report'
    fi
}
# once: the words of stdin on one line, each once.
once() { tr ' ' '\n' | awk 'NF && !s[$0]++' | xargs; }

errors="$(grep -E "$prefix\*\*\* " "$log" || true)"
ours="$prefix\*\*\* \[(test|test-slow-push)\] Error"
grep -qE "$ours" <<<"$errors" || no_rerun 'no red test or test-slow-push target'
! grep -vqE "$ours" <<<"$errors" || no_rerun 'a target other than test and test-slow-push failed'
remade="$(grep -E 'not remade because of errors' "$log" || true)"
[[ -z "$remade" ]] || ! grep -vqE "${prefix}Target [\`']check' not remade because of errors\.$" <<<"$remade" ||
    no_rerun 'a target other than check is not remade'
reason="$(blocked "$log")"
[[ -z "$reason" ]] || no_rerun "$reason"

# Make writes the Error line of a target after its output, so the failed test lines before the
# [test] Error line are fast tests, and those before the [test-slow-push] Error line are slow.
split="$(awk -v failed="$failed" '
    $0 ~ failed { n = $0; sub(/.*✘ Test /, "", n); sub(/\(.*/, "", n); names = names " " n; next }
    /^make(\[[0-9]+\])?: \*\*\* \[test\] Error/ { print "fast" names; names = ""; next }
    /^make(\[[0-9]+\])?: \*\*\* \[test-slow-push\] Error/ { print "slow" names; names = ""; next }
    END { if (names != "") print "left" names }
' "$log")"
! grep -qxE 'fast|slow' <<<"$split" || no_rerun 'a red target with no failed test line'
! grep -q '^left' <<<"$split" || no_rerun 'a failed test line of no red target'
fast="$(sed -n 's/^fast//p' <<<"$split" | once)"
slow="$(sed -n 's/^slow//p' <<<"$split" | once)"
all="$(xargs <<<"$fast $slow")"

# rerun <names> <command>: prints each name with a failed line or with no pass line in the output
# of the command (none: all passed). A test that did not run stays red, and so does a name of two
# suites with one red suite. A crash, an issue of no test, or a red command in which each name
# passed returns 1.
rerun() {
    local names="$1" code=0 why left="" name cases='[(][^)]*[)]( with [0-9]+ test cases)?'
    shift
    "$@" 2>&1 | tee "$log.rerun" >&2 || code=$?
    why="$(blocked "$log.rerun")"
    for name in $names; do
        if grep -qE "✘ Test $name$cases failed after" "$log.rerun" ||
            ! grep -qE "(✔|✘) Test $name$cases passed after" "$log.rerun"; then left+=" $name"; fi
    done
    [[ $code -eq 0 || -n "$left" ]] || why="${why:-no failed test line}"
    [[ -z "$why" ]] || { echo "run-checks: the rerun stopped: $why" >&2; return 1; }
    echo $left
}

tries=3
[[ "${CHECK_RISK:-}" != yes ]] || tries=1
for ((try = 1; try <= tries; try++)); do
    echo "run-checks: rerun $try of $tries: $(xargs <<<"$fast $slow")"
    "$here/check-changed.sh" --wait-load test
    [[ -z "$fast" ]] || fast="$(rerun "$fast" env -u DIRIGIBLE_SLOW_TESTS "$here/test-filter.sh" --exact $fast)" || exit 1
    [[ -z "$slow" ]] || slow="$(rerun "$slow" env DIRIGIBLE_SLOW_TESTS=1 "$here/test-filter.sh" --exact --no-parallel $slow)" || exit 1
    if [[ -z "$fast$slow" ]]; then
        head="$(git rev-parse HEAD)" file="$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes"
        for name in $all; do echo "$head $name load $load" >> "$file"; done
        echo "run-checks: flake: $all passed on rerun $try of $tries"
        exit 0
    fi
done
echo "run-checks: red after $tries reruns: $(xargs <<<"$fast $slow")" >&2
exit 1
