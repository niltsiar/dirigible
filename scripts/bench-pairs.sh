#!/bin/bash
# Compare the optimized benches of this tree with main in alternate pairs (decision 0022 rule: no
# case worse than main by more than 10 % or 1 ms, the larger). An A/A pair of main runs first: when
# main alone moves more than the rule, the pairs cannot give a verdict. The pair count is fixed
# before the runs, and every pair counts: a pick of the clean pairs after the results is not a
# verdict (timeline-navigation Phase 7). Each run writes the load of the Mac next to its log.
# A run holds the build lock (with-lock.sh) once for all its benches; --compare takes no lock.
# Usage: scripts/bench-pairs.sh <main worktree> <test filter> <pairs> <new out folder>
#        scripts/bench-pairs.sh --compare <out folder>
# Per case the compare prints VERIFIED (no pair over the rule), NOT VERIFIED (each pair over the
# rule), or INCONCLUSIVE (the A/A spread is over the rule, or only some pairs are). Exit 1 when a
# case is NOT VERIFIED, a bench failed (load.txt), or a log has no sample.
set -euo pipefail
if [[ "${1:-}" != "--compare" ]]; then
  main="${1:?usage: bench-pairs.sh <main worktree> <filter> <pairs> <out folder>}"
  filter="${2:?filter}"; count="${3:?pairs}"; out="${4:?out folder}"
  root="$(cd "$(dirname "$0")/.." && pwd)"
  [[ ! -e "$out" ]] || { echo "bench-pairs: $out exists; give a new folder" >&2; exit 2; }
  # with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
  [[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$root/scripts/with-lock.sh" "$0" "$@"
  mkdir -p "$out"; out="$(cd "$out" && pwd)"
  run() { # run <tree> <log name>
    echo "$2 $(date +%T) $(uptime | sed 's/.*load/load/')" >> "$out/load.txt"
    (cd "$1" && scripts/bench.sh "$filter") > "$out/$2.log" 2>&1 || echo "$2: the bench failed" >> "$out/load.txt"
  }
  run "$main" aa-1
  run "$main" aa-2
  for i in $(seq 1 "$count"); do
    run "$main" "main-$i"
    run "$root" "branch-$i"
  done
  set -- --compare "$out"
fi
python3 - "${2:?usage: bench-pairs.sh --compare <out folder>}" <<'PY'
import glob, os, re, statistics, sys
folder = sys.argv[1]
def read(path):
    cases = {}
    for line in open(path, errors='replace'):
        m = re.match(r'(\w+Benchmark .+?): (?:drag )?p50 [0-9.e-]+ seconds, p95 ([0-9.e-]+) seconds', line)
        if m: cases[m.group(1)] = float(m.group(2)) * 1000
    return cases
aa = [read(f'{folder}/aa-{n}.log') for n in (1, 2)]
pairs = []
for n in range(1, 1000):
    a, b = f'{folder}/main-{n}.log', f'{folder}/branch-{n}.log'
    if not (os.path.exists(a) and os.path.exists(b)): break
    pairs.append((read(a), read(b)))
# A failed bench or a side with no sample (a filter that matched no test) gives no verdict.
load = f'{folder}/load.txt'
failed = [l.strip() for l in open(load)] if os.path.exists(load) else []
failed = [l for l in failed if l.endswith('the bench failed')]
empty = [n for n, cases in [('aa-1.log', aa[0]), ('aa-2.log', aa[1])] + [
    (f'{side}-{i}.log', c) for i, pair in enumerate(pairs, 1) for side, c in zip(('main', 'branch'), pair)] if not cases]
if failed or empty:
    for line in failed: print(f'NOT VERIFIED: {line}')
    for name in empty: print(f'NOT VERIFIED: no bench sample in {name}')
    sys.exit(1)
worst = 0
for case in sorted(aa[0]):
    mains = [m[case] for m, _ in pairs if case in m]
    limit = max(0.10 * statistics.median(mains or [aa[0][case]]), 1.0)
    spread = abs(aa[0][case] - aa[1].get(case, aa[0][case]))
    over = sum(1 for m, b in pairs if b.get(case, float('inf')) - m[case] > limit)
    detail = ' '.join(f'{m[case]:.2f}/{b.get(case, float("nan")):.2f}' for m, b in pairs)
    if spread > limit:
        print(f'INCONCLUSIVE {case} (A/A spread {spread:.2f} ms over the rule {limit:.2f} ms)')
    elif over == 0:
        print(f'VERIFIED {case}')
    elif over == len(pairs):
        print(f'NOT VERIFIED {case}'); worst = 1
    else:
        print(f'INCONCLUSIVE {case} ({over} of {len(pairs)} pairs over the rule {limit:.2f} ms)')
    print(f'  main/branch p95 ms per pair: {detail}; A/A {aa[0][case]:.2f}/{aa[1].get(case, float("nan")):.2f}')
sys.exit(worst)
PY
