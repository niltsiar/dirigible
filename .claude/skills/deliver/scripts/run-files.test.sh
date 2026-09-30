#!/bin/bash
# Check that log-decision.sh appends one row of six tab-separated columns from a five-line file
# (--from), changes a tab in a field to a space, refuses a file with four lines and appends
# nothing, and keeps the six-argument form. Run by `make test-hooks`.
set -uo pipefail
log="$(cd "$(dirname "$0")" && pwd)/log-decision.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
run="$tmp/run"
mkdir "$run"
: > "$run/decisions.tsv"

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# The last row has six columns, a ts from the clock, and the expected fields.
check_row() {
  local name="$1" want="$2" row
  row="$(tail -n 1 "$run/decisions.tsv")"
  [[ "$(awk -F'\t' '{print NF}' <<< "$row")" == 6 ]] || fail "$name: row has not six columns: $row"
  [[ "$(cut -f1 <<< "$row")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$ ]] || fail "$name: no ts: $row"
  [[ "$(cut -f2- <<< "$row")" == "$want" ]] || fail "$name: fields differ: $row"
}

printf 'implement\nuse make check && git commit\nwhy\nevidence\ndone\n' > "$tmp/five"
"$log" "$run" --from "$tmp/five" || fail "--from with five lines exits $?"
check_row '--from' $'implement\tuse make check && git commit\twhy\tevidence\tdone'
[[ "$(wc -l < "$run/decisions.tsv")" -eq 1 ]] || fail '--from did not append exactly one row'

printf 'implement\na\tb\nwhy\nevidence\ndone\n' > "$tmp/tab"
"$log" "$run" --from "$tmp/tab" || fail "--from with a tab exits $?"
check_row 'a tab in a field' $'implement\ta b\twhy\tevidence\tdone'

before="$(shasum -a 256 "$run/decisions.tsv")"
printf 'implement\ndecision\nwhy\nevidence\n' > "$tmp/four"
err="$("$log" "$run" --from "$tmp/four" 2>&1)"
code=$?
[[ $code -eq 2 ]] || fail "four lines: expected exit 2, got $code"
[[ "$err" == *"five lines"* ]] || fail "four lines: no reason in the message: $err"
[[ "$(shasum -a 256 "$run/decisions.tsv")" == "$before" ]] || fail 'four lines: decisions.tsv changed'

"$log" "$run" plan decision why evidence done || fail "six arguments exit $?"
check_row 'six arguments' $'plan\tdecision\twhy\tevidence\tdone'

[[ $failures -eq 0 ]] && echo "run-files tests: all passed"
exit $((failures > 0))
