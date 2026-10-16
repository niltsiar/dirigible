#!/bin/bash
# Check the mode that usage-mode.sh prints for a fixture limits.json and a fixed clock: the
# thresholds at both sides (75 % save; 60 min and 70 % spend), a past reset (normal), a file
# older than 15 min with a future reset (save), the seven_day row ignored, and no file or no
# five_hour row (normal). Run by `make test-hooks`.
set -uo pipefail
mode="$(cd "$(dirname "$0")" && pwd)/usage-mode.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

now=1792000000 # a fixed clock, in seconds
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# limits <percent> <reset in min from now> <age of the file in min> [<seven_day percent>]
limits() {
  printf '{"written_at":%s,"session_id":"s","rate_limits":[{"kind":"seven_day","percentUsed":%s,"resetsAt":"%s"},{"kind":"five_hour","percentUsed":%s,"resetsAt":"%s"}]}\n' \
    $(((now - $3 * 60) * 1000)) "${4:-5}" "$(iso $((now + 99999)))" "$1" "$(iso $((now + $2 * 60)))" > "$tmp/limits.json"
}
# expect <label> <mode>
expect() {
  local out
  out="$(USAGE_LIMITS_FILE="$tmp/limits.json" USAGE_MODE_NOW=$now "$mode" 2>&1)"
  [[ "$out" == "$2" ]] || fail "$1: expected '$2', got '$out'"
}

limits 75 120 0; expect "75 % with 120 min left" save
limits 74 120 0; expect "74 % with 120 min left" normal
limits 70 60 0; expect "70 % with 60 min left" spend
limits 70 61 0; expect "70 % with 61 min left" normal
limits 71 30 0; expect "71 % with 30 min left" normal
limits 80 30 0; expect "80 % with 30 min left: save wins" save
limits 0 30 0; expect "0 % with 30 min left" spend
limits 90 -10 0; expect "90 % with a reset 10 min in the past" normal
limits 20 120 15; expect "a file of exactly 15 min" normal
limits 20 120 16; expect "a file of 16 min with a future reset" save
limits 20 -10 16; expect "a file of 16 min with a past reset" normal
limits 20 120 0 99; expect "a seven_day row of 99 %" normal

printf '{"written_at":%s,"rate_limits":[{"kind":"seven_day","percentUsed":99,"resetsAt":"%s"}]}\n' \
  $((now * 1000)) "$(iso $((now + 600)))" > "$tmp/limits.json"
expect "no five_hour row" normal

rm "$tmp/limits.json"
expect "no file" normal

[[ $failures -eq 0 ]] && echo "usage-mode tests: all passed"
exit $((failures > 0))
