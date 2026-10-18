#!/bin/bash
# Refuse commits that must not be pushed: a commit that a tool made, and a secret in a commit.
# Usage: scripts/check-commits.sh <base>                   both checks on <base>..HEAD
#        scripts/check-commits.sh --authors <rev-list args>   for example <old>..<new>
#        scripts/check-commits.sh --secrets <base>         gitleaks on <base>..HEAD
# A commit fails the author check when its author, its committer, or a Co-Authored-By trailer
# names a tool (the pattern below). The secret scan reads the commits, not the tree, so a secret
# that a later commit removes still fails. It needs gitleaks and fails with no skip when it is
# missing.
# Callers: land.sh (before the push), run-checks.sh (--secrets, when BASE is set, so
# make check-changed BASE=<ref> scans), .githooks/pre-push (--authors, on each pushed ref).
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

secrets() {
    local base="$1" report code=0
    git rev-parse --verify -q "$base^{commit}" > /dev/null || die "$base is not a commit"
    command -v gitleaks > /dev/null ||
        die "gitleaks is not installed, and the secret scan needs it. Install it with: brew install gitleaks"
    # --exit-code 2 makes a finding exit 2, so exit 1 stays a tool error. A bad ref in --log-opts
    # gives exit 0 and no scan, so the base is checked above.
    report="$(gitleaks git --no-banner --no-color --redact --exit-code 2 --report-format json --report-path - \
        --log-opts="$base..HEAD" "$(git rev-parse --show-toplevel)")" || code=$?
    case $code in
        0) ;;
        2)
            grep -E '"(RuleID|File|Commit)"' <<<"$report" >&2 || true
            die "gitleaks found a secret in the commits of $base..HEAD (listed above); remove it from the commit, not only from the tree"
            ;;
        *) die "gitleaks failed (exit $code)" ;;
    esac
}

if [[ "${1:-}" == --authors ]]; then
    shift
    [[ $# -gt 0 ]] || { echo "usage: scripts/check-commits.sh --authors <rev-list args>" >&2; exit 2; }
    authors "$@"
    exit 0
fi

if [[ "${1:-}" == --secrets ]]; then
    [[ $# -eq 2 ]] || { echo "usage: scripts/check-commits.sh --secrets <base>" >&2; exit 2; }
    secrets "$2"
    exit 0
fi

[[ $# -eq 1 ]] || { echo "usage: scripts/check-commits.sh <base> | --authors <rev-list args> | --secrets <base>" >&2; exit 2; }
base="$1"
git rev-parse --verify -q "$base^{commit}" > /dev/null || die "$base is not a commit"
authors "$base..HEAD"
secrets "$base"
