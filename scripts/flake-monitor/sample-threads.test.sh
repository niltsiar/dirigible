#!/bin/bash
# Check that sample-threads.py marks a pool thread whose stack `sample` cut at an async thunk,
# prints its gate frame, and does not mark the main thread. Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/sample-threads.py"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A call graph in the format of /usr/bin/sample: one main thread in a suite init, and one pool
# thread in Gate.waitOnce with no queue label and no job frame.
cat > "$tmp/sample.txt" <<'GRAPH'
Analysis of sampling swiftpm-testing-helper (pid 1) every 1 millisecond
Call graph:
    100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 100 start  (in dyld) + 3056  [0x1]
    +   100 swift_task_switch  (in libswift_Concurrency.dylib) + 1  [0x2]
    +     90 PendingTakeTests.init()  (in DirigiblePackageTests) + 10  [0x3]  PendingTakeTests.swift:20
    +       90 fcntl  (in libsystem_kernel.dylib) + 10  [0x4]
    100 Thread_2
    + 100 thunk for @escaping @isolated(any) @callee_guaranteed @async () -> (@out A)  (in DirigiblePackageTests) + 1  [0x5]
    +   100 closure #2 in AutosaveTests.aSaveWaits()  (in DirigiblePackageTests) + 77  [0x6]  AutosaveTests.swift:48
    +     100 Gate.waitOnce()  (in DirigiblePackageTests) + 626  [0x7]  Support.swift:252
    +       100 semaphore_timedwait_trap  (in libsystem_kernel.dylib) + 10  [0x8]

Total number in stack (recursive counted multiple, when >=5):
GRAPH
out="$(python3 "$script" "$tmp/sample.txt" 2>&1)"
grep -q '^POOL 100 Thread_2' <<< "$out" || { echo "FAIL: the cut pool thread is marked POOL: $out"; failures=$((failures + 1)); }
grep -q 'Gate.waitOnce()' <<< "$out" || { echo "FAIL: the gate frame of the pool thread is printed: $out"; failures=$((failures + 1)); }
grep -q '^     100 Thread_1' <<< "$out" || { echo "FAIL: the main thread is printed without POOL: $out"; failures=$((failures + 1)); }
grep -q 'PendingTakeTests.init()' <<< "$out" || { echo "FAIL: the init frame of the main thread is printed: $out"; failures=$((failures + 1)); }

# A busy pool thread in a synchronous test body: no label, no async thunk. Only its ID in
# pool-threads.txt marks it. An unlisted thread of the same shape stays unmarked, and so does the
# same thread ID while it serves a serial queue.
cat > "$tmp/sample.txt" <<'GRAPH'
Call graph:
    100 Thread_3
    + 100 partial apply for implicit closure #1 in static FinalizeTests.aTest()  (in DirigiblePackageTests) + 1  [0x1]
    +   100 SegmentWriter.write(_:frames:)  (in DirigiblePackageTests) + 10  [0x2]  SegmentWriter.swift:69
    100 Thread_4
    + 100 partial apply for implicit closure #1 in static FinalizeTests.bTest()  (in DirigiblePackageTests) + 1  [0x3]
    +   100 SegmentWriter.write(_:frames:)  (in DirigiblePackageTests) + 10  [0x4]  SegmentWriter.swift:69
    100 Thread_3   DispatchQueue_9: Dirigible.DeviceWriter.mic  (serial)
    + 100 SegmentWriter.write(_:frames:)  (in DirigiblePackageTests) + 10  [0x5]  SegmentWriter.swift:69

Total number in stack (recursive counted multiple, when >=5):
GRAPH
printf '3\n' > "$tmp/pool-threads.txt"
out="$(python3 "$script" "$tmp/sample.txt" 2>&1)"
grep -q '^POOL 100 Thread_3' <<< "$out" || { echo "FAIL: a listed pool thread is marked POOL: $out"; failures=$((failures + 1)); }
grep -q '^     100 Thread_4' <<< "$out" || { echo "FAIL: an unlisted thread is not marked POOL: $out"; failures=$((failures + 1)); }
grep -q '^     100 Thread_3   DispatchQueue_9' <<< "$out" || { echo "FAIL: a listed thread on a serial queue is not marked POOL: $out"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "sample-threads tests: all passed"
exit $((failures > 0))
