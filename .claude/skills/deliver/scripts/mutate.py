#!/usr/bin/env python3
"""Run one source-mutation control and never leave the mutant in the tree.

Usage: mutate.py <file> <old text> <new text> <log> <build command> <test command>

The script records the SHA-256 of <file>, replaces the one exact copy of <old text> with
<new text>, runs <build command>, then <test command> (each with bash -c), writes the raw output
to <log>, restores the file, and checks the hash. It prints one result:
  killed        the build passed and the test failed (exit 0)
  survived      the build and the test passed (exit 1)
  BUILD FAILED  the mutant did not build, so it proves nothing (exit 2)
A missing or repeated <old text> exits 2 before any change. A failed restore exits 3.
"""
import hashlib, shutil, subprocess, sys

if len(sys.argv) != 7:
    sys.exit(__doc__)
path, old, new, log, build, test = sys.argv[1:]
original = open(path, 'rb').read()
digest = hashlib.sha256(original).hexdigest()
text = original.decode()
if text.count(old) != 1:
    print(f'mutate: the old text is in {path} {text.count(old)} times, not once', file=sys.stderr)
    sys.exit(2)
backup = log + '.orig'
shutil.copyfile(path, backup)
try:
    with open(path, 'w') as mutant:
        mutant.write(text.replace(old, new))
    with open(log, 'w') as out:
        out.write(f'# mutation of {path}\n# - {old!r}\n# + {new!r}\n# build: {build}\n# test: {test}\n')
        out.flush()
        built = subprocess.call(['bash', '-c', build], stdout=out, stderr=subprocess.STDOUT) == 0
        tested = built and subprocess.call(['bash', '-c', test], stdout=out, stderr=subprocess.STDOUT) == 0
finally:
    shutil.copyfile(backup, path)
if hashlib.sha256(open(path, 'rb').read()).hexdigest() != digest:
    print(f'mutate: the restore of {path} failed; the copy is {backup}', file=sys.stderr)
    sys.exit(3)
result, code = ('BUILD FAILED', 2) if not built else (('survived', 1) if tested else ('killed', 0))
with open(log, 'a') as out:
    out.write(f'# result: {result}\n')
print(f'{result}: {log}')
sys.exit(code)
