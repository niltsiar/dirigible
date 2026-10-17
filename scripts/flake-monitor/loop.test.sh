#!/bin/bash
# Check the summary line that loop.sh writes for one run, and the --min-load stop. Run by `make test-hooks`.
set -uo pipefail
loop="$(cd "$(dirname "$0")" && pwd)/loop.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

[[ $failures -eq 0 ]] && echo "loop tests: all passed"
exit $((failures > 0))
