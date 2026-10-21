#!/bin/bash
# Print words of the workflow docs of a repo (decision 0028, Word budgets). Read-only.
# Usage: scripts/workflow-words.sh <mode> [--root <dir>] [--rev <commit>]
# The root is the git top level unless --root names it. With --rev the script reads that commit
# with git ls-tree and git show; else it reads the work tree. The workflow docs are AGENTS.md,
# CODING_STANDARDS.md, .claude/skills/<name>/<file>.md, .claude/skills/<name>/references/<file>.md,
# and .claude/agents/<name>.md. This is the one list of them: check-docs.sh, new-run.sh, and
# check-governance.sh call this script.
# - list: the paths of the workflow docs.
# - sum: their words (wc -w), less the folders on the `Pinned skills` line of
#   .claude/skills/THIRD_PARTY.md.
# - always-on: the words that Claude Code loads at the start: AGENTS.md, CLAUDE.md, each file that
#   an `@<path>` line of those two files imports (to depth 5, each file once), and the
#   `description:` value of each .claude/skills/<name>/SKILL.md and .claude/agents/<name>.md. The
#   value runs from the `description:` line to the next frontmatter key; a lone YAML indicator
#   (>, |, >-, |-) is not a word.
# - count: the number of skills (SKILL.md files) plus agents.
# A missing file or folder counts 0. A bad mode or a bad commit exits 2.
# scripts/workflow-words.test.sh tests it.
set -euo pipefail

die() { echo "workflow-words: $1" >&2; exit 2; }

mode="${1:-}"
[[ "$mode" =~ ^(list|sum|always-on|count)$ ]] || die "usage: scripts/workflow-words.sh <list|sum|always-on|count> [--root <dir>] [--rev <commit>]"
shift
root="" rev=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) root="${2:?--root needs a folder}"; shift 2 ;;
        --rev) rev="${2:?--rev needs a commit}"; shift 2 ;;
        *) die "unknown argument $1" ;;
    esac
done
[[ -n "$root" ]] || root="$(git rev-parse --show-toplevel)"
cd "$root"
[[ -z "$rev" ]] || git rev-parse -q --verify "$rev^{commit}" > /dev/null || die "no commit $rev"

doc_re='^(AGENTS\.md|CODING_STANDARDS\.md|\.claude/skills/[^/]+/[^/]+\.md|\.claude/skills/[^/]+/references/[^/]+\.md|\.claude/agents/[^/]+\.md)$'
desc_re='^(\.claude/skills/[^/]+/SKILL\.md|\.claude/agents/[^/]+\.md)$'

# The text of a file, or nothing when it does not exist.
read_file() {
    if [[ -n "$rev" ]]; then git show "$rev:$1" 2> /dev/null || true; else cat "$1" 2> /dev/null || true; fi
}
exists() {
    if [[ -n "$rev" ]]; then git cat-file -e "$rev:$1" 2> /dev/null; else [[ -f "$1" ]]; fi
}
words() { read_file "$1" | wc -w | tr -d ' '; }

docs() {
    {
        if [[ -n "$rev" ]]; then
            git ls-tree -r --name-only "$rev"
        else
            find AGENTS.md CODING_STANDARDS.md .claude/skills .claude/agents -type f -name '*.md' 2> /dev/null || true
        fi
    } | { grep -E "$doc_re" || true; } | LC_ALL=C sort
}

# The words of the description value of the file $1.
description_words() {
    read_file "$1" | awk '
        NR == 1 { if ($0 != "---") exit; next }
        /^---[ \t]*$/ { exit }
        /^description:/ {
            inside = 1; v = $0; sub(/^description:[ \t]*/, "", v)
            if (v ~ /^[>|][-+]?[0-9]*[ \t]*$/) v = ""
            n += split(v, a, " "); next
        }
        inside && /^[A-Za-z0-9_-]+:/ { inside = 0 }
        inside { n += split($0, a, " ") }
        END { print n + 0 }'
}

# The path $2 as seen from the folder of the file $1, with . and .. resolved; empty when it leaves the root.
resolve() {
    local dir="${1%/*}" parts=() out=() p
    [[ "$1" == */* ]] || dir=""
    IFS=/ read -ra parts <<< "${dir:+$dir/}$2"
    for p in "${parts[@]}"; do
        case "$p" in
            '' | .) ;;
            ..) [[ ${#out[@]} -gt 0 ]] || return 0; unset 'out[${#out[@]}-1]' ;;
            *) out+=("$p") ;;
        esac
    done
    (IFS=/; echo "${out[*]}")
}

case "$mode" in
    list) docs ;;
    count) docs | { grep -cE "$desc_re" || true; } ;;
    sum)
        pinned=" $(read_file .claude/skills/THIRD_PARTY.md | sed -n 's/^Pinned skills: //p' | { grep -o '`[a-z0-9-]*`' || true; } | tr -d '`' | tr '\n' ' ')"
        total=0
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            skill=""
            [[ "$f" != .claude/skills/* ]] || { skill="${f#.claude/skills/}"; skill="${skill%%/*}"; }
            [[ -z "$skill" || "$pinned" != *" $skill "* ]] || continue
            total=$((total + $(words "$f")))
        done < <(docs)
        echo "$total"
        ;;
    always-on)
        total=0
        queue=(AGENTS.md CLAUDE.md) seen=" " depth=0
        while [[ ${#queue[@]} -gt 0 && $depth -le 5 ]]; do
            next=()
            for f in "${queue[@]}"; do
                [[ "$seen" != *" $f "* ]] || continue
                seen+="$f "
                exists "$f" || continue
                total=$((total + $(words "$f")))
                while IFS= read -r target; do
                    [[ -n "$target" && "$target" != /* && "$target" != '~'* ]] || continue
                    path="$(resolve "$f" "$target")"
                    [[ -z "$path" ]] || next+=("$path")
                done < <(read_file "$f" | { grep -E '^@[^[:space:]]+[[:space:]]*$' || true; } | sed -E 's/^@//; s/[[:space:]]+$//')
            done
            queue=("${next[@]+"${next[@]}"}")
            depth=$((depth + 1))
        done
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            total=$((total + $(description_words "$f")))
        done < <(docs | { grep -E "$desc_re" || true; })
        echo "$total"
        ;;
esac
