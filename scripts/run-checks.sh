#!/bin/bash
# Run the make targets of a check with -k, so a red target does not skip the later targets. Before
# make, it waits for a normal load (check-changed.sh --wait-load), after the static gates. When
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
# The partial stamp: with BASE, a tree that is clean at the start and at the end, and the same
# HEAD, tests that stay red after the reruns append '<HEAD> <base commit> failed fast:<names>
# slow:<names>' (names joined with commas) to dirigible-check-partial in the git common dir.
# check-changed.sh <base> is its only reader: it gives the word RERUN=<P>:fast:<names>+slow:<names>.
# This script runs the other targets first, then the names of the word as the tries above, with
# one flake line for each name that passes; no name gets two flake lines in one check. The word
# never goes to make. A red check with a word keeps the names of the word in its partial line.
# Usage: [CHECK_RISK=yes] scripts/run-checks.sh <make args> [RERUN=<P>:fast:<names>+slow:<names>]
#        scripts/run-checks.sh --flakes   print the lines of dirigible-flakes (nothing with no file)
#          and run no make. The guardrail hook blocks each other command that names the file, except a read.
# The check-changed target of the Makefile and land.sh call it. scripts/run-checks.test.sh tests it.
set -euo pipefail
if [[ "${1:-}" == --flakes ]]; then
    cat "$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes" 2>/dev/null || true
    exit 0
fi
word="" args=()
for a in "$@"; do
    if [[ $a == RERUN=* ]]; then word="${a#RERUN=}"; else args+=("$a"); fi
done
set -- ${args[@]+"${args[@]}"}
# A stamped run (BASE set by make check-changed BASE=<ref>, which exports it, or by the land.sh
# delta) marks the tree while it runs: .githooks/pre-commit refuses a commit while the mark is
# live, because a commit makes the pass stamp useless. The mark is a file of the run pid in
# dirigible-check-running of the git dir. It holds the start time of the pid, so a reused pid is
# not live. The EXIT trap removes the mark, and the loop removes a stale mark.
mark="" base="" start_head="" start_tree=""
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
    base="$(git rev-parse -q --verify "$BASE^{commit}" || true)"
    start_head="$(git rev-parse HEAD)" start_tree="$(git status --porcelain)"
fi
here="$(cd "$(dirname "$0")" && pwd)"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
log="$(mktemp)"
trap 'rm -f "$log" "$log".* ${mark:+"$mark"}' EXIT

skip=() vars=() goals=() first=no
for a in "$@"; do
    if [[ $a == *=* ]]; then vars+=("$a"); else goals+=("$a"); fi
    if [[ $a == check || $a == check-fast ]]; then first=yes; fi
done

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

# retry: the tries of the names in $fast and $slow, which keep the names that stay red. On a pass,
# one dirigible-flakes line for each name with no line in this check, and return 0.
tries=3 written=" "
[[ "${CHECK_RISK:-}" != yes ]] || tries=1
retry() {
    local try name head all
    all="$(xargs <<<"$fast $slow")"
    for ((try = 1; try <= tries; try++)); do
        echo "run-checks: rerun $try of $tries: $(xargs <<<"$fast $slow")"
        "$here/check-changed.sh" --wait-load test || exit 1
        [[ -z "$fast" ]] || fast="$(rerun "$fast" env -u DIRIGIBLE_SLOW_TESTS "$here/test-filter.sh" --exact $fast)" || exit 1
        [[ -z "$slow" ]] || slow="$(rerun "$slow" env DIRIGIBLE_SLOW_TESTS=1 "$here/test-filter.sh" --exact --no-parallel $slow)" || exit 1
        if [[ -z "$fast$slow" ]]; then
            head="$(git rev-parse HEAD)"
            for name in $all; do
                [[ "$written" != *" $name "* ]] || continue
                echo "$head $name load $load" >> "$common/dirigible-flakes"
                written+="$name "
            done
            echo "run-checks: flake: $all passed on rerun $try of $tries"
            return 0
        fi
    done
    echo "run-checks: red after $tries reruns: $(xargs <<<"$fast $slow")" >&2
    return 1
}
# partial <fast names> <slow names>: append the partial stamp line, when the check had a base, the
# tree was clean at the start and is clean now, and HEAD did not move.
partial() {
    [[ -n $base && -z $start_tree && -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$start_head" ]] || return 0
    echo "$start_head $base failed fast:$(once <<<"$1" | tr ' ' ,) slow:$(once <<<"$2" | tr ' ' ,)" >> "$common/dirigible-check-partial"
    echo "run-checks: partial stamp of $start_head: $(xargs <<<"$1 $2")"
}
# The names of the word: fast before +slow:, slow after it, with spaces for the commas.
names="${word#*:}" word_fast="" word_slow=""
if [[ -n $word ]]; then
    word_fast="${names%%+slow:*}" word_fast="${word_fast#fast:}" word_slow="${names#*+slow:}"
    word_fast="${word_fast//,/ }" word_slow="${word_slow//,/ }"
fi

# With no goal (only a word), make does not run: make with no goal runs the default goal setup.
if [[ ${#goals[@]} -gt 0 ]]; then
    # The static gates first (decision 0028): for the goal check or check-fast, make -k static
    # runs the gates of STATIC_GATES in the Makefile. A red gate stops the check before the Swift
    # targets. The main make then skips each passed gate with -o, so each gate runs once. GNU make
    # does not pass -o to a nested make.
    gates="$(sed -n 's/^STATIC_GATES := //p' Makefile 2>/dev/null || true)"
    if [[ $first == yes && -n $gates ]]; then
        for g in $gates; do skip+=(-o "$g"); done
    fi
    if [[ ${#skip[@]} -gt 0 ]] && ! "${MAKE:-make}" -k static ${vars[@]+"${vars[@]}"} 2>&1; then
        echo "run-checks: a static gate is red" >&2
        exit 1
    fi
    # The load wait of check-changed.sh comes after the static gates, so a red gate does not wait.
    "$here/check-changed.sh" --wait-load "${goals[@]}"
    # GNU Make 3.81 writes the Error and not-remade lines to stderr: 2>&1 keeps them in order.
    if ! "${MAKE:-make}" -k ${skip[@]+"${skip[@]}"} "$@" 2>&1 | tee "$log"; then
        # The load at the end of the check: make -k runs the later targets after a red test.
        load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
        errors="$(grep -E "$prefix\*\*\* " "$log" || true)"
        ours="$prefix\*\*\* \[(test|test-slow-push)\] Error"
        grep -qE "$ours" <<<"$errors" || no_rerun 'no red test or test-slow-push target'
        ! grep -vqE "$ours" <<<"$errors" || no_rerun 'a target other than test and test-slow-push failed'
        remade="$(grep -E 'not remade because of errors' "$log" || true)"
        [[ -z "$remade" ]] || ! grep -vqE "${prefix}Target [\`']check' not remade because of errors\.$" <<<"$remade" ||
            no_rerun 'a target other than check is not remade'
        reason="$(blocked "$log")"
        [[ -z "$reason" ]] || no_rerun "$reason"

        # Make writes the Error line of a target after its output, so the failed test lines before
        # the [test] Error line are fast tests, and those before the [test-slow-push] Error line are
        # slow.
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
        retry || { partial "$fast $word_fast" "$slow $word_slow"; exit 1; }
    fi
fi
if [[ -n $word ]]; then
    load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
    fast="$(once <<<"$word_fast")" slow="$(once <<<"$word_slow")"
    retry || { partial "$fast" "$slow"; exit 1; }
fi
exit 0
