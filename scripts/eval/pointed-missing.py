#!/usr/bin/env python3
"""List tracked files of a commit that a copy names by full path but does not hold.
Usage: pointed-missing.py <copy folder> <commit>"""
import os, subprocess, sys
copy, commit = sys.argv[1], sys.argv[2]
tracked = subprocess.run(["git", "ls-tree", "-r", "--name-only", commit], capture_output=True, text=True, check=True).stdout.split()
text = {}
for root, _, files in os.walk(copy):
    for f in files:
        p = os.path.join(root, f)
        try:
            text[os.path.relpath(p, copy)] = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            pass
for t in tracked:
    if os.path.exists(os.path.join(copy, t)):
        continue
    srcs = [s for s, body in text.items() if t in body]
    if srcs:
        print(f"MISSING {t} <- {','.join(sorted(srcs)[:5])}")
