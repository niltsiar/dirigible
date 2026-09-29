#!/bin/bash
# Check the summary line that loop.sh writes for one run. Run by `make test-hooks`.
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
FLAKE-MONITOR worst pool 1.20 s, worst main 3.40 s, samples 1, start 1000012
LOG
want="t 3 exit=1 wall=150s load=2.50 monitor-start=+12s banner=74.400s settle=16.679s waits=[until=12.5 AsyncGate.wait=2.1] children=16 monitor=[worst pool 1.20 s, worst main 3.40 s, samples 1] failed=[settleEndsATakeWhileAPassWaits]"
out="$("$loop" --summary t 3 1 150 2.50 1000000 "$tmp/run.log" 2>&1)"
[[ "$out" == "$want" ]] || { echo "FAIL: the summary line of one run: $out"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "loop tests: all passed"
exit $((failures > 0))
