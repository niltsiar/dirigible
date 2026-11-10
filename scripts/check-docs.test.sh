#!/bin/bash
# Check that check-docs.sh passes a good docs tree and fails each broken one. Run by `make check`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-docs.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# One compiled converter for every case: `swift guide-html.swift` takes about 1 s per case.
swiftc -O "$(dirname "$check")/guide-html.swift" -o "$tmp/guide-html" || exit 1
export GUIDE_HTML="$tmp/guide-html"

# A minimal good tree: one research file, a brief with R1 and R10, releases for both, one accepted record,
# three menu names in English and Spanish, a guide with each name in bold, a README with an image, and a
# deliver Autonomy rules section with each friction token of a reflect cost.sh, and a CLI with the root
# commands info and clip.
good() {
  rm -rf "$tmp/docs" "$tmp/Support" "$tmp/README.md" "$tmp/.claude" "$tmp/Sources" "$tmp/CODING_STANDARDS.md" "$tmp/CLAUDE.md"
  mkdir -p "$tmp/docs/research" "$tmp/docs/requirements" "$tmp/docs/decisions" "$tmp/docs/images" \
    "$tmp/Support/Resources/en.lproj" "$tmp/Support/Resources/es.lproj"
  printf '# Topic\n\nDate: 2026-09-24\n\n## Sources\n\n- x\n' > "$tmp/docs/research/topic.md"
  printf '| ID | Requirement |\n|---|---|\n| R1 | One. |\n| R10 | Ten. |\n\n## Answered questions\n\n- Q? See [0002](../decisions/0002-x.md).\n' > "$tmp/docs/requirements/brief.md"
  printf '# Releases\n\n## Release 1: a\n\nStatus: closed\n\n| Requirement | What |\n|---|---|\n| R1 | a |\n\n1. **x (F01, F03).**\n\n## Release 4: b\n\n| Requirement | What |\n|---|---|\n| R10 | b |\n\n1. **y (F02).**\n' > "$tmp/docs/requirements/releases.md"
  printf '# Features\n\nDate: 2026-09-24\n\n## Sources\n\n- x\n\n| ID | Feature | Req |\n|---|---|---|\n| F01 | One | R1 |\n| F02 | Two | R10 |\n| F04 | Four | - |\n\n| Command | Key |\n|---|---|\n| Fade or crossfade | Cmd-F |\n' > "$tmp/docs/research/podcast-features.md"
  printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n| F01 | One | user 2026-10-14 | done, Release 1 run 1 | R1 |\n| F02 | Two | Logic | Release 4 | R10 |\n| F03 | Three | Audacity | Later | R10 |\n| F04 | Four | Logic | Later | - |\n' > "$tmp/docs/requirements/features.md"
  printf '# 0002. X\n\n- Status: accepted\n' > "$tmp/docs/decisions/0002-x.md"
  printf '| Command | What |\n|---|---|\n| `make test` | a |\n| `make bench FILTER=<test>` | b |\n' > "$tmp/AGENTS.md"
  printf 'test:\n\tswift test\n\nbench:\n\tscripts/bench.sh\n' > "$tmp/Makefile"
  printf '"menu.file.export" = "Export…";\n"menu.edit.cut" = "Cut";\n"menu.markers" = "Markers";\n"other" = "Other";\n' \
    > "$tmp/Support/Resources/en.lproj/Localizable.strings"
  printf '"menu.file.export" = "Exportar…";\n"menu.edit.cut" = "Cortar";\n"menu.markers" = "Marcadores";\n' \
    > "$tmp/Support/Resources/es.lproj/Localizable.strings"
  printf '# Guide\n\n### What Dirigible does not do yet\n\n**Export** **Exportar** **Cut** **Cortar** **Markers** **Marcadores**\n\nSee [the top](#guide), ![x](images/x.png), and [Apple](https://www.apple.com).\n' \
    > "$tmp/docs/guide.md"
  : > "$tmp/docs/images/x.png"
  printf '<picture><source srcset="docs/images/x.png"><img src="docs/images/x.png" alt="x"></picture>\n\nSee [the guide](docs/guide.md) and [what it does not do](docs/guide.md#what-dirigible-does-not-do-yet).\n' \
    > "$tmp/README.md"
  mkdir -p "$tmp/.claude/workflows" "$tmp/.claude/agents"
  printf "const LENSES = [\n  { key: 'x', agentType: 'x-reviewer', gates: ['diff'] },\n]\nagent(task, { agentType: lens.agentType })\n" \
    > "$tmp/.claude/workflows/review-panel.js"
  printf -- '---\nname: x-reviewer\ndescription: X.\n---\n\nBody.\n\n```bash\nswift run dirigible --help\ndirigible clip cut Demo.dirigible\n```\n' > "$tmp/.claude/agents/x-reviewer.md"
  mkdir -p "$tmp/.claude/skills/s/references" "$tmp/docs/workflow"
  printf -- '---\nname: s\n---\n\nRead `references/r.md` when you need the detail.\nRun `dirigible clip cut`, `dirigible info`, or `dirigible --help`.\n' > "$tmp/.claude/skills/s/SKILL.md"
  mkdir -p "$tmp/Sources/DirigibleCLI"
  printf '%s\n' 'struct Dirigible: ParsableCommand {' '    static let configuration = CommandConfiguration(' \
    '        commandName: "dirigible",' '        subcommands: [' '            Info.self, ClipCommand.self,' '        ])' '}' '' \
    'struct Info: ParsableCommand {' '    static let configuration = CommandConfiguration(abstract: "Show.")' '}' \
    > "$tmp/Sources/DirigibleCLI/Dirigible.swift"
  printf '%s\n' 'struct ClipCommand: ParsableCommand {' '    static let configuration = CommandConfiguration(' \
    '        commandName: "clip", abstract: "Clips.", subcommands: [Cut.self])' '' '    struct Cut: ParsableCommand {' \
    '        static let configuration = CommandConfiguration(commandName: "cut", abstract: "Cut.")' '    }' '}' \
    > "$tmp/Sources/DirigibleCLI/ClipCommands.swift"
  printf '# R\n\nDetail.\n' > "$tmp/.claude/skills/s/references/r.md"
  mkdir -p "$tmp/.claude/skills/reflect/scripts" "$tmp/.claude/skills/deliver"
  printf '#!/bin/bash\n# tokens: /^(not verified|flake|fail)([^a-z]|$)/\n' > "$tmp/.claude/skills/reflect/scripts/cost.sh"
  printf -- '---\nname: deliver\n---\n\n## Autonomy rules\n\n- A row result starts with its token: `NOT VERIFIED`, `flake`, or `fail`.\n\n## Phase 7\n\nA `flake` here.\n' \
    > "$tmp/.claude/skills/deliver/SKILL.md"
  printf 'path\twords\tdecision\nTOTAL\t10000\tbaseline\n' > "$tmp/docs/workflow/budgets.tsv"
  printf 'id\tfile\tverdict\ttarget\treason\tsource\tkey\tsummary\n%s\n%s\n' \
    'AGT-001	AGENTS.md	keep	AGENTS.md	scope	10edc92		product scope' \
    'AGT-002	AGENTS.md	merge	AGT-001	duplicate	L12	AGT-001/doc	scope again' > "$tmp/docs/workflow/rules.tsv"
  printf '# Evals\n\n## Scenarios\n\n| ID | Type |\n|---|---|\n| E1 | policy |\n| H1 | retention |\n%s\n\n## Notes\n\n| E1 | another table |\n' \
    '| E38 | agent | s | q | (a) k | `Sources/DirigibleMCP/Server.swift`, `Sources/DirigibleMCP/XTools.swift` | - | - |' \
    > "$tmp/docs/workflow/evals.md"
  mkdir -p "$tmp/Sources/DirigibleMCP"
  printf 'let xTools = [\n    Tool(name: "x"),\n]\n' > "$tmp/Sources/DirigibleMCP/XTools.swift"
  printf 'struct Server {}\n' > "$tmp/Sources/DirigibleMCP/Server.swift"
  mkdir -p "$tmp/.claude/skills/interrogate" "$tmp/scripts"
  printf -- '## Output format\n\n- **Act on:** a numbered list. Each item starts with `(<severity>, <lenses>)`, then the description, Invariant, and Siblings.\n' \
    > "$tmp/.claude/skills/interrogate/SKILL.md"
  printf '%s\n' '        BEGIN { field[1] = "Invariant"; field[2] = "Siblings" }' > "$tmp/scripts/check-plan.sh"
}

# Append one row to the rule register.
rule() { printf '%s\n' "$1" >> "$tmp/docs/workflow/rules.tsv"; }

# Set the words cell of the budget row of <path> to <n>.
budget() { sed -i '' "s|^$1	[0-9]*	|$1	$2	|" "$tmp/docs/workflow/budgets.tsv"; }
# Set the cell <col> (State is 5, Req is 6) of the features.md row of <id> to <value>.
setcol() {
  awk -F'|' -v OFS='|' -v id="$1" -v col="$2" -v val="$3" '$2 == " " id " " { $col = " " val " " } { print }' \
    "$tmp/docs/requirements/features.md" > "$tmp/features.new" && mv "$tmp/features.new" "$tmp/docs/requirements/features.md"
}
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
good; printf '"menu.tools.reduceNoise" = "Reduce Noise\\U2026";\n' >> "$tmp/Support/Resources/en.lproj/Localizable.strings"
printf '**Reduce Noise**\n' >> "$tmp/docs/guide.md"; expect pass 'menu name that ends in an escaped ellipsis'
good; printf '"menu.tools.reduceNoise" = "Reduce Noise\\U2026";\n' >> "$tmp/Support/Resources/en.lproj/Localizable.strings"
expect fail 'escaped ellipsis menu name missing' 'docs/guide.md: no **Reduce Noise** (en menu name)'
good; rm "$tmp/docs/guide.md"; expect fail 'no guide' 'docs/guide.md is missing'
good; sed -i '' 's/src="docs\/images\/x.png"/src="docs\/images\/light.png"/' "$tmp/README.md"; expect fail 'missing src file' 'README.md: link to a missing file: docs/images/light.png'
good; sed -i '' 's/srcset="docs\/images\/x.png"/srcset="docs\/images\/dark.png"/' "$tmp/README.md"; expect fail 'missing srcset file' 'README.md: link to a missing file: docs/images/dark.png'
good; printf '[x](missing.md)\n' >> "$tmp/docs/guide.md"; expect fail 'missing link target in the guide' 'docs/guide.md: link to a missing file: missing.md'
good; printf '![x](docs/images/X.png)\n' >> "$tmp/README.md"; expect fail 'link with the wrong case' 'README.md: link to a missing file: docs/images/X.png'
good; printf '[x](docs/guide.md#no-such-heading)\n' >> "$tmp/README.md"; expect fail 'README link to a missing heading' 'README.md: no heading for #no-such-heading in docs/guide.md'
good; printf '[x](#no-such-heading)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a missing heading' 'docs/guide.md: no heading for #no-such-heading in docs/guide.md'
good; printf '[x](../README.md#no-such-heading)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a missing README heading' 'docs/guide.md: no heading for #no-such-heading in README.md'
good; printf '[x](../README.md#what-dirigible-does-not-do-yet)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a heading of the guide, not of the README' 'docs/guide.md: no heading for #what-dirigible-does-not-do-yet in README.md'
good; printf '# Readme\n\n## Install\n' >> "$tmp/README.md"; printf '[x](../README.md#install)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to a README heading' 'docs/guide.md: guide-html: a link that the bundled guide cannot open: ../README.md#install'
good; printf '[x](http://example.com)\n' >> "$tmp/docs/guide.md"; expect fail 'guide link to an http page' 'docs/guide.md: guide-html: a link that the bundled guide cannot open: http://example.com'
good; printf 'Text <img src="images/x.png"> here.\n' >> "$tmp/docs/guide.md"; expect fail 'raw tag in the guide' 'docs/guide.md: guide-html: raw HTML'
good; printf '> [!WARNING]\n> Text.\n' >> "$tmp/docs/guide.md"; expect fail 'GitHub alert in the guide' 'docs/guide.md: guide-html: GitHub alert'
good; printf 'Type `<name>` in the field.\n' >> "$tmp/docs/guide.md"; expect pass 'a tag in a code span'
good; printf '\n---\n\nMore.\n' >> "$tmp/docs/guide.md"; expect pass 'a thematic break in the guide'
good; printf 'See <https://www.apple.com/mac/>.\n' >> "$tmp/docs/guide.md"; expect pass 'an autolink in the guide'
good; printf 'See [the README][r].\n\n[r]: ../README.md\n' >> "$tmp/docs/guide.md"; expect fail 'a reference link in the guide' 'docs/guide.md: guide-html: a link that the bundled guide cannot open: ../README.md'
good; rm "$tmp/.claude/agents/x-reviewer.md"; expect fail 'panel agentType with no agent file' 'review-panel.js: agentType x-reviewer has no .claude/agents/x-reviewer.md'
good; sed -i '' 's/^name: x-reviewer$/name: y-reviewer/' "$tmp/.claude/agents/x-reviewer.md"; expect fail 'agent file with another name' "review-panel.js: .claude/agents/x-reviewer.md has no 'name: x-reviewer' in its frontmatter"
good; printf -- '---\ndescription: X.\n---\n\nname: x-reviewer\n' > "$tmp/.claude/agents/x-reviewer.md"; expect fail 'name only in the body' "review-panel.js: .claude/agents/x-reviewer.md has no 'name: x-reviewer' in its frontmatter"
good; sed -i '' "s/agentType: 'x-reviewer'/agentType: \"x-reviewer\"/" "$tmp/.claude/workflows/review-panel.js"; expect pass 'agentType in double quotes'
good; sed -i '' "s/agentType: 'x-reviewer'/agentType: name/" "$tmp/.claude/workflows/review-panel.js"; expect fail 'panel with no literal agentType' 'review-panel.js: no literal agentType'
good; printf 'QUOTA\t9000\tbaseline\n' >> "$tmp/docs/workflow/budgets.tsv"; expect fail 'a QUOTA row' 'budgets.tsv: a row other than TOTAL: QUOTA'
good; printf 'AGENTS.md\t1000\tbaseline\n' >> "$tmp/docs/workflow/budgets.tsv"; expect fail 'an AGENTS.md row' 'budgets.tsv: a row other than TOTAL: AGENTS.md'
good; printf '.claude/skills/v/NOTES.md\t100\tvendored: third party\n' >> "$tmp/docs/workflow/budgets.tsv"; expect fail 'a vendored row' 'budgets.tsv: a row other than TOTAL: .claude/skills/v/NOTES.md'
good; printf 'TOTAL\t10000\tbaseline\n' >> "$tmp/docs/workflow/budgets.tsv"; expect fail 'two TOTAL rows' 'budgets.tsv: more than one TOTAL row'
good; mkdir -p "$tmp/.claude/skills/new"; printf -- '---\nname: new\n---\n' > "$tmp/.claude/skills/new/SKILL.md"; expect pass 'a new SKILL.md with no row'
good; budget TOTAL 5; expect pass 'the docs over TOTAL x 1.03'
good; sed -i '' '/^TOTAL	/d' "$tmp/docs/workflow/budgets.tsv"; expect fail 'no TOTAL row' 'budgets.tsv: no TOTAL row'
good; sed -i '' 's|^TOTAL	10000	baseline$|TOTAL	10000	|' "$tmp/docs/workflow/budgets.tsv"; expect fail 'the TOTAL row with an empty decision' 'budgets.tsv: the row for TOTAL has no decision'
good; sed -i '' 's|references/r.md|the reference|' "$tmp/.claude/skills/s/SKILL.md"; expect fail 'references file not named by its SKILL.md' '.claude/skills/s/references/r.md: .claude/skills/s/SKILL.md does not name it by path'
good; long_ref 101; expect fail 'long references file with no contents list' '.claude/skills/s/references/r.md: over 100 lines with no contents list in its first 10 lines'
good; long_ref 101 '## Contents'; expect pass 'long references file with a contents list'
good; long_ref 100; expect pass 'references file of 100 lines with no contents list'
good; rule 'AGT-001	AGENTS.md	keep	AGENTS.md	scope	10edc92		scope twice'; expect fail 'register with a duplicate ID' 'rules.tsv: duplicate id AGT-001'
good; rule 'AGT-003	AGENTS.md	branch	AGENTS.md	scope	10edc92		scope'; expect fail 'register with a bad verdict' 'rules.tsv: AGT-003 has verdict branch'
good; rule 'AGT-003	AGENTS.md	merge	AGT-999	duplicate	10edc92		scope'; expect fail 'register merge to an unknown ID' 'rules.tsv: AGT-003 merges into an unknown id AGT-999'
good; rule 'AGT-003	AGENTS.md	delete			10edc92		scope'; expect fail 'register delete with no reason' 'rules.tsv: AGT-003 is delete with no reason'
good; rule 'AGT-003	AGENTS.md	keep	AGENTS.md	scope			scope'; expect fail 'register row with no source' 'rules.tsv: AGT-003 has no source'
good; rule 'AGT-003	AGENTS.md	keep	no/such.md	scope	10edc92		scope'; expect fail 'register target that does not exist' 'rules.tsv: AGT-003 targets no/such.md, which does not exist'
good; rule 'AGT-003	AGENTS.md	new		scope	10edc92		scope'; expect fail 'register row with no target' 'rules.tsv: AGT-003 is new with no target'
good; rule 'AGT-003	AGENTS.md	new	AGENTS.md	scope10edc92	claim	scope'; expect fail 'register row with 7 fields' 'rules.tsv: AGT-003 has 7 fields; each row has 8'
good; rule 'AGT-003	AGENTS.md	new	AGENTS.md	scope	10edc92	claim	scope	more'; expect fail 'register row with 9 fields' 'rules.tsv: AGT-003 has 9 fields; each row has 8'
good; rm "$tmp/docs/workflow/rules.tsv"; expect fail 'no register' 'docs/workflow/rules.tsv is missing'
good; sed -i '' '1s/$/	text/' "$tmp/docs/workflow/rules.tsv"; expect fail 'register with a text column' 'rules.tsv: the header is not'
good; printf 'In run 2026-10-01-x the hook failed.\n' >> "$tmp/.claude/skills/s/references/r.md"; expect fail 'a date in a loaded doc' '.claude/skills/s/references/r.md:4: a date in a loaded doc'
# An import is a line that is only @<path>: the always-on count reads those. An inline @<path> outside
# a code span or a fence loads at the start and passes the count uncounted.
good; printf 'See @docs/guide.md for the guide.\n' >> "$tmp/AGENTS.md"; expect fail 'an inline @ import in AGENTS.md' 'AGENTS.md:5: an inline @ import'
good; printf -- '- @docs/guide.md\n' >> "$tmp/AGENTS.md"; expect fail 'an @ import in a list item' 'AGENTS.md:5: an inline @ import'
good; printf '@docs/guide.md\n' >> "$tmp/AGENTS.md"; expect pass 'an @ import on a line of its own'
good; printf 'See `@docs/guide.md`, or mail a@b.com.\n' >> "$tmp/AGENTS.md"; expect pass 'an @ token in a code span and in an address'
good; printf '```\nsee @docs/guide.md\n```\n' >> "$tmp/AGENTS.md"; expect pass 'an @ token in a fenced block'
good; printf '@docs/i.md\n' > "$tmp/CLAUDE.md"; printf 'See @docs/guide.md\n' > "$tmp/docs/i.md"; expect fail 'an inline @ import in a file that CLAUDE.md imports' 'docs/i.md:1: an inline @ import'
good; mkdir -p "$tmp/.claude/rules"; printf 'See @docs/guide.md\n' > "$tmp/.claude/rules/r.md"; expect fail 'an inline @ import in a rules file' '.claude/rules/r.md:1: an inline @ import'
good; printf 'See @docs/guide.md\n' > "$tmp/docs/i.md"; expect pass 'an inline @ import in a file that no start file imports'
good; printf 'Since 2026-10-01, check.\n' >> "$tmp/AGENTS.md"; expect fail 'a date in AGENTS.md' 'AGENTS.md:5: a date in a loaded doc'
good; printf 'Since 2026-10-01, check.\n' > "$tmp/CODING_STANDARDS.md"; expect fail 'a date in CODING_STANDARDS.md' 'CODING_STANDARDS.md:1: a date in a loaded doc'
good; printf 'Source: example.org, fetched 2026-07-18.\n' >> "$tmp/.claude/skills/s/SKILL.md"; expect pass 'a fetch date on a Source line'
good; sed -i '' 's/, `flake`,/,/' "$tmp/.claude/skills/deliver/SKILL.md"; expect fail 'a cost.sh token only outside the deliver Autonomy rules' '.claude/skills/deliver/SKILL.md: the Autonomy rules have no `flake`'
good; sed -i '' 's/`fail`\./`failed`./' "$tmp/.claude/skills/deliver/SKILL.md"; expect fail 'a cost.sh token only inside a longer word' '.claude/skills/deliver/SKILL.md: the Autonomy rules have no `fail`'
good; printf '#!/bin/bash\n' > "$tmp/.claude/skills/reflect/scripts/cost.sh"; expect fail 'cost.sh with no token list' '.claude/skills/reflect/scripts/cost.sh: no token list'
good; sed -i '' 's/^## Autonomy rules$/## Rules/' "$tmp/.claude/skills/deliver/SKILL.md"; expect fail 'deliver with no Autonomy rules section' '.claude/skills/deliver/SKILL.md: no ## Autonomy rules section'
good; printf 'Run `dirigible show`.\n' >> "$tmp/.claude/skills/s/SKILL.md"; expect fail 'a dirigible command that the CLI does not have' '.claude/skills/s/SKILL.md:7: `dirigible show` is not a command of Sources/DirigibleCLI'
good; printf 'Run `dirigible cut`.\n' >> "$tmp/README.md"; expect fail 'a subcommand used as a root command' 'README.md:4: `dirigible cut` is not a command of Sources/DirigibleCLI'
good; printf 'Run `swift run dirigible show`.\n' >> "$tmp/.claude/skills/s/SKILL.md"; expect fail 'an unknown command after swift run' '.claude/skills/s/SKILL.md:7: `dirigible show` is not a command of Sources/DirigibleCLI'
good; printf '```\ndirigible show Demo.dirigible\n```\n' >> "$tmp/.claude/agents/x-reviewer.md"; expect fail 'an unknown command in a fenced block' '.claude/agents/x-reviewer.md:13: `dirigible show` is not a command of Sources/DirigibleCLI'
good; rm -rf "$tmp/Sources"; expect fail 'no CLI file' 'Sources/DirigibleCLI/Dirigible.swift is missing'
good; printf '| E1 | again |\n' >> "$tmp/docs/workflow/evals.md"; expect pass 'an eval ID again in another section'
good; sed -i '' 's/^| H1 |/| E1 |/' "$tmp/docs/workflow/evals.md"; expect fail 'a duplicate eval scenario ID' 'docs/workflow/evals.md: duplicate scenario id E1'
good; rm "$tmp/docs/workflow/evals.md"; expect fail 'no eval set' 'docs/workflow/evals.md is missing'
good; sed -i '' 's|, `Sources/DirigibleMCP/XTools.swift`||' "$tmp/docs/workflow/evals.md"
expect fail 'a tools file that the E38 Files cell does not name' 'docs/workflow/evals.md: the Files cell of E38 has no `Sources/DirigibleMCP/XTools.swift` (it defines a tools array)'
good; sed -i '' 's|`Sources/DirigibleMCP/XTools.swift`|`Sources/DirigibleMCP/XTools.swift.bak`|' "$tmp/docs/workflow/evals.md"
expect fail 'a longer path in the E38 Files cell' 'docs/workflow/evals.md: the Files cell of E38 has no `Sources/DirigibleMCP/XTools.swift`'
good; printf '    package static let yTools = [Tool(name: "y")]\n' > "$tmp/Sources/DirigibleMCP/YTools.swift"
expect fail 'a package static tools array that the E38 Files cell does not name' 'docs/workflow/evals.md: the Files cell of E38 has no `Sources/DirigibleMCP/YTools.swift` (it defines a tools array)'
good; sed -i '' 's/description, Invariant,/description, Rule,/' "$tmp/.claude/skills/interrogate/SKILL.md"
expect fail 'an Act on format with another field than check-plan.sh' '.claude/skills/interrogate/SKILL.md: the Act on line of ## Output format has no Invariant (a field of scripts/check-plan.sh)'
good; sed -i '' 's/^- \*\*Act on:\*\*/- **Fix:**/' "$tmp/.claude/skills/interrogate/SKILL.md"
expect fail 'no Act on line' '.claude/skills/interrogate/SKILL.md: no Act on line in ## Output format'
good; printf '#!/bin/bash\n' > "$tmp/scripts/check-plan.sh"; expect fail 'check-plan.sh with no field names' 'scripts/check-plan.sh: no field[1] and field[2] names'

# The feature inventory: features.md has one row for each catalog ID, a state of the grammar, and the catalog Req.
for s in 'done, Release 1 run 2' 'done, Release 2 runs 11a and 11b-1' 'done, Release 1 run 2; Later: a part' \
  'done, Release 2 run 16 and Release 3 run 5 (v0.3.5)' \
  'done, Release 1 runs 3 and 3b and Release 3 run 1 (v0.3.4: the record monitor); Later: a part'; do
  good; setcol F01 5 "$s"; expect pass "feature state $s"
done
good; setcol F02 5 'done, Release 4 run 7 (moved from Release 5)'; expect pass 'a moved feature in the open release section'
good; setcol F03 5 'Later (note)'; expect pass 'a Later state with a note'
good; setcol F03 5 'Dropped (reason)'; expect pass 'a Dropped state'
good; rm "$tmp/docs/requirements/features.md"; expect fail 'no features.md' 'docs/requirements/features.md is missing'
good; sed -i '' '/^| F01 /d' "$tmp/docs/requirements/features.md"; expect fail 'a catalog ID with no row' 'features.md: no row for F01'
good; printf '| F01 | One again | user 2026-10-14 | Later | R1 |\n' >> "$tmp/docs/requirements/features.md"; expect fail 'two rows for one ID' 'features.md: F01 has more than one row'
good; setcol F01 5 ''; expect fail 'an empty state' 'features.md: F01 has no state'
# A run ID of Release 4 or later is digits only: tag-release.sh matches the digits of the tag.
good; setcol F01 5 'done, Release 3 run 9b and Release 4 run 2'; expect pass 'a letter run ID in Release 3 and digits in Release 4'
for s in 'done, Release 4 run 5a' 'done, Release 4 runs 5 and 5b' 'done, Release 3 run 2 and Release 4 run 5a' 'done, Release 12 run 2-1'; do
  good; setcol F01 5 "$s"; expect fail "feature state $s" 'features.md: F01 has a bad state'
done
for s in 'planned' 'later' 'Release' 'Release four' 'done' 'done in run 3' 'Dropped' 'done, Release 1' 'done, Release 1 run'; do
  good; setcol F01 5 "$s"; expect fail "feature state $s" 'features.md: F01 has a bad state'
done
good; setcol F01 6 'R2'; expect fail 'a Req that differs from the catalog' 'features.md: F01 Req R2 is not the Req R1 of podcast-features.md'
good; setcol F04 6 'R3'; expect fail 'a catalog Req of - changed' 'features.md: F04 Req R3 is not the Req - of podcast-features.md'
good; printf '| F05 | Five | Logic | Later | - |\n' >> "$tmp/docs/requirements/features.md"; expect fail 'a new ID with no Req' 'features.md: F05 has no Req'
good; printf '| F05 | Five | Logic | Dropped (not used) | - |\n' >> "$tmp/docs/requirements/features.md"; expect pass 'a dropped new ID with no Req'
good; sed -i '' 's/| State |/| Status |/' "$tmp/docs/requirements/features.md"; expect fail 'features.md with no State column' 'features.md: no State column'
good; sed -i '' 's/| Req |/| Reqs |/' "$tmp/docs/requirements/features.md"; expect fail 'features.md with no Req column' 'features.md: no Req column'
good; sed -i '' 's/| ID |/| No |/' "$tmp/docs/requirements/features.md"; expect fail 'features.md with no ID column' 'features.md: no ID column'
good; printf '# Features\n\n| ID | Feature | From | State | Req |\n|---|---|---|---|---|\n' > "$tmp/docs/requirements/features.md"; expect fail 'features.md with no F row' 'features.md has no F row'
good; printf '| ID | Feature |\n|---|---|\n| F09 | Nine |\n' >> "$tmp/docs/research/podcast-features.md"; expect fail 'a catalog table with an ID header and no Req column' 'podcast-features.md: a table with an ID header has no Req column'
good; sed -i '' 's/(F01, F03)/(F01, F03, F09)/' "$tmp/docs/requirements/releases.md"; expect fail 'releases.md names an ID with no row' 'releases.md names F09, which has no features.md row'
good; setcol F02 5 'Release 5'; expect fail 'a Release 5 state with no Release 5 section' 'features.md: F02 has the state Release 5, but the open Release 5 section does not name it'
good; sed -i '' 's/(F02)/(F01)/' "$tmp/docs/requirements/releases.md"; expect fail 'an open release section that does not name its feature' 'features.md: F02 has the state Release 4, but the open Release 4 section does not name it'
good; sed -i '' 's/(F02)/(F02, F03)/' "$tmp/docs/requirements/releases.md"; expect fail 'an open release section that names a Later feature' 'releases.md: the Release 4 section names F03, whose state is Later'
good; sed -i '' 's/^Status: closed$/Status: closed 2026-11-02/' "$tmp/docs/requirements/releases.md"; expect pass 'a closed release section with a date after the status'
good; sed -i '' 's/^Status: closed$/Status: closedown/' "$tmp/docs/requirements/releases.md"; expect fail 'a status line that only starts with closed' 'releases.md: the Release 1 section names F03, whose state is Later'

# The module map: its Folders line names each folder of a Swift target in the scope of its target.
folder() { mkdir -p "$tmp/Sources/$1"; printf 'struct X {}\n' > "$tmp/Sources/$1/$2"; }
map() { printf '# 0002. Map\n\n%s\n' "$1" > "$tmp/docs/decisions/0002-module-map.md"; }
audio='- **Folders.** Inside `DirigibleAudio`: `Capture/` (the device list), and `Studio/` (the facade). `DirigibleApp/Timeline/` holds the view.'
good; folder DirigibleAudio/Capture A.swift; map "$audio"; expect pass 'a Swift folder that the Folders line names'
good; folder DirigibleAudio/Capture A.swift; folder DirigibleAudio/Transcribe B.swift; map "$audio"
expect fail 'a Swift folder that the Folders line does not name' 'docs/decisions/0002-module-map.md: Folders does not name Sources/DirigibleAudio/Transcribe/'
good; folder DirigibleAudio/Capture A.swift; mkdir -p "$tmp/Sources/CLame/src"; : > "$tmp/Sources/CLame/src/a.c"; map "$audio"
expect pass 'a C folder with no Swift file'
good; folder DirigibleApp/Timeline T.swift; map "$audio"; expect pass 'a folder of another target named with its target'
good; folder DirigibleAudio/Transcribe B.swift; map "$audio"$'\n- Amended: 2026-11-01. `Transcribe/` holds the transcription job.'
expect fail 'a folder that only another line names' 'docs/decisions/0002-module-map.md: Folders does not name Sources/DirigibleAudio/Transcribe/'
good; folder DirigibleAudio/Capture A.swift; expect fail 'a Swift folder and no module map' 'no docs/decisions/0002-module-map.md for the folders of Sources/'
good; folder DirigibleMCP/Capture X.swift; map "$audio"
expect fail 'a bare folder name for another target' 'docs/decisions/0002-module-map.md: Folders does not name Sources/DirigibleMCP/Capture/'
good; folder DirigibleAudio/New/Sub C.swift; map "$audio"
expect fail 'a folder with only nested Swift files' 'docs/decisions/0002-module-map.md: Folders does not name Sources/DirigibleAudio/New/'

[[ $failures -eq 0 ]] && echo "check-docs tests: all passed"
exit $((failures > 0))
