#!/bin/bash
# Check the summary line that loop.sh writes for one run, the --min-load stop, --filter (make
# test-filter in place of make test), the exports to make test, and the hold limit that the loop sets for its own take of the lock. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The loop takes the lock itself, so a copy in a temporary repo keeps the test off the real lock.
unset DIRIGIBLE_BUILD_LOCK DIRIGIBLE_LOCKED_SCRIPT WITH_LOCK_MAX_WAIT WITH_LOCK_MAX_HOLD
export WITH_LOCK_RETRY=0.1
repo="$tmp/repo"
mkdir -p "$repo/scripts/flake-monitor"
cp "$here/../with-lock.sh" "$here/../lock-words.sh" "$repo/scripts/"
cp "$here/loop.sh" "$repo/scripts/flake-monitor/loop.sh"
git -C "$repo" init -q
loop="$repo/scripts/flake-monitor/loop.sh"
holds="$repo/.git/dirigible-build-holds.log"

cat > "$tmp/run.log" <<'LOG'
WAIT until 3.2 s the window did not open
WAIT until 12.5 s the subtitle did not change
WAIT AsyncGate.wait 2.1 s AsyncGate
CLI-CHILDREN peak 9
CLI-CHILDREN peak 16
✔ Test theWindowSubtitleFollowsTheTracks() passed after 74.400 seconds.
✘ Test settleEndsATakeWhileAPassWaits() recorded an issue at StudioPeaksSettleTests.swift:68:9: Issue recorded
✘ Test settleEndsATakeWhileAPassWaits() failed after 16.679 seconds with 1 issue.
✘ Test aGateOnAPoolThreadIsAnIssue() recorded a known issue at Support.swift:273:25: Issue recorded
✘ Test aGateOnAPoolThreadIsAnIssue() passed after 0.226 seconds with 1 known issue.
FLAKE-MONITOR worst pool 1.20 s, worst main 3.40 s, samples 1, start 1000012
LOG
want="t 3 exit=1 wall=150s load=2.50 monitor-start=+12s banner=74.400s settle=16.679s waits=[until=12.5 AsyncGate.wait=2.1] children=16 monitor=[worst pool 1.20 s, worst main 3.40 s, samples 1] failed=[settleEndsATakeWhileAPassWaits]"
out="$("$loop" --summary t 3 1 150 2.50 1000000 "$tmp/run.log" 2>&1)"
[[ "$out" == "$want" ]] || { echo "FAIL: the summary line of one run: $out"; failures=$((failures + 1)); }

# A loop under a load source stops before make test when the load is below the minimum.
msg="$("$loop" --min-load 1000 t 1 1 "$tmp/out" "$tmp" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 3 && "$msg" == *"below the minimum 1000 before run 1"* && ! -e "$tmp/out/t-1.log" ]] \
    || { echo "FAIL: --min-load 1000 did not stop the loop before run 1 (exit $code): $msg"; failures=$((failures + 1)); }

# Each make test of the loop runs with WITH_LOCK_MAX_WAIT=0, so a lock wait in a run never ends in
# exit 75 and never counts as a failed run.
mkdir "$tmp/stub"
printf 'test:\n\t@echo "limit=$$WITH_LOCK_MAX_WAIT"\n' > "$tmp/stub/Makefile"
WITH_LOCK_MAX_WAIT=5 "$loop" t 1 1 "$tmp/out10" "$tmp/stub" > /dev/null 2>&1
[[ "$(cat "$tmp/out10/t-1.log" 2>/dev/null)" == "limit=0" ]] \
    || { echo "FAIL: the loop does not export WITH_LOCK_MAX_WAIT=0 to make test: $(cat "$tmp/out10/t-1.log" 2>/dev/null)"; failures=$((failures + 1)); }

# The loop runs the full suite on purpose, so make test gets DIRIGIBLE_FULL_SUITE=1 (the refusal of
# test-shards.sh for a bare call).
printf 'test:\n\t@echo "suite=$$DIRIGIBLE_FULL_SUITE"\n' > "$tmp/stub/Makefile"
env -u DIRIGIBLE_FULL_SUITE "$loop" t 1 1 "$tmp/out11" "$tmp/stub" > /dev/null 2>&1
[[ "$(cat "$tmp/out11/t-1.log" 2>/dev/null)" == "suite=1" ]] \
    || { echo "FAIL: the loop does not export DIRIGIBLE_FULL_SUITE=1 to make test: $(cat "$tmp/out11/t-1.log" 2>/dev/null)"; failures=$((failures + 1)); }

# The loop takes the lock once, with a hold limit of its run count times 2 times the newest push-check
# hold, at least 3600 s. A make test that prints the limit in the lock folder shows it.
printf 'test:\n\t@cat "%s/dirigible-build.lock/maxhold"\n' "$repo/.git" > "$tmp/stub/Makefile"
limit() { rm -rf "$tmp/outh"; "$loop" t 1 "$1" "$tmp/outh" "$tmp/stub" > /dev/null 2>&1; cat "$tmp/outh/t-$1.log" 2>/dev/null; }
got="$(limit 1)"
[[ "$got" == 3600 ]] || { echo "FAIL: the hold limit of a 1-run loop with no history: [$got]"; failures=$((failures + 1)); }
printf '2026-10-17T10:00:00\t6000\tmake check-changed BASE=origin/main\t/t/a\n' > "$holds"
got="$(limit 1)"
[[ "$got" == 12000 ]] || { echo "FAIL: the hold limit of a 1-run loop, newest push check 6000 s: [$got]"; failures=$((failures + 1)); }
got="$(limit 3)"
[[ "$got" == 36000 ]] || { echo "FAIL: the hold limit of a 3-run loop, newest push check 6000 s: [$got]"; failures=$((failures + 1)); }

# A caller that holds the lock already (the nested path) runs the loop at once under its own limit.
rm -rf "$tmp/outh"
out="$("$repo/scripts/with-lock.sh" "$loop" t 1 1 "$tmp/outh" "$tmp/stub" 2>&1)"
code=$?
[[ $code -eq 0 && "$(cat "$tmp/outh/t-1.log" 2>/dev/null)" == 1800 ]] \
    || { echo "FAIL: the loop under an outer with-lock.sh call: exit $code, limit [$(cat "$tmp/outh/t-1.log" 2>/dev/null)]: $out"; failures=$((failures + 1)); }

# --filter '<names>' runs make test-filter FILTER='<names>' in place of make test, with the same
# exports; no --filter runs make test.
printf 'test:\n\t@echo "goal=test"\ntest-filter:\n\t@echo "goal=filter FILTER=$(FILTER) suite=$$DIRIGIBLE_FULL_SUITE limit=$$WITH_LOCK_MAX_WAIT"\n' > "$tmp/stub/Makefile"
"$loop" --filter 'ATests BTests/b1' t 1 1 "$tmp/out12" "$tmp/stub" > /dev/null 2>&1
[[ "$(cat "$tmp/out12/t-1.log" 2>/dev/null)" == "goal=filter FILTER=ATests BTests/b1 suite=1 limit=0" ]] \
    || { echo "FAIL: --filter does not run make test-filter: $(cat "$tmp/out12/t-1.log" 2>/dev/null)"; failures=$((failures + 1)); }
"$loop" t 1 1 "$tmp/out13" "$tmp/stub" > /dev/null 2>&1
[[ "$(cat "$tmp/out13/t-1.log" 2>/dev/null)" == "goal=test" ]] \
    || { echo "FAIL: no --filter does not run make test: $(cat "$tmp/out13/t-1.log" 2>/dev/null)"; failures=$((failures + 1)); }
"$loop" --min-load 0 --filter 'CTests' t 1 1 "$tmp/out14" "$tmp/stub" > /dev/null 2>&1
[[ "$(cat "$tmp/out14/t-1.log" 2>/dev/null)" == "goal=filter FILTER=CTests suite=1 limit=0" ]] \
    || { echo "FAIL: --min-load then --filter: $(cat "$tmp/out14/t-1.log" 2>/dev/null)"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "loop tests: all passed"
exit $((failures > 0))
