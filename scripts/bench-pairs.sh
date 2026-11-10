#!/bin/bash
# Compare the optimized benches of this tree with main in alternate pairs (decision 0022 rule: no
# case worse than main by more than 10 % or 1 ms, the larger). An A/A pair of main runs first: when
# main alone moves more than the rule, the pairs cannot give a verdict. The pair count is fixed
# before the runs, and every pair counts: a pick of the clean pairs after the results is not a
# verdict (timeline-navigation Phase 7). Each run writes the load of the Mac next to its log.
# A run holds the build lock (with-lock.sh) once for all its benches; --compare takes no lock.
# Usage: scripts/bench-pairs.sh <main worktree> <test filter> <pairs> <new out folder>
#        scripts/bench-pairs.sh --compare <out folder>
# Per case (its p95, or its p50 for a bench that prints p50 and max) the compare prints VERIFIED
# (no pair over the rule), NOT VERIFIED (each pair over the rule), or INCONCLUSIVE (the A/A spread
# is over the rule, or only some pairs are). Exit 1 when a case is NOT VERIFIED, a log has no
# sample, or a bench failed (load.txt), except for a budget miss: a failed log with samples and a
# report line of 1 test or more whose failed tests (each `✘ Test <name> recorded an issue` line)
# have budget issues only (`budget →` after `(` or `.`) prints a note, and its samples count. An aa
# or main log needs 1 failed test or more (a miss that the branch fixes). A branch log (a miss that
# main shares) needs each failed test to fail in an aa or main log too, and to print a case (a line
# read between its started and end lines) that the test prints in each aa and main log; with no
# failed test or no such case it prints NO VERDICT and exits 1.
# The pairs give the bench verdict of a budget only with clean provenance: the bench.sh line of the
# aa-* and main-* logs names one commit, that of the branch-* logs names one commit, each on a
# clean tree, and the branch commit has the Sources, Tests, Package.swift, Package.resolved, and
# scripts/bench.sh of HEAD of this tree, and the two sides name two commits (no A/A comparison).
# Else --compare prints NOT VERIFIED with the reason and exits 1. A branch commit that differs
# from HEAD only in other paths (docs) passes. A tree is dirty only by a change in those paths. A
# pair run checks the same at its start (exit 2) and before each bench (exit 1 when a HEAD moved),
# and refuses an out folder that git does not ignore in a tree.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" != "--compare" ]]; then
  main="${1:?usage: bench-pairs.sh <main worktree> <filter> <pairs> <out folder>}"
  filter="${2:?filter}"; count="${3:?pairs}"; out="${4:?out folder}"
  [[ ! -e "$out" ]] || { echo "bench-pairs: $out exists; give a new folder" >&2; exit 2; }
  # A log in a git tree that git does not ignore makes that tree dirty, so its benches void.
  parent="$(dirname "$out")"
  while [[ ! -d "$parent" ]]; do parent="$(dirname "$parent")"; done
  if git -C "$parent" rev-parse --show-toplevel > /dev/null 2>&1 &&
      ! git -C "$parent" check-ignore -q "$(cd "$parent" && pwd -P)/${out#"$parent"/}"; then
    echo "bench-pairs: $out is in a git tree and git does not ignore it; give a folder outside or an ignored one" >&2
    exit 2
  fi
  # The provenance of --compare, checked at the start too: a change in a bench input of a tree
  # refuses the run, and a HEAD that moves stops it before the next bench.
  inputs=(Sources Tests Package.swift Package.resolved scripts/bench.sh)
  for tree in "$main" "$root"; do
    [[ -z "$(git -C "$tree" status --porcelain -- "${inputs[@]}")" ]] ||
      { echo "bench-pairs: $tree has a change in the bench inputs (${inputs[*]}); commit it first" >&2; exit 2; }
  done
  heads="$(git -C "$main" rev-parse HEAD) $(git -C "$root" rev-parse HEAD)"
  # with-lock.sh runs this script again with the marker, and the marker stops a second wrap.
  [[ "${DIRIGIBLE_LOCKED_SCRIPT:-}" == "$0" ]] || DIRIGIBLE_LOCKED_SCRIPT="$0" exec "$root/scripts/with-lock.sh" "$0" "$@"
  mkdir -p "$out"; out="$(cd "$out" && pwd)"
  run() { # run <tree> <log name>
    [[ "$(git -C "$main" rev-parse HEAD) $(git -C "$root" rev-parse HEAD)" == "$heads" ]] ||
      { echo "bench-pairs: the HEAD of $main or $root moved during the run; stop before $2" >&2; exit 1; }
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
python3 - "${2:?usage: bench-pairs.sh --compare <out folder>}" "$root" <<'PY'
import glob, os, re, statistics, subprocess, sys
folder, root = sys.argv[1], sys.argv[2]
# The value of a case: its p95, or its p50 when the bench prints p50 and max (NavigationKeyBenchmark,
# whose budget is on the p50).
metric = {}
def cases_of(line):
    m = re.match(r'(\w+Benchmark .+?): (?:drag )?p50 ([0-9.e-]+) seconds, (p95|max) ([0-9.e-]+) seconds', line)
    if not m: return {}
    p95 = m.group(3) == 'p95'
    metric[m.group(1)] = 'p95' if p95 else 'p50'
    return {m.group(1): float(m.group(4) if p95 else m.group(2)) * 1000}
def read(path):
    cases = {}
    for line in open(path, errors='replace'): cases.update(cases_of(line))
    return cases
# The failed tests of a runner log ({name: its issue lines}) and the cases of each test.
def runner(path):
    failed, cases, test = {}, {}, None
    for line in open(path, errors='replace'):
        m = re.match(r'◇ Test (.+?) started\.', line)
        if m:
            test = m.group(1); cases.setdefault(test, set()); continue
        if re.match(r'[✔✘] Test .+? (?:passed|failed) after', line):
            test = None; continue
        m = re.match(r'✘ Test (.+?) recorded an issue at', line)
        if m: failed.setdefault(m.group(1), []).append(line)
        elif test: cases[test].update(cases_of(line))
    return failed, cases
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
# A failed bench with samples, a report line, and budget issues only is a budget miss (header):
# budget_miss gives its note, a NO VERDICT line, or None (the failure stays).
def budget_miss(name):
    path = f'{folder}/{name}.log'
    if not (os.path.exists(path) and read(path) and any(
            re.search(r'Test run with [1-9]', l) for l in open(path, errors='replace'))):
        return None
    failed, cases = runner(path)
    if any(not re.search(r'[(.]budget →', l) for issues in failed.values() for l in issues): return None
    if not name.startswith('branch-'):
        return f'note: {name} failed its asserts after its report line; its samples count' if failed else None
    others = [runner(p) for p in sorted(glob.glob(f'{folder}/aa-*.log') + glob.glob(f'{folder}/main-*.log'))]
    if any(not any(t in f for f, _ in others) for t in failed): return None
    if not failed: return f'NO VERDICT {name}: no failed test'
    for t in failed:
        if not any(all(c in oc.get(t, ()) for _, oc in others) for c in cases.get(t, ())):
            return f'NO VERDICT {name}: {t} has no case with a value on both sides'
    return f'note: shared budget miss in {name}: {", ".join(failed)}'
kept, no_verdict = [], []
for line in failed:
    found = budget_miss(line.split(':')[0])
    if found is None: kept.append(line)
    elif found.startswith('NO VERDICT'): no_verdict.append(found)
    else: print(found)
failed = kept
empty = [n for n, cases in [('aa-1.log', aa[0]), ('aa-2.log', aa[1])] + [
    (f'{side}-{i}.log', c) for i, pair in enumerate(pairs, 1) for side, c in zip(('main', 'branch'), pair)] if not cases]
# Provenance: the first "bench: commit <sha> tree <state>" line of each log.
problems, commits = [], {'aa and main': set(), 'branch': set()}
for path in sorted(glob.glob(f'{folder}/aa-*.log') + glob.glob(f'{folder}/main-*.log') + glob.glob(f'{folder}/branch-*.log')):
    name = os.path.basename(path)
    found = next((m for m in (re.match(r'bench: commit (\S+) tree (\S+)', l) for l in open(path, errors='replace')) if m), None)
    if not found: problems.append(f'no bench commit line in {name}')
    elif found.group(2) != 'clean': problems.append(f'{name} ran on a dirty tree')
    else: commits['branch' if name.startswith('branch-') else 'aa and main'].add(found.group(1))
for side, shas in commits.items():
    if len(shas) > 1: problems.append(f'the {side} logs name {len(shas)} commits')
if len(commits['branch']) == 1 and commits['branch'] == commits['aa and main']:
    problems.append('the main and branch logs name the same commit')
if len(commits['branch']) == 1:
    sha = next(iter(commits['branch']))
    def object_id(rev, path):
        r = subprocess.run(['git', '-C', root, 'rev-parse', '--verify', '-q', f'{rev}:{path}'], capture_output=True, text=True)
        return r.stdout.strip() or 'none'
    for path in ('Sources', 'Tests', 'Package.swift', 'Package.resolved', 'scripts/bench.sh'):
        if object_id(sha, path) != object_id('HEAD', path): problems.append(f'the branch commit differs from HEAD in {path}')
if failed or no_verdict or empty or problems:
    for line in failed: print(f'NOT VERIFIED: {line}')
    for line in no_verdict: print(line)
    for name in empty: print(f'NOT VERIFIED: no bench sample in {name}')
    for problem in problems: print(f'NOT VERIFIED: {problem}')
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
    print(f'  main/branch {metric[case]} ms per pair: {detail}; A/A {aa[0][case]:.2f}/{aa[1].get(case, float("nan")):.2f}')
sys.exit(worst)
PY
