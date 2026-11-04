#!/bin/bash
# Check that provider-limit.sh refuses a bad name or reset time with exit 2 and leaves the limits
# file as it was, that a valid call appends one line, and that agent-guard.sh refuses a
# delegate_task on the line that the script wrote. Each case uses a temporary git repo with copies
# of the scripts and the hook. Run by `make test-hooks`.
set -uo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/.claude/hooks"
git init -q "$repo"
cp "$src/scripts/provider-limit.sh" "$src/scripts/lock-words.sh" "$src/scripts/with-lock.sh" "$repo/scripts/"
cp "$src/.claude/hooks/agent-guard.sh" "$src/.claude/hooks/commit-files.awk" "$repo/.claude/hooks/"
writer="$repo/scripts/provider-limit.sh"
file="$repo/.git/dirigible-provider-limits"

# refuse <case> <name> <reset>: exit 2, and the file is as it was before the call.
refuse() {
    local before="absent" out code
    [[ ! -e "$file" ]] || before="$(cat "$file")"
    out="$("$writer" "$2" "$3" 2>&1)"
    code=$?
    [[ $code -eq 2 && -n "$out" ]] || fail "$1: expected exit 2 and a message, got exit $code: $out"
    if [[ -e "$file" ]]; then [[ "$(cat "$file")" == "$before" ]] || fail "$1: the file changed"
    else [[ "$before" == absent ]] || fail "$1: the file is gone"; fi
}

# Each refused input leaves no file, and then leaves the one line of an earlier valid call.
refuse_all() {
    refuse "a reset with a space, $1" antigravity '2026-11-04 17:00'
    refuse "a reset with no date, $1" antigravity '17:00'
    refuse "a month 13, $1" antigravity '2026-13-01T00:00'
    refuse "a day that the month does not have, $1" antigravity '2026-02-30T10:00'
    refuse "a reset with seconds, $1" antigravity '2026-11-04T17:00:00'
    refuse "an empty name, $1" '' '2026-11-04T17:00'
    refuse "a name with a space, $1" 'anti gravity' '2026-11-04T17:00'
    refuse "a name with a tab, $1" $'anti\tgravity' '2026-11-04T17:00'
    out="$("$writer" antigravity 2>&1)"
    [[ $? -eq 2 ]] || fail "one argument, $1: expected exit 2: $out"
}
refuse_all 'no file'

out="$("$writer" antigravity 2026-11-05T17:00 2>&1)"
code=$?
[[ $code -eq 0 ]] || fail "a valid call: exit $code: $out"
[[ "$(cat "$file")" == $'antigravity\t2026-11-05T17:00' ]] || fail "a valid call: the file holds: $(cat "$file")"
refuse_all 'one line'

"$writer" opencode 2026-11-06T09:30 > /dev/null 2>&1
[[ "$(cat "$file")" == $'antigravity\t2026-11-05T17:00\nopencode\t2026-11-06T09:30' ]] || fail "a second call: the file holds: $(cat "$file")"

# The hook reads the line: refused one minute before the reset, passed at the reset.
# hook <epoch>: exit code of agent-guard.sh for a delegate_task to antigravity at that time.
hook() {
    local input="$tmp/input.json"
    plutil -create xml1 "$input"
    plutil -insert tool_name -string mcp__t3-code__delegate_task "$input"
    plutil -insert tool_input -dictionary "$input"
    plutil -insert tool_input.task -string 'Review the diff.' "$input"
    plutil -insert tool_input.target -dictionary "$input"
    plutil -insert tool_input.target.providerInstanceId -string antigravity "$input"
    plutil -insert tool_input.target.model -string gemini-4-argon "$input"
    plutil -convert json "$input"
    PROVIDER_LIMIT_NOW=$1 "$repo/.claude/hooks/agent-guard.sh" < "$input" > /dev/null 2>&1
}
reset="$(date -j -u -f %Y-%m-%dT%H:%M:%S 2026-11-05T17:00:00 +%s)"
hook $((reset - 60))
[[ $? -eq 2 ]] || fail "the hook passed a delegate_task one minute before the reset that the script wrote"
hook "$reset"
[[ $? -eq 0 ]] || fail "the hook refused a delegate_task at the reset that the script wrote"

if [[ $failures -ne 0 ]]; then
    echo "$failures failed"
    exit 1
fi
