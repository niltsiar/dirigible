#!/bin/bash
# Check that check-plan.sh exits 1 and names the failure for a run folder with no Unknowns table,
# an open Unknowns row, a split row with no child row, a slice with no check line, or a plan with
# no Agents: line, and exits 0 for a good folder and for a user row answered with a default.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/check-plan.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

run="$tmp/run"
# A good run folder: each Unknowns row is answered with a row time, the split row has a child, a
# cell has an escaped bar, and each slice has a check line.
good() {
  rm -rf "$run"
  mkdir "$run"
  cat > "$run/analysis.md" <<'EOF'
# Analysis: x

## Unknowns

| id | parent | question | resolver | answer | row |
|---|---|---|---|---|---|
| U1 | - | Where does the stamp live? | default | In the git dir. Reverse: say in the tree. | 2026-10-01T17:18 |
| U2 | - | How does the filter read `A\|B`? | split | Two child rows. | 2026-10-01T17:19 |
| U3 | U2 | Does swift take two flags? | probe | Yes (logs/p.log). | 2026-10-01T17:20 |

## Out of scope

- y
EOF
  cat > "$run/plan.md" <<'EOF'
# Plan: x

Agents: B = S1, S2 (serial: one index).

## Slices

### S1 one

- First test: a.
- Check: `targets: check-fast`.

### S2 two

- Check: `targets: check-docs`.

## Gates

### Not a slice

- No check line here.
EOF
}

# pass <name>: exit 0. refuse <name> <reason>: exit 1 and the reason in the output.
pass() {
  local out
  out="$("$script" "$run" 2>&1)" || fail "$1: expected exit 0: $out"
}
refuse() {
  local out code
  out="$("$script" "$run" 2>&1)"
  code=$?
  [[ $code -eq 1 ]] || fail "$1: expected exit 1, got $code: $out"
  [[ "$out" == *"$2"* ]] || fail "$1: no '$2' in: $out"
}

good
pass 'all good'

good
sed -i '' '/^## Unknowns/,/^## Out/{/^|/d;}' "$run/analysis.md"
refuse 'an Unknowns heading with no table' 'no ## Unknowns table'
good
sed -i '' 's/^## Unknowns/## Open questions/' "$run/analysis.md"
refuse 'no Unknowns table' 'no ## Unknowns table'

good
sed -i '' 's/| Yes (logs\/p.log). | 2026-10-01T17:20 |/|  | 2026-10-01T17:20 |/' "$run/analysis.md"
refuse 'a row with no answer' 'open unknown: | U3 | U2 | Does swift take two flags?'
good
sed -i '' 's/| Yes (logs\/p.log). | 2026-10-01T17:20 |/| Yes. | - |/' "$run/analysis.md"
refuse 'a row with no row time' 'open unknown: | U3 |'

good
sed -i '' '/^| U3 /d' "$run/analysis.md"
refuse 'a split row with no child' 'split unknown U2 has no child row'

good
sed -i '' '/^- Check: `targets: check-docs`/d' "$run/plan.md"
refuse 'a slice with no check line' 'slice "### S2 two" has no "- Check:" line'
out="$("$script" "$run" 2>&1)"
[[ "$out" != *'S1 one'* && "$out" != *'Not a slice'* ]] || fail "a slice with no check line: another heading is named: $out"

good
sed -i '' '/^Agents:/d' "$run/plan.md"
refuse 'no Agents: line' 'plan.md has no Agents: line'

good
printf '| U4 | - | Which color? | user | Default: blue, logged. Reverse: say red. | 2026-10-01T17:21 |\n' > "$tmp/u4"
sed -i '' "/^| U3 /r $tmp/u4" "$run/analysis.md"
pass 'a user row answered with a default'

good
rm "$run/plan.md"
refuse 'no plan.md' 'no plan.md'

out="$("$script" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "no argument: exit $code: $out"

[[ $failures -eq 0 ]] && echo "check-plan tests: all passed"
exit $((failures > 0))
