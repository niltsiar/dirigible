#!/usr/bin/env python3
"""Run one source-mutation control and never leave the mutant in the tree.

Usage: mutate.py [--expect <text>] [--timeout <seconds>] [--side-effects] <file> <old text> <new text> <log>
                 <build command> <test command> [<old text 2> <new text 2> ...] [--in=<file 2> <old> <new> ...]
       mutate.py [--expect <text>] [--timeout <seconds>] [--allow-side-effects] --replay <old log> <new log>

The script records the SHA-256 of <file>, replaces the one exact copy of <old text> with
<new text> (and of each extra pair, in order: one mutant with several edits), runs <build command>, then <test command> (each with bash -o pipefail -c), writes the raw output
to <log>, restores the file, and checks the hash. Each command runs with pipefail, so a failed
build piped into `tail` is a failed build, not a stale binary under test. It prints one result:
  killed        the build passed and the test failed (exit 0)
  killed (hang) the test ran past --timeout; the script killed it (exit 0)
  survived      the build and the test passed (exit 1)
  BUILD FAILED  the mutant did not build, so it proves nothing (exit 2)
  WRONG FAILURE the test failed, but its output has no <text> of --expect (exit 4); it prints
                up to 10 compared lines that hold ✘, failed, or error
  NO TESTS      the test passed, but it ran no test: the filter matched nothing (exit 5)
  stopped       SIGINT, SIGTERM, or SIGHUP stopped the run; the files are restored (exit 130)
With --expect, a kill counts only when the output of the test has <text>, for example the
message of the assertion that the control must break. A progress line (a test started or passed)
does not count: it names every test of the filter, also on a run where another test fails. A crash or a trap also fails the test.
With --timeout, a test that runs longer than <seconds> is killed with all its processes, and the
result is a kill: use it for a mutant that makes the code hang (a display loop), which no wait
limit inside the test can stop. With --expect too, a hang is a kill only when <text> came before
the kill: a failure report that hangs (a large value in an assert message) prints no text and
gives WRONG FAILURE. --replay runs the control of <old log> again from its header
(file, pairs, commands, expect, timeout) and writes <new log>; an option on the command line
wins over the header. A replay needs a time limit, from the header or --timeout: with none, it
exits 2. When a later commit changed an old text, the replay exits 2, so you write
that mutant again on purpose.
A missing or repeated <old text>, or an extra old text with no new text, exits 2 before any
change. A failed restore exits 3. A control that needs two edits (a guard mutant and the fault
that trips it) is one call with two pairs. An extra argument --in=<file> puts the pairs after it
in <file>: one mutant in two files, with each file hashed and restored. Do not nest mutate.py in the test command: the outer
result line then gives the verdict of the inner script, not of the mutant.
In a git tree, a run holds the lock <git dir>/dirigible-mutate.lock (a folder with the pid), so two
runs never mutate one tree; a second run exits 2, and the lock of a dead process is taken over.
--side-effects marks a control whose test command acts on shared state (it opens Mission Control,
posts HID events, or starts a probe). The log header says so, and --replay of that log exits 2
unless --allow-side-effects is given: a batch replay must not run it by accident.
"""
import ast, hashlib, os, re, shutil, signal, subprocess, sys

args = sys.argv[1:]
expected = timeout = replay = None
side_effects = allow_side_effects = False
while args[:1] in (['--expect'], ['--timeout'], ['--replay'], ['--side-effects'], ['--allow-side-effects']):
    if args[0] == '--side-effects':
        side_effects, args = True, args[1:]
    elif args[0] == '--allow-side-effects':
        allow_side_effects, args = True, args[1:]
    elif args[0] == '--replay':
        if len(args) < 3:
            sys.exit(__doc__)
        replay, args = (args[1], args[2]), args[3:]
    elif len(args) < 2:
        sys.exit(__doc__)
    elif args[0] == '--expect':
        expected, args = args[1], args[2:]
    else:
        timeout, args = float(args[1]), args[2:]

if replay:
    if args:
        sys.exit(__doc__)
    header = {'pairs': []}
    current = None
    for line in open(replay[0], errors='replace').read().splitlines():
        if not line.startswith('# '):
            break
        key, _, value = line[2:].partition(' ')
        if key == 'mutation':
            header['file'] = value.removeprefix('of ')
        elif key == 'in':
            header['pairs'].append('--in=' + value)
        elif key in ('-', '+'):
            header['pairs'].append(ast.literal_eval(value))
        elif key in ('build:', 'test:'):
            header[key[:-1]] = value
        elif key in ('expect:', 'timeout:'):
            header[key[:-1]] = ast.literal_eval(value)
        elif key == 'side-effects:':
            side_effects = True
    if side_effects and not allow_side_effects:
        print(f'mutate: the test command of {replay[0]} has side effects; pass --allow-side-effects', file=sys.stderr)
        sys.exit(2)
    pairs = header['pairs']
    args = [header['file'], pairs[0], pairs[1], replay[1], header['build'], header['test']] + pairs[2:]
    expected = expected if expected is not None else header.get('expect')
    timeout = timeout if timeout is not None else header.get('timeout')
    if timeout is None:
        # A replay with no limit hung for hours in a batch (start-window Phase 7).
        print(f'mutate: {replay[0]} has no time limit; pass --timeout <seconds>', file=sys.stderr)
        sys.exit(2)

if len(args) < 6:
    sys.exit(__doc__)
path, old, new, log, build, test = args[:6]
# The pairs of each file, in order. --in=<file> starts the pairs of another file.
edits = {path: [(old, new)]}
current, rest = path, args[6:]
while rest:
    if rest[0].startswith('--in='):
        current, rest = rest[0][len('--in='):], rest[1:]
        edits.setdefault(current, [])
    elif len(rest) < 2 or rest[1].startswith('--in='):
        print('mutate: an extra old text has no new text', file=sys.stderr)
        sys.exit(2)
    else:
        edits[current].append((rest[0], rest[1]))
        rest = rest[2:]
digests, mutants = {}, {}
for name, pairs in edits.items():
    original = open(name, 'rb').read()
    digests[name] = hashlib.sha256(original).hexdigest()
    mutant_text = original.decode()
    for old, new in pairs:
        if mutant_text.count(old) != 1:
            print(f'mutate: the old text is in {name} {mutant_text.count(old)} times, not once: {old!r}',
                  file=sys.stderr)
            sys.exit(2)
        mutant_text = mutant_text.replace(old, new)
    mutants[name] = mutant_text


def descendants(pid):
    """The processes under `pid`, also the ones in another process group (a test runner makes one)."""
    table = subprocess.run(['ps', '-A', '-o', 'pid=,ppid='], capture_output=True, text=True).stdout.split()
    children = {}
    for child, parent in zip(table[::2], table[1::2]):
        children.setdefault(int(parent), []).append(int(child))
    found, todo = [], [pid]
    while todo:
        for child in children.get(todo.pop(), []):
            found.append(child)
            todo.append(child)
    return found


def run(command, out, limit=None):
    """The exit status of `command`, or None when it ran past `limit` seconds."""
    process = subprocess.Popen(
        ['bash', '-o', 'pipefail', '-c', command], stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        kill_tree(process)
        return None
    except KeyboardInterrupt:
        kill_tree(process)
        raise


def kill_tree(process):
    tree = descendants(process.pid)
    # The group has ended: ESRCH after the wait, and on macOS EPERM while its leader is an
    # unreaped zombie.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (PermissionError, ProcessLookupError):
        pass
    for pid in tree:
        try:
            os.kill(pid, signal.SIGKILL)
        except (PermissionError, ProcessLookupError):
            pass
    process.wait()


def stop(signum, frame):
    raise KeyboardInterrupt


# A stop by SIGINT, SIGTERM, or SIGHUP (a closed terminal) restores the files. A background job
# of a shell starts with SIGINT ignored, so SIGINT gets the handler too.
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, stop)


def take_lock():
    """The lock folder in the git dir of the tree, or None outside a git tree. Exits 2 while a live process holds it."""
    found = subprocess.run(['git', 'rev-parse', '--absolute-git-dir'], capture_output=True, text=True)
    if found.returncode:
        return None
    lock = os.path.join(found.stdout.strip(), 'dirigible-mutate.lock')
    for _ in range(2):
        try:
            os.mkdir(lock)
        except FileExistsError:
            try:
                os.kill(int(open(os.path.join(lock, 'pid')).read()), 0)
            except ProcessLookupError:
                shutil.rmtree(lock, ignore_errors=True)
                continue
            except (OSError, ValueError):
                pass  # No pid yet: the holder is between its mkdir and its write.
            print(f'mutate: another mutate.py run holds {lock}; wait for it to end', file=sys.stderr)
            sys.exit(2)
        with open(os.path.join(lock, 'pid'), 'w') as pid:
            pid.write(str(os.getpid()))
        return lock
    print(f'mutate: cannot take {lock}', file=sys.stderr)
    sys.exit(2)


lock = take_lock()
backups = {name: log + '.orig' + (str(n) if n else '') for n, name in enumerate(edits)}
for name, backup in backups.items():
    shutil.copyfile(name, backup)
hung = stopped = built = tested = False
test_start = 0
try:
    for name, mutant_text in mutants.items():
        with open(name, 'w') as mutant:
            mutant.write(mutant_text)
    with open(log, 'w') as out:
        out.write(f'# mutation of {path}\n')
        for name, pairs in edits.items():
            if name != path:
                out.write(f'# in {name}\n')
            for old, new in pairs:
                out.write(f'# - {old!r}\n# + {new!r}\n')
        out.write(f'# build: {build}\n# test: {test}\n')
        if expected is not None:
            out.write(f'# expect: {expected!r}\n')
        if timeout is not None:
            out.write(f'# timeout: {timeout!r}\n')
        if side_effects:
            out.write('# side-effects: yes\n')
        out.flush()
        built = run(build, out) == 0
        out.flush()
        test_start = out.tell()
        status = run(test, out, timeout) if built else 1
        hung = status is None
        tested = status == 0
except KeyboardInterrupt:
    stopped = True
finally:
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)
    for name, backup in backups.items():
        shutil.copyfile(backup, name)
    if lock:
        shutil.rmtree(lock, ignore_errors=True)
for name, backup in backups.items():
    if hashlib.sha256(open(name, 'rb').read()).hexdigest() != digests[name]:
        print(f'mutate: the restore of {name} failed; the copy is {backup}', file=sys.stderr)
        sys.exit(3)
if stopped:
    with open(log, 'a') as out:
        out.write('# result: stopped\n')
    print(f'stopped: {log}')
    sys.exit(130)
if hung:
    result, code = 'killed (hang)', 0
else:
    result, code = ('BUILD FAILED', 2) if not built else (('survived', 1) if tested else ('killed', 0))
if code == 1:
    # A filter that matches no test passes: that run proves nothing (SwiftPM and Swift Testing lines).
    with open(log, errors='replace') as done:
        done.seek(test_start)
        output = done.read()
    if 'No matching test cases were run' in output or re.search(r'Test run with 0 tests', output):
        result, code = 'NO TESTS', 5
if code == 0 and expected is not None:
    with open(log, errors='replace') as done:
        done.seek(test_start)
        # A progress line of each run (a test started or passed) names every test in the filter,
        # so a test name found only there is not a reason for the kill.
        reasons = [line for line in done.read().splitlines()
                   if not line.lstrip().startswith(('◇', '✔'))
                   and not re.match(r"\s*Test (Case|Suite) '.*' (started|passed)", line)]
        if not any(expected in line for line in reasons):
            result, code = 'WRONG FAILURE', 4
with open(log, 'a') as out:
    out.write(f'# result: {result}\n')
print(f'{result}: {log}')
if code == 4:
    # The compared failure lines, so the next --expect copies their printed form.
    print('\n'.join([line for line in reasons if re.search('✘|failed|error', line, re.I)][:10]))
sys.exit(code)
