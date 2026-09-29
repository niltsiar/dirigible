#!/usr/bin/env python3
"""Prints, for each thread of a macOS `sample` call graph, the test-code frames and the leaf
frame that hold at least half of its samples. It marks the threads of the concurrency pool
with POOL. Usage: sample-threads.py <sample file>

`sample` names a busy pool thread with no queue label. So a thread is a pool thread when its ID
is in pool-threads.txt of the folder of the sample (the flake monitor writes it), when a sample
file of that folder shows the ID with a `.cooperative` label, or when its stack starts at an
async thunk."""
import glob
import os
import re
import sys

text = open(sys.argv[1]).read()
folder = os.path.dirname(os.path.abspath(sys.argv[1]))
pool_ids = set()
if os.path.exists(os.path.join(folder, 'pool-threads.txt')):
    pool_ids |= set(open(os.path.join(folder, 'pool-threads.txt')).read().split())
for other in glob.glob(os.path.join(folder, '*.txt')):
    pool_ids |= set(re.findall(r'Thread_(\d+)\s+DispatchQueue_\d+: [^\n]*\.cooperative', open(other).read()))
graph = text.split('Call graph:')[1].split('Total number in stack')[0]
threads = re.split(r'\n    (?=\d+ Thread_)', graph)
for t in threads[1:]:
    lines = t.split('\n')
    head = lines[0]
    total = int(head.split()[0])
    # `sample` cuts the bottom of a deep pool stack, so a pool thread can start at an async
    # thunk with no queue label and no job frame.
    first = lines[1] if len(lines) > 1 else ''
    ids = re.match(r'\d+ Thread_(\d+)', head)
    # A worker thread can serve the pool and a GCD queue at other times, so a queue label other
    # than the pool wins over the ID.
    other_queue = 'DispatchQueue_' in head and '.cooperative' not in head
    pool = not other_queue and (
        '.cooperative' in head or 'swift_job_run' in t or '@async' in first or (ids and ids.group(1) in pool_ids))
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
