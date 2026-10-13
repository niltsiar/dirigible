#!/bin/bash
# Check scripts/eval/agent-tasks.sh with a fake claude and a fake dirigible, so no model runs and no
# Swift build is needed, and the take match of scripts/eval/agent-grade.py. Run by `make test-hooks`.
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
    [[ -z ${FAKE_WARNING:-} ]] || echo "warning: a file is short" >&2
fi
exit 0
EOF
# The fake claude: an init message, and a result that says whether the skill link resolves.
cat >"$tmp/bin/claude" <<'EOF'
#!/bin/bash
skill=missing
[[ -f .claude/skills/dirigible/SKILL.md ]] && skill=ok
# On T2, remove the out folder, so the step after the claude run fails.
[[ $2 != *"trim the silence"* ]] || rm -rf ../out
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

# A warning of `dirigible info` on stderr does not go into after.json (code gate 1 item 7).
FAKE_WARNING=1 run warning T5
python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$tmp/results/warning/T5/after.json" 2>/dev/null \
    || fail "a stderr warning makes after.json invalid: $(cat "$tmp/warning.log")"

# A failed task fails the batch and leaves no task folder (code gate 1 item 8).
before="$(ls -d /private/tmp/dirigible-e38-* 2>/dev/null | wc -l)"
if run broken T2 T3; then
    fail "a failed task gives exit 0: $(cat "$tmp/broken.log")"
fi
grep -q "the runner failed on T2$" "$tmp/broken.log" || fail "the runner does not name the failed task: $(cat "$tmp/broken.log")"
after="$(ls -d /private/tmp/dirigible-e38-* 2>/dev/null | wc -l)"
[[ $after -le $before ]] || fail "a failed task leaves $((after - before)) task folders in /private/tmp"

# The grader sees a CLI take behind a wrapper word or in bash -c (code gate 1 item 6).
python3 -I -B - "$here/agent-grade.py" <<'PY' || fail "the grader misses a CLI take behind a wrapper"
import importlib.util, sys
spec = importlib.util.spec_from_file_location('grade', sys.argv[1])
grade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grade)
cli, package = '/private/tmp/t/dirigible', '/private/tmp/t/Show.dirigible'
takes = [
    f'{cli} record {package} --seconds 10 --arm host',
    f'X=1 {cli} record {package} --seconds 10 --arm host',
    f'env DIRIGIBLE_MCP_SOCKET=x {cli} record {package} --seconds 10 --arm host',
    f'env -i {cli} capture place {package} take1-1-1',
    f'exec {cli} record {package} --seconds 10 --arm host',
    f'time nohup {cli} take finalize {package}',
    f'cd /private/tmp && bash -c "{cli} record {package} --seconds 10 --arm host"',
    f"sh -c '{cli} record {package} --seconds 1 --arm host'",
]
safe = [f'{cli} help record', f'{cli} info {package}', f'env {cli} loudness {package}']
missed = [c for c in takes if not grade.take_commands([c])]
wrong = [c for c in safe if grade.take_commands([c])]
for c in missed:
    print('missed:', c)
for c in wrong:
    print('not a take:', c)
sys.exit(1 if missed or wrong else 0)
PY

if [[ $failures -gt 0 ]]; then
    echo "agent-tasks tests: $failures failed"
    exit 1
fi
echo "agent-tasks tests: all passed"
