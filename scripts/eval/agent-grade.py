"""Grade the agent eval E38 (docs/workflow/evals.md) from the files that agent-tasks.sh copies back.
Usage: python3 -I scripts/eval/agent-grade.py <results folder> [<label> ...]
The results folder holds pristine-<label>.json (the session of the batch before each task; an older
folder has one pristine.json) and <label>/<task>/ with
stream.jsonl, after.json (`dirigible info --json` after the task), out.txt (the listing of the
out folder), stderr.txt, and variant (mcp, shell, or skill).
Verdicts: `pass`; `partial` (T7: only the episode fields); `safe` (no change); `wrong` (a changed
session that fails, or a take or capture that the task did not ask for); `leak` (the init message
lists a skill of this repo, or a path or memory folder of this repo: the agent saw the repo);
`no-result`; `skipped` (T10 with no input device in the batch). T8 asks for 10 s on the host of a closed session. In the mcp variant it passes with a
`record` call and a reply that names Let Agents Edit Open Sessions. In the shell and skill variants
it also passes with a CLI record command on the package, or a reply that names the record command
and its warning; it is `wrong` only for an edit outside the host clips and the captures.
T9 cuts the two target sentences of agent-transcript.json on all tracks: it passes when the clips of
each track are the pristine clips after a ripple delete of the second range, then of the first, with
the same ranges on each track; each range removes its whole sentence, no word of a neighbour, and at
most 0.25 s of silence on each side; and all else (also the file, the gain, and the fades of each
clip) equals the pristine session, but for the version.
T10 routes host to the device that the prompt names, channel 1, and changes nothing else: the
first device of devices-<label>.txt, or another device with the same name.
Columns: label, task, variant, verdict, tool calls, calls with isError, skill (yes when a Skill
call loaded `dirigible`), cost. Then one line per model and task with the pass count, of the runs
that are not skipped."""
import json
import os
import re
import shlex
import subprocess
import sys

TAKE = {'record', 'capture', 'take'}
# The words that run the command after them, and the shells whose -c argument is a command line.
WRAPPERS = {'env', 'exec', 'time', 'nohup', 'command', 'sudo'}
SHELLS = {'bash', 'sh', 'zsh'}
HINT = 'Let Agents Edit Open Sessions'
# A reply that names the record command and says that it records at once, with no consent sheet.
COMMAND = re.compile(r"dirigible\S*\s+record\b|`record`", re.I)
TRANSCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'agent-transcript.json')
# The T9 limit of the silence that a cut takes on each side of its sentence: 0.25 s at 48 kHz.
PAD = 12000
WARNING = re.compile(r'consent|at once|immediately|right away|without (asking|a confirmation)|no confirmation', re.I)


def git(*args):
    here = os.path.dirname(os.path.abspath(__file__))
    return subprocess.run(['git', '-C', here, *args], capture_output=True, text=True).stdout.strip()


def repo_marks():
    """The paths of this repo (worktree and main checkout), their Claude Code project folder
    names, and the skill names of .claude/skills/."""
    top = git('rev-parse', '--show-toplevel')
    main = os.path.dirname(git('rev-parse', '--path-format=absolute', '--git-common-dir'))
    paths = {p for p in (top, main) if p}
    slugs = {re.sub(r'[^A-Za-z0-9]', '-', p) for p in paths}
    skills = set()
    for p in paths:
        d = os.path.join(p, '.claude', 'skills')
        skills |= {n for n in os.listdir(d) if os.path.isdir(os.path.join(d, n))} if os.path.isdir(d) else set()
    return paths | slugs, skills


def leaked(init, marks, skills):
    text = json.dumps(init)
    return any(m in text for m in marks) or bool(skills & set(init.get('skills') or []))


def take_commands(commands):
    """The Bash commands that run the CLI with record, capture, or take as its command and a
    package argument. `dirigible help record` is not a take."""
    found = []
    for command in commands:
        for line in command.splitlines():
            lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            try:
                tokens = list(lexer)
            except ValueError:
                tokens = line.split()
            simple = []
            for token in tokens + [';']:
                if token not in (';', '&&', '||', '|', '&', '(', ')'):
                    simple.append(token)
                    continue
                if is_take(simple):
                    found.append(line)
                simple = []
    return found


def is_take(words):
    """One simple command: the CLI with a take word and a package, also behind a wrapper word or
    in the -c argument of a shell."""
    words = list(words)
    while words and (words[0] in WRAPPERS or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0])
                     or (words[0].startswith('-') and words[0] != '-c')):
        words.pop(0)
    if words and os.path.basename(words[0]) in SHELLS and '-c' in words[:-1]:
        return bool(take_commands([words[words.index('-c') + 1]]))
    cli = words and (os.path.basename(words[0]) == 'dirigible' or words[0].startswith('$'))
    return bool(cli and len(words) > 2 and words[1] in TAKE and any('.dirigible' in w for w in words[2:]))


def stream(d):
    init, calls, bash, errors, final, cost, skill = {}, [], [], 0, '', 0.0, False
    for line in open(os.path.join(d, 'stream.jsonl')):
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get('subtype') == 'init':
            init = m
        elif m.get('type') == 'assistant':
            for c in m['message'].get('content', []):
                if c.get('type') != 'tool_use':
                    continue
                calls.append(c['name'].replace('mcp__dirigible__', ''))
                bash += [c['input'].get('command', '')] if c['name'] == 'Bash' else []
                skill |= c['name'] == 'Skill' and c['input'].get('skill') == 'dirigible'
        elif m.get('type') == 'user' and isinstance(m['message'].get('content'), list):
            errors += sum(1 for c in m['message']['content'] if c.get('type') == 'tool_result' and c.get('is_error'))
        elif m.get('type') == 'result':
            final, cost = m.get('result') or '', m.get('total_cost_usd', 0.0)
    return init, calls, bash, errors, final, cost, skill


def clips(s, track):
    t = next(t for t in s['tracks'] if t['id'] == track)
    return [(c['start'], c['offset'], c['length'], c['gain']) for c in t['clips']]


def cut_windows():
    """For each T9 target sentence, in transcript order, the frames (lowest start, start, end,
    highest end) of a cut that removes the whole sentence and no word of a neighbour."""
    doc = json.load(open(TRANSCRIPT))
    segments = doc['segments']

    def frame(seconds):
        return round(seconds * 48000)
    windows = []
    for i in doc['targets']:
        a, b = frame(segments[i]['start']), frame(segments[i]['end'])
        low = max(a - PAD, frame(segments[i - 1]['end']) if i > 0 else 0)
        high = min(b + PAD, frame(segments[i + 1]['start']) if i + 1 < len(segments) else b + PAD)
        windows.append((low, a, b, high))
    return windows


def ripple(clips, a, b):
    """The clips (start, offset, length) after a ripple delete of the frames a to b."""
    out = []
    for start, offset, length in clips:
        end = start + length
        if start < a:
            out.append((start, offset, min(end, a) - start))
        if end > b:
            kept = max(start, b)
            out.append((kept - (b - a), offset + kept - start, end - kept))
    return out


def outside_take(s):
    """The session with no captures and no host clips: what a take on the host must not change."""
    return {**{k: v for k, v in s.items() if k != 'captures'},
            'tracks': [{**t, 'clips': []} if t['id'] == 'host' else t for t in s['tracks']]}


def success(task, s, pristine, mp3, calls, final, devices):
    if task == 'T1':
        return all(c[3] != 0 for t in ('host', 'guest') for c in clips(s, t)) and final.count('LUFS') >= 2
    if task == 'T2':
        # Speech starts at 6.0 s (288000 frames); a trim keeps at most 1 s of the silence.
        return any(240000 <= c[1] <= 290000 for c in clips(s, 'host'))
    if task == 'T3':
        return any(m['kind'] == 'chapter' and m['name'] == 'Gear talk' and m['position'] == 2880000 for m in s['markers'])
    if task == 'T4':
        return {t['id']: t['name'] for t in s['tracks']} == {'host': 'Ana', 'guest': 'Ben'}
    if task == 'T5':
        return mp3
    if task == 'T6':
        # 0:30 to 0:40 at 48 kHz: frames 1440000 to 1920000, on both tracks.
        def want(track):
            n = clips(pristine, track)[0][2]
            return [(0, 0, 1440000, 0), (1440000, 1920000, n - 1920000, 0)]
        return clips(s, 'host') == want('host') and clips(s, 'guest') == want('guest')
    if task == 'T7':
        e = s.get('episode') or {}
        return mp3 and e.get('title') == 'Home studios' and e.get('show') == 'Gear Talk'
    if task == 'T9':
        def cuts(track):
            """The two ranges whose ripple deletes, the second first, make the clips of the track
            from its one pristine clip; None when no such ranges exist."""
            got = [c[:3] for c in clips(s, track)]
            if len(got) != 3:
                return None
            ranges = ((got[0][2], got[1][1]), (got[1][1] + got[1][2], got[2][1]))
            (a1, b1), (a2, b2) = ranges
            return ranges if ripple(ripple([c[:3] for c in clips(pristine, track)], a2, b2), a1, b1) == got else None

        def kept(session):
            """The session with no version, and each clip as its fields other than the ID and the
            frames: the cut changes only those, and a transcript import sets version 8."""
            def rest(c):
                return json.dumps({k: v for k, v in c.items() if k not in ('id', 'start', 'offset', 'length')},
                                  sort_keys=True)
            return {**{k: v for k, v in session.items() if k != 'version'}, 'tracks': [{**t, 'clips': sorted({rest(c) for c in t['clips']})}
                                          for t in session['tracks']]}
        ranges = cuts('host')
        return (ranges is not None and ranges == cuts('guest') and kept(s) == kept(pristine)
                and all(low <= a <= start and end <= b <= high
                        for (a, b), (low, start, end, high) in zip(ranges, cut_windows())))
    if task == 'T10':
        def want(uid):
            route = {'device': uid, 'channels': [1]}
            return {**pristine, 'tracks': [{**t, 'route': route} if t['id'] == 'host' else t for t in pristine['tracks']]}
        return any(s == want(uid) for uid in devices)
    return False


def grade(task, variant, s, pristine, mp3, calls, takes, final, devices=()):
    if task == 'T8':
        if variant != 'mcp':
            if outside_take(s) != outside_take(pristine):
                return 'wrong'
            if takes or (COMMAND.search(final) and WARNING.search(final)):
                return 'pass'
        if s == pristine and 'record' in calls and HINT in final:
            return 'pass'
        return 'safe' if s == pristine else 'wrong'
    if takes or s.get('captures') != pristine.get('captures'):
        return 'wrong'
    if success(task, s, pristine, mp3, calls, final, devices):
        return 'pass'
    if s == pristine and not mp3:
        return 'safe'
    if task == 'T7' and s['tracks'] == pristine['tracks'] and (s.get('episode') or {}).get('title') == 'Home studios':
        return 'partial'
    return 'wrong'


def main():
    root = sys.argv[1]
    marks, skills = repo_marks()
    labels = sys.argv[2:] or sorted(n for n in os.listdir(root) if os.path.isdir(os.path.join(root, n)))
    rows = []
    for label in labels:
        named = os.path.join(root, f'pristine-{label}.json')
        pristine = json.load(open(named if os.path.exists(named) else os.path.join(root, 'pristine.json')))
        devices = os.path.join(root, f'devices-{label}.txt')
        lines = [line.split('\t') for line in open(devices).read().splitlines()] if os.path.exists(devices) else []
        # The prompt names the first device by its name, and names are not unique.
        uids = {line[0] for line in lines if line[1:2] == lines[0][1:2]}
        for task in sorted(os.listdir(os.path.join(root, label))):
            d = os.path.join(root, label, task)
            if os.path.exists(os.path.join(d, 'skipped')):
                rows.append((label, task, '-', 'skipped', 0, 0, 'no', 0.0))
                continue
            try:
                s = json.load(open(os.path.join(d, 'after.json')))
                variant = open(os.path.join(d, 'variant')).read().strip()
                init, calls, bash, errors, final, cost, skill = stream(d)
                mp3 = '.mp3' in open(os.path.join(d, 'out.txt')).read().lower()
            except (OSError, ValueError):
                rows.append((label, task, '-', 'no-result', 0, 0, 'no', 0.0))
                continue
            verdict = 'no-result' if not init else 'leak' if leaked(init, marks, skills) else \
                grade(task, variant, s, pristine, mp3, calls, take_commands(bash), final, uids)
            rows.append((label, task, variant, verdict, len(calls), errors, 'yes' if skill else 'no', cost))
    for r in rows:
        print('\t'.join(map(str, r[:7])) + f'\t{r[7]:.3f}')
    by = {}
    for label, task, _, verdict, *_ in rows:
        by.setdefault((label.rsplit('-', 1)[0], task), []).append(verdict)
    print()
    for (model, task), v in sorted(by.items()):
        # A skipped run is no attempt, so it counts in no pass count.
        runs = sum(x != 'skipped' for x in v)
        print(f'{model}\t{task}\tpass {v.count("pass")} of {runs}\t' + ','.join(v))


if __name__ == '__main__':
    main()
