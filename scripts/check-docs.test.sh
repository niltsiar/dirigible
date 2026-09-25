#!/bin/bash
# Check that check-docs.sh passes a good docs tree and fails each broken one. Run by `make check`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-docs.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A minimal good tree: one research file, a brief with R1 and R10, releases for both, one accepted record.
good() {
  rm -rf "$tmp/docs"
  mkdir -p "$tmp/docs/research" "$tmp/docs/requirements" "$tmp/docs/decisions"
  printf '# Topic\n\nDate: 2026-09-24\n\n## Sources\n\n- x\n' > "$tmp/docs/research/topic.md"
  printf '| ID | Requirement |\n|---|---|\n| R1 | One. |\n| R10 | Ten. |\n\n## Answered questions\n\n- Q? See [0002](../decisions/0002-x.md).\n' > "$tmp/docs/requirements/brief.md"
  printf '| Requirement | What |\n|---|---|\n| R1 | a |\n| R10 | b |\n' > "$tmp/docs/requirements/releases.md"
  printf '# 0002. X\n\n- Status: accepted\n' > "$tmp/docs/decisions/0002-x.md"
  printf '| Command | What |\n|---|---|\n| `make test` | a |\n| `make bench FILTER=<test>` | b |\n' > "$tmp/AGENTS.md"
  printf 'test:\n\tswift test\n\nbench:\n\tscripts/bench.sh\n' > "$tmp/Makefile"
}

expect() {
  local want="$1" name="$2" got
  "$check" "$tmp" >/dev/null 2>&1 && got=pass || got=fail
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

good; expect pass 'good tree'
good; printf '# Topic\n\n## Sources\n' > "$tmp/docs/research/topic.md"; expect fail 'research file without a date'
good; printf '# Topic\n\nDate: 2026-09-24\n' > "$tmp/docs/research/topic.md"; expect fail 'research file without sources'
good; printf '| R10 | b |\n' > "$tmp/docs/requirements/releases.md"; expect fail 'R1 missing while R10 stays'
good; printf '| R10 | b |\nR1 is the product.\n' > "$tmp/docs/requirements/releases.md"; expect fail 'R1 only in prose, not in a release row'
good; printf '| R1-R10 | all |\n' > "$tmp/docs/requirements/releases.md"; expect fail 'a range only'
good; printf '|R1| One. |\n' > "$tmp/docs/requirements/brief.md"; expect fail 'brief with no answered questions'
good; printf '|  R1  | One. |\n\n## Answered questions\n\n- Q? See [x](releases.md).\n' > "$tmp/docs/requirements/brief.md"
printf '| R10 | b |\n' > "$tmp/docs/requirements/releases.md"; expect fail 'brief row with other spacing'
good; printf 'No table.\n\n## Answered questions\n\n- Q? See [x](releases.md).\n' > "$tmp/docs/requirements/brief.md"; expect fail 'brief with no requirement IDs'
good; sed -i '' 's/0002-x.md/0099-missing.md/' "$tmp/docs/requirements/brief.md"; expect fail 'link to a missing file'
good; sed -i '' 's/(\.\.\/decisions/(..\/decisions/' "$tmp/docs/requirements/brief.md"
printf -- '- Q2? No link.\n' >> "$tmp/docs/requirements/brief.md"; expect fail 'answered question without a link'
good; printf '# 0002. X\n\n- Status: proposed\n' > "$tmp/docs/decisions/0002-x.md"; expect fail 'record not accepted'
good; printf '# 0002. X\n\n- Status: superseded\n\nOld text:\n- Status: accepted\n' > "$tmp/docs/decisions/0002-x.md"; expect fail 'second status line says accepted'
good; printf '| `make test` | again |\n' >> "$tmp/AGENTS.md"; expect fail 'two AGENTS.md rows for one make target'
good; printf '| `make lint` | c |\n' >> "$tmp/AGENTS.md"; expect fail 'AGENTS.md row with no Makefile target'

[[ $failures -eq 0 ]] && echo "check-docs tests: all passed"
exit $((failures > 0))
