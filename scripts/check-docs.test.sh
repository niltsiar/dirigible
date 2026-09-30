#!/bin/bash
# Check that check-docs.sh passes a good docs tree and fails each broken one. Run by `make check`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-docs.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A minimal good tree: one research file, a brief with R1 and R10, releases for both, one accepted record,
# three menu names in English and Spanish, a guide with each name in bold, and a README with an image.
good() {
  rm -rf "$tmp/docs" "$tmp/Support" "$tmp/README.md" "$tmp/.claude"
  mkdir -p "$tmp/docs/research" "$tmp/docs/requirements" "$tmp/docs/decisions" "$tmp/docs/images" \
    "$tmp/Support/Resources/en.lproj" "$tmp/Support/Resources/es.lproj"
  printf '# Topic\n\nDate: 2026-09-24\n\n## Sources\n\n- x\n' > "$tmp/docs/research/topic.md"
  printf '| ID | Requirement |\n|---|---|\n| R1 | One. |\n| R10 | Ten. |\n\n## Answered questions\n\n- Q? See [0002](../decisions/0002-x.md).\n' > "$tmp/docs/requirements/brief.md"
  printf '| Requirement | What |\n|---|---|\n| R1 | a |\n| R10 | b |\n' > "$tmp/docs/requirements/releases.md"
  printf '# 0002. X\n\n- Status: accepted\n' > "$tmp/docs/decisions/0002-x.md"
  printf '| Command | What |\n|---|---|\n| `make test` | a |\n| `make bench FILTER=<test>` | b |\n' > "$tmp/AGENTS.md"
  printf 'test:\n\tswift test\n\nbench:\n\tscripts/bench.sh\n' > "$tmp/Makefile"
  printf '"menu.file.export" = "Export…";\n"menu.edit.cut" = "Cut";\n"menu.markers" = "Markers";\n"other" = "Other";\n' \
    > "$tmp/Support/Resources/en.lproj/Localizable.strings"
  printf '"menu.file.export" = "Exportar…";\n"menu.edit.cut" = "Cortar";\n"menu.markers" = "Marcadores";\n' \
    > "$tmp/Support/Resources/es.lproj/Localizable.strings"
  printf '# Guide\n\n### What Dirigible does not do yet\n\n**Export** **Exportar** **Cut** **Cortar** **Markers** **Marcadores**\n\nSee [the README](../README.md), [the top](#guide), and [Apple](https://www.apple.com).\n' \
    > "$tmp/docs/guide.md"
  : > "$tmp/docs/images/x.png"
  printf '<picture><source srcset="docs/images/x.png"><img src="docs/images/x.png" alt="x"></picture>\n\nSee [the guide](docs/guide.md) and [what it does not do](docs/guide.md#what-dirigible-does-not-do-yet).\n' \
    > "$tmp/README.md"
  mkdir -p "$tmp/.claude/workflows" "$tmp/.claude/agents"
  printf "const LENSES = [\n  { key: 'x', agentType: 'x-reviewer', gates: ['diff'] },\n]\nagent(task, { agentType: lens.agentType })\n" \
    > "$tmp/.claude/workflows/review-panel.js"
  printf -- '---\nname: x-reviewer\ndescription: X.\n---\n\nBody.\n' > "$tmp/.claude/agents/x-reviewer.md"
  mkdir -p "$tmp/.claude/skills/s/references" "$tmp/docs/workflow"
  printf -- '---\nname: s\n---\n\nRead `references/r.md` when you need the detail.\n' > "$tmp/.claude/skills/s/SKILL.md"
  printf '# R\n\nDetail.\n' > "$tmp/.claude/skills/s/references/r.md"
  printf 'path\twords\tdecision\n' > "$tmp/docs/workflow/budgets.tsv"
  printf '%s\t1000\tbaseline\n' AGENTS.md .claude/agents/x-reviewer.md \
    .claude/skills/s/SKILL.md .claude/skills/s/references/r.md >> "$tmp/docs/workflow/budgets.tsv"
  printf '.claude/skills/s/\t5000\tbaseline\nTOTAL\t10000\tbaseline\n' >> "$tmp/docs/workflow/budgets.tsv"
  printf 'id\tfile\tverdict\ttarget\treason\tsource\tkey\tsummary\n%s\n%s\n' \
    'AGT-001	AGENTS.md	keep	AGENTS.md	scope	10edc92		product scope' \
    'AGT-002	AGENTS.md	merge	AGT-001	duplicate	L12	AGT-001/doc	scope again' > "$tmp/docs/workflow/rules.tsv"
}

# Append one row to the rule register.
rule() { printf '%s\n' "$1" >> "$tmp/docs/workflow/rules.tsv"; }

# Set the words cell of the budget row of <path> to <n>.
budget() { sed -i '' "s|^$1	[0-9]*	|$1	$2	|" "$tmp/docs/workflow/budgets.tsv"; }
# Write a references file of <n> lines, with an optional first line.
long_ref() { { [[ -n "${2:-}" ]] && echo "$2"; for _ in $(seq "$1"); do echo x; done; } > "$tmp/.claude/skills/s/references/r.md"; }

# expect pass <name>, or expect fail <name> <message>. A failure counts only with its rule
# message, so a fixture that breaks another rule cannot pass as the refused case.
expect() {
  local want="$1" name="$2" message="${3:-}" got output
  output="$("$check" "$tmp" 2>&1 >/dev/null)" && got=pass || got=fail
  if [[ "$got" == fail && "$want" == fail ]] && ! grep -qF "check-docs: $message" <<<"$output"; then
    got="fail without '$message'"
  fi
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

good; expect pass 'good tree'
good; printf '# Topic\n\n## Sources\n' > "$tmp/docs/research/topic.md"; expect fail 'research file without a date' "docs/research/topic.md: no 'Date: YYYY-MM-DD' line"
good; printf '# Topic\n\nDate: 2026-09-24\n' > "$tmp/docs/research/topic.md"; expect fail 'research file without sources' "docs/research/topic.md: no '## Sources' section"
good; printf '| R10 | b |\n' > "$tmp/docs/requirements/releases.md"; expect fail 'R1 missing while R10 stays' 'releases.md: no release row for R1'
good; printf '| R10 | b |\nR1 is the product.\n' > "$tmp/docs/requirements/releases.md"; expect fail 'R1 only in prose, not in a release row' 'releases.md: no release row for R1'
good; printf '| R1-R10 | all |\n' > "$tmp/docs/requirements/releases.md"; expect fail 'a range only' 'releases.md: no release row for R1'
good; printf '|R1| One. |\n' > "$tmp/docs/requirements/brief.md"; expect fail 'brief with no answered questions' "brief.md: no '## Answered questions' section"
good; printf '|  R1  | One. |\n\n## Answered questions\n\n- Q? See [x](releases.md).\n' > "$tmp/docs/requirements/brief.md"
printf '| R10 | b |\n' > "$tmp/docs/requirements/releases.md"; expect fail 'brief row with other spacing' 'releases.md: no release row for R1'
good; printf 'No table.\n\n## Answered questions\n\n- Q? See [x](releases.md).\n' > "$tmp/docs/requirements/brief.md"; expect fail 'brief with no requirement IDs' 'brief.md: no requirement rows'
good; sed -i '' 's/0002-x.md/0099-missing.md/' "$tmp/docs/requirements/brief.md"; expect fail 'link to a missing file' 'brief.md: link to a missing file'
good; sed -i '' 's/(\.\.\/decisions/(..\/decisions/' "$tmp/docs/requirements/brief.md"
printf -- '- Q2? No link.\n' >> "$tmp/docs/requirements/brief.md"; expect fail 'answered question without a link' 'brief.md: answered question has no link'
good; printf '# 0002. X\n\n- Status: proposed\n' > "$tmp/docs/decisions/0002-x.md"; expect fail 'record not accepted' 'brief.md: ../decisions/0002-x.md is not accepted'
good; printf '# 0002. X\n\n- Status: superseded\n\nOld text:\n- Status: accepted\n' > "$tmp/docs/decisions/0002-x.md"; expect fail 'second status line says accepted' 'brief.md: ../decisions/0002-x.md is not accepted'
good; printf '| `make test` | again |\n' >> "$tmp/AGENTS.md"; expect fail 'two AGENTS.md rows for one make target' 'AGENTS.md: more than one row for make test'
good; printf '| `make lint` | c |\n' >> "$tmp/AGENTS.md"; expect fail 'AGENTS.md row with no Makefile target' 'AGENTS.md: row for make lint, but the Makefile has no lint target'
good; sed -i '' 's/\*\*Cut\*\* //' "$tmp/docs/guide.md"; expect fail 'English menu name missing' 'docs/guide.md: no **Cut** (en menu name)'
good; sed -i '' 's/\*\*Cortar\*\* //' "$tmp/docs/guide.md"; expect fail 'Spanish menu name missing' 'docs/guide.md: no **Cortar** (es menu name)'
good; printf '"menu.view.zoom.selection" = "Zoom to Selection or Session";\n' >> "$tmp/Support/Resources/en.lproj/Localizable.strings"
printf '**Zoom to Selection**\n' >> "$tmp/docs/guide.md"; expect fail 'renamed menu name' 'docs/guide.md: no **Zoom to Selection or Session** (en menu name)'
good; rm "$tmp/docs/guide.md"; expect fail 'no guide' 'docs/guide.md is missing'
good; sed -i '' 's/src="docs\/images\/x.png"/src="docs\/images\/light.png"/' "$tmp/README.md"; expect fail 'missing src file' 'README.md: link to a missing file: docs/images/light.png'
good; sed -i '' 's/srcset="docs\/images\/x.png"/srcset="docs\/images\/dark.png"/' "$tmp/README.md"; expect fail 'missing srcset file' 'README.md: link to a missing file: docs/images/dark.png'
good; printf '[x](missing.md)\n' >> "$tmp/docs/guide.md"; expect fail 'missing link target in the guide' 'docs/guide.md: link to a missing file: missing.md'
good; printf '![x](docs/images/X.png)\n' >> "$tmp/README.md"; expect fail 'link with the wrong case' 'README.md: link to a missing file: docs/images/X.png'
good; printf '[x](docs/guide.md#no-such-heading)\n' >> "$tmp/README.md"; expect fail 'README link to a missing heading' 'README.md: no heading for #no-such-heading in docs/guide.md'
good; printf '[x](#no-such-heading)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a missing heading' 'docs/guide.md: no heading for #no-such-heading in docs/guide.md'
good; printf '[x](../README.md#no-such-heading)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a missing README heading' 'docs/guide.md: no heading for #no-such-heading in README.md'
good; printf '[x](../README.md#what-dirigible-does-not-do-yet)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a heading of the guide, not of the README' 'docs/guide.md: no heading for #what-dirigible-does-not-do-yet in README.md'
good; printf '# Readme\n\n## Install\n' >> "$tmp/README.md"; printf '[x](../README.md#install)\n' >> "$tmp/docs/guide.md"; expect pass 'guide link to a README heading'
good; rm "$tmp/.claude/agents/x-reviewer.md"; expect fail 'panel agentType with no agent file' 'review-panel.js: agentType x-reviewer has no .claude/agents/x-reviewer.md'
good; sed -i '' 's/^name: x-reviewer$/name: y-reviewer/' "$tmp/.claude/agents/x-reviewer.md"; expect fail 'agent file with another name' "review-panel.js: .claude/agents/x-reviewer.md has no 'name: x-reviewer' in its frontmatter"
good; printf -- '---\ndescription: X.\n---\n\nname: x-reviewer\n' > "$tmp/.claude/agents/x-reviewer.md"; expect fail 'name only in the body' "review-panel.js: .claude/agents/x-reviewer.md has no 'name: x-reviewer' in its frontmatter"
good; sed -i '' "s/agentType: 'x-reviewer'/agentType: \"x-reviewer\"/" "$tmp/.claude/workflows/review-panel.js"; expect pass 'agentType in double quotes'
good; sed -i '' "s/agentType: 'x-reviewer'/agentType: name/" "$tmp/.claude/workflows/review-panel.js"; expect fail 'panel with no literal agentType' 'review-panel.js: no literal agentType'
good; budget AGENTS.md 1; expect fail 'file over its budget row' 'budgets.tsv: AGENTS.md is over its row'
good; sed -i '' '/^\.claude\/skills\/s\/SKILL\.md	/d' "$tmp/docs/workflow/budgets.tsv"; expect fail 'SKILL.md with no budget row' 'budgets.tsv: no row for .claude/skills/s/SKILL.md'
good; sed -i '' '/^\.claude\/skills\/s\/references\/r\.md	/d' "$tmp/docs/workflow/budgets.tsv"; expect fail 'references file with no budget row' 'budgets.tsv: no row for .claude/skills/s/references/r.md'
good; sed -i '' '/^\.claude\/agents\/x-reviewer\.md	/d' "$tmp/docs/workflow/budgets.tsv"; expect fail 'agent file with no budget row' 'budgets.tsv: no row for .claude/agents/x-reviewer.md'
good; printf '.claude/skills/gone/SKILL.md\t100\tbaseline\n' >> "$tmp/docs/workflow/budgets.tsv"; expect fail 'budget row for a missing file' 'budgets.tsv: row for a missing file: .claude/skills/gone/SKILL.md'
good; budget .claude/skills/s/ 5; expect fail 'skill folder over its total row' 'budgets.tsv: .claude/skills/s/ is over its total row'
good; budget TOTAL 5; expect fail 'all budgeted files over the TOTAL row' 'budgets.tsv: the budgeted files are over the TOTAL row'
good; sed -i '' '/^TOTAL	/d' "$tmp/docs/workflow/budgets.tsv"; expect fail 'no TOTAL row' 'budgets.tsv: no TOTAL row'
good; sed -i '' 's|^AGENTS.md	1000	baseline$|AGENTS.md	1000	|' "$tmp/docs/workflow/budgets.tsv"; expect fail 'budget row with an empty decision' 'budgets.tsv: the row for AGENTS.md has no decision'
good; sed -i '' 's|references/r.md|the reference|' "$tmp/.claude/skills/s/SKILL.md"; expect fail 'references file not named by its SKILL.md' '.claude/skills/s/references/r.md: .claude/skills/s/SKILL.md does not name it by path'
good; long_ref 101; expect fail 'long references file with no contents list' '.claude/skills/s/references/r.md: over 100 lines with no contents list in its first 10 lines'
good; long_ref 101 '## Contents'; expect pass 'long references file with a contents list'
good; long_ref 100; expect pass 'references file of 100 lines with no contents list'
good; rule 'AGT-001	AGENTS.md	keep	AGENTS.md	scope	10edc92		scope twice'; expect fail 'register with a duplicate ID' 'rules.tsv: duplicate id AGT-001'
good; rule 'AGT-003	AGENTS.md	branch	AGENTS.md	scope	10edc92		scope'; expect fail 'register with a bad verdict' 'rules.tsv: AGT-003 has verdict branch'
good; rule 'AGT-003	AGENTS.md	merge	AGT-999	duplicate	10edc92		scope'; expect fail 'register merge to an unknown ID' 'rules.tsv: AGT-003 merges into an unknown id AGT-999'
good; rule 'AGT-003	AGENTS.md	delete			10edc92		scope'; expect fail 'register delete with no reason' 'rules.tsv: AGT-003 is delete with no reason'
good; rule 'AGT-003	AGENTS.md	keep	AGENTS.md	scope			scope'; expect fail 'register row with no source' 'rules.tsv: AGT-003 has no source'
good; rm "$tmp/docs/workflow/rules.tsv"; expect fail 'no register' 'docs/workflow/rules.tsv is missing'
good; sed -i '' '1s/$/	text/' "$tmp/docs/workflow/rules.tsv"; expect fail 'register with a text column' 'rules.tsv: the header is not'

[[ $failures -eq 0 ]] && echo "check-docs tests: all passed"
exit $((failures > 0))
