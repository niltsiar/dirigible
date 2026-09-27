#!/usr/bin/env python3
"""Run one source-mutation control and never leave the mutant in the tree.

Usage: mutate.py [--expect <text>] [--timeout <seconds>] <file> <old text> <new text> <log>
                 <build command> <test command> [<old text 2> <new text 2> ...]

The script records the SHA-256 of <file>, replaces the one exact copy of <old text> with
<new text> (and of each extra pair, in order: one mutant with several edits), runs <build command>, then <test command> (each with bash -o pipefail -c), writes the raw output
to <log>, restores the file, and checks the hash. Each command runs with pipefail, so a failed
build piped into `tail` is a failed build, not a stale binary under test. It prints one result:
  killed        the build passed and the test failed (exit 0)
  killed (hang) the test ran past --timeout; the script killed it (exit 0)
  survived      the build and the test passed (exit 1)
  BUILD FAILED  the mutant did not build, so it proves nothing (exit 2)
  WRONG FAILURE the test failed, but its output has no <text> of --expect (exit 4)
With --expect, a kill counts only when the output of the test has <text>, for example the
message of the assertion that the control must break. A crash or a trap also fails the test.
With --timeout, a test that runs longer than <seconds> is killed with its process group, and the
result is a kill: use it for a mutant that makes the code hang (a display loop), which no wait
limit inside the test can stop.
A missing or repeated <old text>, or an extra old text with no new text, exits 2 before any
change. A failed restore exits 3. A control that needs two edits (a guard mutant and the fault
that trips it) is one call with two pairs. Do not nest mutate.py in the test command: the outer
result line then gives the verdict of the inner script, not of the mutant.
"""
import hashlib, os, shutil, signal, subprocess, sys

args = sys.argv[1:]
expected = timeout = None
while args[:1] in (['--expect'], ['--timeout']):
    if len(args) < 2:
        sys.exit(__doc__)
    elif args[0] == '--expect':
        expected, args = args[1], args[2:]
    else:
        timeout, args = float(args[1]), args[2:]

if len(args) < 6:
    sys.exit(__doc__)
if len(args) % 2 == 1:
    print('mutate: an extra old text has no new text', file=sys.stderr)
    sys.exit(2)
path, old, new, log, build, test = args[:6]
pairs = [(old, new)] + list(zip(args[6::2], args[7::2]))
original = open(path, 'rb').read()
digest = hashlib.sha256(original).hexdigest()
text = original.decode()
mutant_text = text
for old, new in pairs:
    if mutant_text.count(old) != 1:
        print(f'mutate: the old text is in {path} {mutant_text.count(old)} times, not once: {old!r}', file=sys.stderr)
        sys.exit(2)
    mutant_text = mutant_text.replace(old, new)


def run(command, out, limit=None):
    """The exit status of `command`, or None when it ran past `limit` seconds."""
    process = subprocess.Popen(
        ['bash', '-o', 'pipefail', '-c', command], stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return process.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return None


backup = log + '.orig'
shutil.copyfile(path, backup)
hung = False
try:
    with open(path, 'w') as mutant:
        mutant.write(mutant_text)
    with open(log, 'w') as out:
        out.write(f'# mutation of {path}\n')
        for old, new in pairs:
            out.write(f'# - {old!r}\n# + {new!r}\n')
        out.write(f'# build: {build}\n# test: {test}\n')
        if expected is not None:
            out.write(f'# expect: {expected!r}\n')
        if timeout is not None:
            out.write(f'# timeout: {timeout!r}\n')
        out.flush()
        built = run(build, out) == 0
        out.flush()
        test_start = out.tell()
        status = run(test, out, timeout) if built else 1
        hung = status is None
        tested = status == 0
finally:
    shutil.copyfile(backup, path)
if hashlib.sha256(open(path, 'rb').read()).hexdigest() != digest:
    print(f'mutate: the restore of {path} failed; the copy is {backup}', file=sys.stderr)
    sys.exit(3)
if hung:
    result, code = 'killed (hang)', 0
else:
    result, code = ('BUILD FAILED', 2) if not built else (('survived', 1) if tested else ('killed', 0))
if code == 0 and not hung and expected is not None:
    with open(log, errors='replace') as done:
        done.seek(test_start)
        if expected not in done.read():
            result, code = 'WRONG FAILURE', 4
with open(log, 'a') as out:
    out.write(f'# result: {result}\n')
print(f'{result}: {log}')
sys.exit(code)
