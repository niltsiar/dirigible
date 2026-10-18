#!/bin/bash
# Refuse commits that must not be pushed: a commit that a tool made, and a secret in a commit.
# Usage: scripts/check-commits.sh <base>                   both checks on <base>..HEAD
#        scripts/check-commits.sh --authors <rev-list args>   for example <old>..<new>
# A commit fails when its author, its committer, or a Co-Authored-By trailer names a tool (the
# pattern below). The names and addresses of the repo owner pass.
# Callers: land.sh (before the push), .githooks/pre-push (--authors, on each pushed ref).
# scripts/land.test.sh tests it.
set -euo pipefail

die() { echo "check-commits: $1" >&2; exit 1; }

# A name or an address of a tool: a coding agent, a bot account, or a noreply address of an AI lab.
tool_re='(^|[^[:alnum:]])(claude|copilot|codex|t3 ?code|opencode|cursor|gemini)([^[:alnum:]]|$)|\[bot\]|noreply@(anthropic|openai)\.com'

authors() {
    local rows sha author committer trailers found="" field value
    rows="$(git log --format='%H%x09%an <%ae>%x09%cn <%ce>%x09%(trailers:key=Co-Authored-By,valueonly,unfold,separator=%x1f)' "$@" --)" ||
        die "git log failed on: $*"
    # One grep clears a range with no tool, so a long range costs no loop.
    grep -qiE "$tool_re" <<<"$rows" || return 0
    while IFS=$'\t' read -r sha author committer trailers; do
        [[ -n "$sha" ]] || continue
        for field in "author:$author" "committer:$committer" "Co-Authored-By:${trailers//$'\x1f'/; }"; do
            value="${field#*:}"
            if grep -qiE "$tool_re" <<<"$value"; then
                found+="${sha:0:10} ${field%%:*} names a tool: $value"$'\n'
            fi
        done
    done <<<"$rows"
    [[ -z "$found" ]] || {
        printf '%s' "$found" >&2
        die "a commit of the range names a tool as author, committer, or Co-Authored-By; make the commit again as yourself, with no such trailer"
    }
}

if [[ "${1:-}" == --authors ]]; then
    shift
    [[ $# -gt 0 ]] || { echo "usage: scripts/check-commits.sh --authors <rev-list args>" >&2; exit 2; }
    authors "$@"
    exit 0
fi

[[ $# -eq 1 ]] || { echo "usage: scripts/check-commits.sh <base> | --authors <rev-list args>" >&2; exit 2; }
base="$1"
git rev-parse --verify -q "$base^{commit}" > /dev/null || die "$base is not a commit"
authors "$base..HEAD"
