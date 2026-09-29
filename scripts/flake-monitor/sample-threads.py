#!/usr/bin/env python3
"""Prints, for each thread of a macOS `sample` call graph, the test-code frames and the leaf
frame that hold at least half of its samples. It marks the threads of the concurrency pool
with POOL. Usage: sample-threads.py <sample file>"""
import re
import sys

text = open(sys.argv[1]).read()
graph = text.split('Call graph:')[1].split('Total number in stack')[0]
threads = re.split(r'\n    (?=\d+ Thread_)', graph)
for t in threads[1:]:
    lines = t.split('\n')
    head = lines[0]
    total = int(head.split()[0])
    # `sample` cuts the bottom of a deep pool stack, so a pool thread can start at an async
    # thunk with no queue label and no job frame.
    first = lines[1] if len(lines) > 1 else ''
    pool = 'com.apple.main-thread' not in head and (
        '.cooperative' in head or 'swift_job_run' in t or '@async' in first)
    rows = []
    for line in lines[1:]:
        m = re.match(r'^[ +!:|]*(\d+) (.*)$', line)
        if not m:
            continue
        n, frame = int(m.group(1)), m.group(2)
        if n * 2 < total:
            continue
        rows.append((n, frame))
    keep = [f"{n} {f[:110]}" for n, f in rows if re.search(r'Tests\.|Dirigible[A-Z]|Gate\.|DispatchSemaphore|semaphore', f)]
    leaf = rows[-1] if rows else (0, '')
    if not pool and not keep:
        continue
    print(('POOL ' if pool else '     ') + head[:90])
    for k in keep[-4:]:
        print('      ', k)
    print('       leaf:', leaf[0], leaf[1][:100])
