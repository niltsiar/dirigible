#!/bin/bash
# Check scripts/eval/agent-tasks.sh with a fake claude and a fake dirigible, so no model runs and no
# Swift build is needed. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

tmp="$(mktemp -d /private/tmp/agent-tasks-test-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/Fake.app/Contents/Resources/skills/dirigible"
echo skill >"$tmp/Fake.app/Contents/Resources/skills/dirigible/SKILL.md"
# The fake tool: `create` makes a folder, and `info` prints a session in which T4 passes, so the smoke task passes.
cat >"$tmp/bin/dirigible" <<'EOF'
#!/bin/bash
[[ $1 == create ]] && mkdir -p "$2"
if [[ $1 == info ]]; then
    echo '{"tracks": [{"id": "host", "name": "Ana", "clips": []}, {"id": "guest", "name": "Ben", "clips": []}], "markers": []}'
fi
exit 0
EOF
# The fake claude: an init message, and a result that says whether the skill link resolves.
cat >"$tmp/bin/claude" <<'EOF'
#!/bin/bash
skill=missing
[[ -f .claude/skills/dirigible/SKILL.md ]] && skill=ok
echo '{"type": "system", "subtype": "init", "skills": []}'
echo "{\"type\": \"result\", \"result\": \"skill-$skill\", \"total_cost_usd\": 0}"
EOF
chmod +x "$tmp/bin/dirigible" "$tmp/bin/claude"

# run <label> <task>...: the runner from $tmp with relative paths, with the fake claude on PATH.
run() {
    local label="$1"
    shift
    (cd "$tmp" && PATH="$tmp/bin:$PATH" "$here/agent-tasks.sh" bin/dirigible results sonnet "$label" "$@") \
        >"$tmp/$label.log" 2>&1
}

# A relative SKILL_LINK gives a skill link that resolves (code gate 1 item 3).
SKILL_LINK=Fake.app run skill T5
grep -q skill-ok "$tmp/results/skill/T5/stream.jsonl" 2>/dev/null \
    || fail "a relative SKILL_LINK gives a dangling skill link: $(cat "$tmp/skill.log")"

if [[ $failures -gt 0 ]]; then
    echo "agent-tasks tests: $failures failed"
    exit 1
fi
echo "agent-tasks tests: all passed"
