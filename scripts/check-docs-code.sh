#!/bin/bash
# Check the docs that name code, against Sources/ and the Makefile.
# Usage: scripts/check-docs-code.sh [repo root]. scripts/check-docs.sh runs it once.
# Rules of this script:
#   The Commands table of AGENTS.md has one row for each make target, and the Makefile has it.
#   decision 0002 (the module map) names each folder of Sources/ that holds a Swift file.
#   Each `dirigible <command>` of a loaded doc names a root command of Sources/DirigibleCLI.
# Rules that read code and stay in check-docs.sh: the Files cell of the eval E38, NOTICE, the menu
# names, and the Act on line.
# The errors keep the `check-docs:` prefix and go to stderr. The exit status is 1 after an error.
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
fail=0
err() { echo "check-docs: $*" >&2; fail=1; }

# The Commands table of AGENTS.md has one row for each make target, and the Makefile has that target.
if [[ -f "$root/AGENTS.md" ]]; then
    targets="$(grep -oE '^\| `make [a-z-]+' "$root/AGENTS.md" | cut -c9- || true)"
    for t in $(sort <<<"$targets" | uniq -d); do err "AGENTS.md: more than one row for make $t"; done
    for t in $targets; do
        grep -qE "^$t:" "$root/Makefile" 2>/dev/null || err "AGENTS.md: row for make $t, but the Makefile has no $t target"
    done
fi

# The Folders line of the module map names each folder of Sources/<target>/ that holds a Swift file,
# at any depth: as `<folder>/` for DirigibleAudio (the line scopes its bare names), else as
# `<target>/<folder>/`. It also names no folder that Sources/ lacks. A record with no Folders line
# gives one error and no folder check.
map="$root/docs/decisions/0002-module-map.md"
swift_folders=""
[[ ! -d "$root/Sources" ]] || swift_folders="$(cd "$root/Sources" && find . -mindepth 3 -type f -name '*.swift' | awk -F/ '{ print $2 "/" $3 }' | sort -u)"
if [[ -n "$swift_folders" && ! -f "$map" ]]; then
    err "no docs/decisions/0002-module-map.md for the folders of Sources/"
elif [[ -f "$map" ]]; then
    folders_line="$(grep -m1 '^- \*\*Folders\.\*\*' "$map" || true)"
    if [[ -z "$folders_line" ]]; then
        err "docs/decisions/0002-module-map.md: no Folders line"
    else
        while IFS=/ read -r target folder; do
            [[ -n "$target" ]] || continue
            name="$target/$folder"
            [[ "$target" != DirigibleAudio ]] || name="$folder"
            [[ "$folders_line" == *"\`$name/\`"* ]] || err "docs/decisions/0002-module-map.md: Folders does not name Sources/$target/$folder/"
        done <<<"$swift_folders"
        for named in $(grep -oE '`[A-Za-z0-9_]+(/[A-Za-z0-9_]+)?/`' <<<"$folders_line" | tr -d '`' | sort -u); do
            path="$named"
            [[ "$named" == */*/ ]] || path="DirigibleAudio/$named"
            [[ -d "$root/Sources/$path" ]] || err "docs/decisions/0002-module-map.md: Folders names $named with no folder Sources/$path"
        done
    fi
fi

# Each `dirigible <command>` or `swift run dirigible <command>` in AGENTS.md, the README, the
# guide, a skill, or an agent (backticked, or in a fenced block) names a root command of the CLI:
# a type of the subcommands list of Dirigible.swift, by the commandName of its configuration,
# else by its type name in kebab case. An option passes.
cli="$root/Sources/DirigibleCLI"
if [[ ! -f "$cli/Dirigible.swift" ]]; then
    err "Sources/DirigibleCLI/Dirigible.swift is missing; the dirigible command check reads it"
else
    commands=" "
    for t in $(awk '/subcommands: \[/ { p = 1 } p { print } p && /\]/ { exit }' "$cli/Dirigible.swift" | grep -oE '[A-Za-z]+\.self' | sed 's/\.self$//'); do
        name="$(awk -v t="$t" '
            $0 ~ "^struct " t "[:{ ]" { s = 1; next }
            s && /^    static let configuration/ { c = 1 }
            c && !/^    static let configuration/ && !/^        / { exit }
            c && match($0, /commandName: "[^"]+"/) { print substr($0, RSTART + 14, RLENGTH - 15); exit }
        ' "$cli"/*.swift)"
        commands+="${name:-$(sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' <<<"$t" | tr '[:upper:]' '[:lower:]')} "
    done
    while IFS=: read -r f n word; do
        [[ "$word" == -* || "$commands" == *" $word "* ]] || err "${f#"$root"/}:$n: \`dirigible $word\` is not a command of Sources/DirigibleCLI"
    done < <(find "$root/AGENTS.md" "$root/README.md" "$root/docs/guide.md" "$root/.claude/skills" "$root/.claude/agents" \
        -name '*.md' -type f 2>/dev/null | sort | xargs awk '
        FNR == 1 { fence = 0 }
        /^ *```/ { fence = !fence; next }
        {
            line = $0
            re = fence ? "(^|[^A-Za-z0-9_./-])dirigible [^ `]+" : "`(swift run )?dirigible [^ `]+"
            while (match(line, re)) {
                word = substr(line, RSTART, RLENGTH)
                sub(/.*dirigible /, "", word)
                print FILENAME ":" FNR ":" word
                line = substr(line, RSTART + RLENGTH)
            }
        }')
fi

exit "$fail"
