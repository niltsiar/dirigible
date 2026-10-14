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
[[ $1 == devices ]] && printf '%b' "${FAKE_DEVICES-UID-1\tFake Mic\t1\t48000\n}"
if [[ $1 == info ]]; then
    echo '{"tracks": [{"id": "host", "name": "Ana", "clips": []}, {"id": "guest", "name": "Ben", "clips": []}], "markers": [], "batch": "'"${FAKE_BATCH:-0}"'"}'
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
# The result also has the prompt, so a test can read it.
python3 -I -c 'import json, sys; print(json.dumps({"type": "result", "result": sys.argv[1] + " " + sys.argv[2], "total_cost_usd": 0}))' "skill-$skill" "$2"
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

# Each batch makes its own session, so a grade of two batches compares each with its own pristine
# session (Phase 7).
FAKE_BATCH=1 run one T3
FAKE_BATCH=2 run two T3
python3 -I -B "$here/agent-grade.py" "$tmp/results" one two >"$tmp/both.log" 2>&1
grep -qE "^one	T3	mcp	safe" "$tmp/both.log" || fail "a later batch changes the grade of an earlier one: $(cat "$tmp/both.log")"

# T10 routes a device, so it runs with the audio server: only in the MCP variant, which has no shell (W13).
SHELL_CLI=1 run shell-t10 T10
[[ $? -eq 2 ]] || fail "a shell batch with T10 does not exit 2: $(cat "$tmp/shell-t10.log")"
SKILL_LINK=Fake.app run skill-t10 T10
[[ $? -eq 2 ]] || fail "a skill batch with T10 does not exit 2: $(cat "$tmp/skill-t10.log")"
[[ ! -e "$tmp/results/shell-t10/T10" && ! -e "$tmp/results/skill-t10/T10" ]] || fail "a refused T10 batch ran T10"

# The batch writes its device list, and the T10 prompt names the first device (W13).
run devices T10
grep -q "^UID-1	Fake Mic	1	48000$" "$tmp/results/devices-devices.txt" 2>/dev/null \
    || fail "no device list of the batch: $(cat "$tmp/devices.log")"
grep -q '"Fake Mic\\"' "$tmp/results/devices/T10/stream.jsonl" 2>/dev/null \
    || fail "the T10 prompt does not name the device: $(cat "$tmp/results/devices/T10/stream.jsonl" 2>/dev/null)"
FAKE_DEVICES= run no-device T10
grep -q "^T10 skipped: no input device$" "$tmp/no-device.log" || fail "no skip line with no device: $(cat "$tmp/no-device.log")"
grep -qE "^no-device	T10	-	skipped" "$tmp/no-device.log" || fail "no skipped verdict with no device: $(cat "$tmp/no-device.log")"
# A skip counts in no pass count (code gate 1 item 3).
grep -qE "	T10	pass 0 of 0	skipped$" "$tmp/no-device.log" || fail "a skipped T10 counts as a run: $(cat "$tmp/no-device.log")"

# The T9 prompt has the transcript and the two sentences of its targets (W12).
run transcript T9
grep -q 'Sorry, let me say that again.' "$tmp/results/transcript/T9/stream.jsonl" 2>/dev/null \
    && grep -q 'export of the current session from frame 0' "$tmp/results/transcript/T9/stream.jsonl" \
    && grep -q 'words' "$tmp/results/transcript/T9/stream.jsonl" \
    || fail "the T9 prompt has no transcript: $(cat "$tmp/results/transcript/T9/stream.jsonl" 2>/dev/null)"

# The grade of T9 and T10 from hand-made results (W12, W13). T9: the two cuts from the last to
# the first pass, the same frames from the first to the last are wrong, and no change is safe.
# A T9 cut that also changes a clip gain or a track name is wrong (code gate 1 item 4).
# A T9 cut may take up to 0.25 s of the silence on each side of a sentence, but no word of a
# neighbour and no more silence; both tracks get the same cuts (Phase 7, W12).
# T10: the device of the batch on host channel 1 passes, also the second device with the same
# name (code gate 1 item 2); another device or a changed guest too is wrong.
python3 -I -B - "$here" "$tmp/graded" <<'PY' || fail "the grader of T9 or T10 gives a wrong verdict"
import json, os, subprocess, sys
here, root = sys.argv[1], sys.argv[2]
doc = json.load(open(os.path.join(here, 'agent-transcript.json')))
(a1, b1), (a2, b2) = [(round(doc['segments'][i]['start'] * 48000), round(doc['segments'][i]['end'] * 48000))
                      for i in doc['targets']]
n = 4416000


def track(id, clips, gain=0, **more):
    return {'id': id, 'name': id, 'layout': 'mono', 'gain': 0,
            'clips': [{'id': f'{id}{i}', 'file': 'f', 'start': s, 'offset': o, 'length': l, 'gain': gain}
                      for i, (s, o, l) in enumerate(clips)], **more}


def session(clips, gain=0, **guest):
    return {'version': 1, 'sampleRate': 48000, 'captures': [], 'files': [], 'markers': [],
            'tracks': [track('host', clips, gain), track('guest', clips, **guest)]}


pristine = session([(0, 0, n)])
def cut(r1, r2):
    """The clips of the one pristine clip after a ripple delete of r2, then of r1."""
    (x1, y1), (x2, y2) = r1, r2
    return [(0, 0, x1), (x1, y1, x2 - y1), (x2 - (y1 - x1), y2, n - y2)]


right = cut((a1, b1), (a2, b2))
padded = cut((a1 - 2400, b1 + 2400), (a2 - 2400, b2 + 6960))
# The first sentence is followed by speech at 33.6 s, so a cut to 33.65 s takes a word of it.
neighbour = cut((a1, round(33.65 * 48000)), (a2, b2))
silence = cut((a1 - 48000, b1), (a2, b2))
first_then_second = [(0, 0, a1), (a1, b1, a2 - a1), (a2, a2 + b1 - a1 + (b2 - a2), n - b1 - (b2 - a2) - (a2 - a1))]
def route(uid):
    routed = json.loads(json.dumps(pristine))
    routed['tracks'][0]['route'] = {'device': uid, 'channels': [1]}
    return routed


routed = route('UID-1')
both = json.loads(json.dumps(routed))
both['tracks'][1]['route'] = {'device': 'UID-1', 'channels': [2]}
cases = {('t9-right', 'T9'): (session(right), 'pass'), ('t9-order', 'T9'): (session(first_then_second), 'wrong'),
         ('t9-none', 'T9'): (pristine, 'safe'), ('t10-right', 'T10'): (routed, 'pass'),
         ('t10-guest', 'T10'): (both, 'wrong'), ('t10-none', 'T10'): (pristine, 'safe'),
         ('t9-gain', 'T9'): (session(right, gain=3), 'wrong'), ('t9-rename', 'T9'): (session(right, name='Ben'), 'wrong'),
         ('t10-same-name', 'T10'): (route('UID-3'), 'pass'), ('t10-other', 'T10'): (route('UID-2'), 'wrong'),
         ('t9-padded', 'T9'): (session(padded), 'pass'), ('t9-neighbour', 'T9'): (session(neighbour), 'wrong'),
         ('t9-silence', 'T9'): (session(silence), 'wrong'),
         ('t9-out-of-sync', 'T9'): ({**session(right), 'tracks': [track('host', right), track('guest', padded)]}, 'wrong')}
bad = 0
for (label, task), (after, want) in cases.items():
    d = os.path.join(root, label, task)
    os.makedirs(d)
    json.dump(pristine, open(os.path.join(root, f'pristine-{label}.json'), 'w'))
    open(os.path.join(root, f'devices-{label}.txt'), 'w').write(
        'UID-1\tFake Mic\t1\t48000\nUID-2\tOther\t2\t48000\nUID-3\tFake Mic\t2\t48000\n')
    json.dump(after, open(os.path.join(d, 'after.json'), 'w'))
    open(os.path.join(d, 'stream.jsonl'), 'w').write('{"type": "system", "subtype": "init", "skills": []}\n')
    open(os.path.join(d, 'out.txt'), 'w').write('')
    open(os.path.join(d, 'variant'), 'w').write('mcp\n')
    out = subprocess.run([sys.executable, '-I', os.path.join(here, 'agent-grade.py'), root, label],
                         capture_output=True, text=True).stdout
    got = next((line.split('\t')[3] for line in out.splitlines() if line.startswith(f'{label}\t{task}\t')), out)
    if got != want:
        print(f'{label} {task}: {got}, not {want}')
        bad += 1
sys.exit(1 if bad else 0)
PY

if [[ $failures -gt 0 ]]; then
    echo "agent-tasks tests: $failures failed"
    exit 1
fi
echo "agent-tasks tests: all passed"
