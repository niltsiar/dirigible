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
}

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

[[ $failures -eq 0 ]] && echo "check-docs tests: all passed"
exit $((failures > 0))
