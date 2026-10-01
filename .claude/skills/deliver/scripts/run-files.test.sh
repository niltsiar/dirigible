#!/bin/bash
# Check that log-decision.sh appends one row of six tab-separated columns from a five-line file
# (--from), changes a tab in a field to a space, refuses a file with four lines and appends
# nothing, and keeps the six-argument form. Check that new-run.sh reports the backlog sections.
# Run by `make test-hooks`.
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

# new-run.sh reports the backlog sections on stderr and keeps stdout to the run folder. It warns
# when ## Next is over 1000 words, writes `- Later items: <n>` in the new run.md, and prints the
# Later count with the change from the `Later items:` line of the last run.md.
new_run="$(dirname "$log")/new-run.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$tmp/repo"
mkdir -p "$repo/.scratchpads/runs/2026-01-01-old"
git -C "$repo" init -q
words="$(printf 'w%.0s ' $(seq 1000))"
printf '# Backlog\n\n## Next\n\n- %s\n\n## Later\n\n- a\n- b\n\n### From run x\n\n- c\n' "$words" > "$repo/.scratchpads/backlog.md"
printf '# Run 2026-01-01-old\n\n- Later items: 1\n' > "$repo/.scratchpads/runs/2026-01-01-old/run.md"
out="$(cd "$repo" && "$new_run" big 2> "$tmp/err")" || fail "new-run with a long ## Next exits $?"
dir="$repo/.scratchpads/runs/$(date +%Y-%m-%d)-big"
[[ "$out" == "$(cd "$repo" && pwd -P)/.scratchpads/runs/$(date +%Y-%m-%d)-big" ]] || fail "new-run stdout is not the run folder: $out"
grep -q '## Next.*1001 words' "$tmp/err" || fail "no warning that names ## Next and 1001 words: $(cat "$tmp/err")"
grep -qx -- '- Later items: 3' "$dir/run.md" || fail "run.md has no '- Later items: 3' line"
grep -q '## Later has 3 items (+2 since 2026-01-01-old)' "$tmp/err" || fail "no Later count with the change: $(cat "$tmp/err")"

printf '# Backlog\n\n## Next\n\n- short\n\n## Later\n\n- a\n' > "$repo/.scratchpads/backlog.md"
rm -r "$dir"
printf '# Run 2026-01-01-old\n' > "$repo/.scratchpads/runs/2026-01-01-old/run.md"
(cd "$repo" && "$new_run" small > /dev/null 2> "$tmp/err") || fail "new-run with a short ## Next exits $?"
grep -q 'Next' "$tmp/err" && fail "warning for a short ## Next: $(cat "$tmp/err")"
grep -qx 'backlog: ## Later has 1 items' "$tmp/err" || fail "no Later count without a last count: $(cat "$tmp/err")"

[[ $failures -eq 0 ]] && echo "run-files tests: all passed"
exit $((failures > 0))
