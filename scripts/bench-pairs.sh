#!/bin/bash
# Compare the optimized benches of this tree with main in alternate pairs (decision 0022 rule: no
# case worse than main by more than 10 % or 1 ms, the larger). An A/A pair of main runs first: when
# main alone moves more than the rule, the pairs cannot give a verdict. The pair count is fixed
# before the runs, and every pair counts: a pick of the clean pairs after the results is not a
# verdict (timeline-navigation Phase 7). Each run writes `<run> <time> start <x> end <y>` to load.txt
# from the two `bench: load` lines of its log. A void run (bench.sh exit 76: the load wait ended at
# its cap, or the end load was high) writes `<run>: the bench is void: <its bench: void line>` there
# and ends the set: no later bench runs, and the compare follows.
# A run holds the build lock (with-lock.sh) once for all its benches; --compare takes no lock.
# Usage: scripts/bench-pairs.sh <main worktree> <test filter> <pairs> <new out folder>
#        scripts/bench-pairs.sh --compare <out folder>
#        scripts/bench-pairs.sh --lines <log>
# --lines reads one log with the compare reader and takes no lock: bench.sh runs it on its own log
# after a timed run. It prints `bench: no pairs form: <line>` on stderr for each of the first 5 time
# lines in a suite that no form reads, as printed, then `bench: <k> more lines with no pairs form`
# when there are more, and exits 1 when the log has one.
# Per case (the value of its form, in forms() below) the compare prints VERIFIED (no pair over the
# rule), NOT VERIFIED (each pair over the rule), or INCONCLUSIVE (the A/A spread is over the rule, or
# only some pairs are). A case name that two tests of a log print is one case for each test, named
# "<name> (<test>)". A case in each branch log and in no aa or main log prints NO MAIN SIDE: judge
# it by its absolute budget. A case of a max or a single time (no p50, p95, p90, mean, or p99 on its
# line) is one sample for each run, so the rule would judge noise: it prints NO PAIR RULE with its
# values (main: the aa and main logs) and gets no verdict, unless its smallest branch value is over
# its largest main value by more than the rule of that main value: then it is NOT VERIFIED. A case
# with a value in only some logs of a side, or in no branch log, prints NO VERDICT, and so does a
# time line in a suite that no form reads; each exits 1. These lines print before a failure stops
# the compare. A set with a void line in load.txt prints `NO VERDICT: <run> is void (<reason>)`
# and exits 1 before any other line. Else a set with no aa-2 log, or with no complete main and
# branch pair, prints NO VERDICT and exits 1 before any other line. Exit 1 when a case is
# NOT VERIFIED, a log has no sample, or a bench failed (load.txt), except for a budget miss: a failed
# log with samples, a report line of 1 test or more, and 1 failed test or more (each `✘ Test <name>
# recorded an issue` line, also with the arguments of a parameterized test) prints a note, and its
# samples count. An aa or main log needs no more (a miss that the branch fixes: a bench can assert its
# time with no budget word). A branch log (a miss that main shares) needs budget issues only
# (`budget →` after `(` or `.`), each failed expectation (its test and the source line of its issue)
# to fail in an aa or main log too, and each failed test to print a case (a line read between its
# started and end lines) that the test prints in each aa and main log; with no failed test or no such
# case it prints NO VERDICT and exits 1.
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
if [[ "${1:-}" != "--compare" && "${1:-}" != "--lines" ]]; then
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
  void=""
  run() { # run <tree> <log name>; after a void run, no later bench runs
    [[ -z "$void" ]] || return 0
    [[ "$(git -C "$main" rev-parse HEAD) $(git -C "$root" rev-parse HEAD)" == "$heads" ]] ||
      { echo "bench-pairs: the HEAD of $main or $root moved during the run; stop before $2" >&2; exit 1; }
    local status=0 at loads first last
    at="$(date +%T)"
    (cd "$1" && scripts/bench.sh "$filter") > "$out/$2.log" 2>&1 || status=$?
    loads="$(awk '/^bench: load / { printf " %s", $3 }' "$out/$2.log")"
    read -r first last <<< "${loads:--}"
    echo "$2 $at start $first end ${last:--}" >> "$out/load.txt"
    if [[ $status -eq 76 ]]; then
      echo "$2: the bench is void: $(grep -m 1 '^bench: void: ' "$out/$2.log")" >> "$out/load.txt"
      void=1
    elif [[ $status -ne 0 ]]; then
      echo "$2: the bench failed" >> "$out/load.txt"
    fi
  }
  run "$main" aa-1
  run "$main" aa-2
  for i in $(seq 1 "$count"); do
    run "$main" "main-$i"
    run "$root" "branch-$i"
  done
  set -- --compare "$out"
fi
python3 - "${2:?usage: bench-pairs.sh --compare <out folder> | --lines <log>}" "$root" "$1" <<'PY'
import glob, os, re, statistics, subprocess, sys
folder, root, mode = sys.argv[1:4]
N = r'([0-9][0-9.e-]*)'
metric = {}
# The cases (name, seconds, metric) of a line that a bench prints, from the first form that reads it.
# <S> is the suite of the last "◇ Suite <S> started." line. A line of the base form gives its p95, or
# its p50 when the bench prints p50 and max (NavigationKeyBenchmark, whose budget is on the p50).
# A pane cost line ("hidden ..., shown ..., added p95 ...") gives "<name> added" and "<name> shown",
# each a p95. A "<S>Benchmark split" line only prints the parts of a span (`split` below).
split = re.compile(r'\w+Benchmark split ')
def forms(line, suite):
    if 'over debug budget' in line or split.match(line): return []
    m = re.match(r'(\w+Benchmark .+?): (?:drag )?p50 ([0-9.e-]+) seconds, (p95|max) ([0-9.e-]+) seconds', line)
    if m: return [(m.group(1), float(m.group(4)), 'p95') if m.group(3) == 'p95' else (m.group(1), float(m.group(2)), 'p50')]
    U = r'(?:ms|seconds)'
    # A number of the pane form may be negative.
    P = r'(-?[0-9][0-9.e-]*)'
    m = re.match(rf'(\w+Benchmark .+?): hidden p50 {P} (ms|seconds) p95 {P} {U}, shown p50 {P} {U} p95 {P} {U}, '
                 rf'added p95 {P} {U}', line)
    if m:
        scale = 1000 if m.group(3) == 'ms' else 1
        return [(f'{m.group(1)} added', float(m.group(7)) / scale, 'p95'),
                (f'{m.group(1)} shown', float(m.group(6)) / scale, 'p95')]
    m = re.match(rf'(\w+Benchmark .+?): p50 {N} ms, p95 {N} ms', line)
    if m: return [(m.group(1), float(m.group(3)) / 1000, 'p95')]
    m = re.match(rf'(\w+Benchmark .+?) p95: {N} seconds, p50 {N} seconds', line)
    if m: return [(m.group(1), float(m.group(2)), 'p95')]
    for pattern, suffix, kind in ((rf'(\w+Benchmark .+?): p95 {N} seconds', '', 'p95'),
                                  (rf'(\w+Benchmark .+?): max {N} seconds', '', 'max'),
                                  (rf'(\w+Benchmark .+?): one-off events .*; max {N} seconds', ', one-off', 'max')):
        m = re.match(pattern, line)
        if m: return [(m.group(1) + suffix, float(m.group(2)), kind)]
    m = re.match(rf'(\w+Benchmark): (.+?) in {N} seconds(?::|$)', line)
    if m: return [(f'{m.group(1)} {m.group(2)}', float(m.group(3)), 'time')]
    # "bench report: <S>Benchmark ..." with each "<name> p90 <x> seconds|ms"; a p90 with no unit is no case.
    m = re.match(r'bench report: (\w+Benchmark) ', line)
    found = [(f'{m.group(1)} {name}', float(x) / (1000 if unit == 'ms' else 1), 'p90') for name, x, unit in re.findall(
        rf'(?:^|: |, |\()((?:(?!: |, |\().)+?) p90 {N} (seconds|ms)\b', line[m.end():])] if m else []
    if found: return found
    if line.startswith('bench report: ') and suite and not re.search(r'\w+Benchmark\b', line):
        text = line[len('bench report: '):]
        m = re.match(rf'ride fixture (\S+): size .*?, open {N} seconds, save {N} seconds; .*the ride adds open {N} seconds, save {N} seconds', text)
        if m:
            head = f'{suite} ride fixture {m.group(1)}'
            return [(f'{head} open', float(m.group(2)), 'time'), (f'{head} save', float(m.group(3)), 'time'),
                    (f'{head} adds save', float(m.group(5)), 'time')]
        m = re.match(rf'(.+?): mean {N} seconds, p99 {N} seconds, max {N} seconds', text)
        if m: return [(f'{suite} {m.group(1)} mean', float(m.group(2)), 'mean'), (f'{suite} {m.group(1)} p99', float(m.group(3)), 'p99')]
        m = re.match(rf'(.+?): p50 {N} seconds, p95 {N} seconds', text)
        if m: return [(f'{suite} {m.group(1)}', float(m.group(3)), 'p95')]
        found = [(f'{suite} {t}', float(x), 'time') for t, x in re.findall(rf'(?:^|, )((?:(?!, ).)+?) took {N} seconds', text)]
        if found: return found
    m = re.match(rf'finalize: .*?seconds: {N}', line)
    if m and suite: return [(f'{suite} finalize', float(m.group(1)), 'time')]
    # A plain time at the line end; a statistic word before it (mean, max, p99) is a form of its own.
    m = re.match(rf'(\w+Benchmark .*?:.*?) {N} seconds$', line)
    if m and not re.search(r'(?:^|[\s:])(?:mean|median|min|max|p[0-9]+)$', m.group(1)):
        return [(m.group(1).rstrip(':'), float(m.group(2)), 'time')]
    return []
# A log: its cases ({name: ms}), its failed tests ({name: issue lines}), the cases of each test
# ({test: {name: ms}}, read between its started and end lines), and each time line in a suite that
# no form reads ((suite, the line with each number as N)), and those lines as printed, in order.
logs = {}
def scan(path):
    if path in logs: return logs[path]
    cases, failed, tests, unread, unread_lines = {}, {}, {}, set(), []
    suite, depth, test = None, 0, None
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        m = re.match(r'◇ Suite (\S+) started\.', line)
        if m:
            suite, depth = m.group(1), depth + 1; continue
        if re.match(r'[✔✘] Suite \S+ (?:passed|failed) after', line):
            depth -= 1; continue
        m = re.match(r'◇ Test (.+?) started\.', line)
        if m:
            test = m.group(1); tests.setdefault(test, {}); continue
        if re.match(r'[✔✘] Test .+? (?:passed|failed) after', line):
            test = None; continue
        m = re.match(r'✘ Test (.+?) recorded an issue\b', line)
        if m:
            failed.setdefault(m.group(1), []).append(line); continue
        read_line = forms(line, suite)
        found = {name: seconds * 1000 for name, seconds, _ in read_line}
        metric.update((name, kind) for name, _, kind in read_line)
        cases.update(found)
        if test: tests[test].update(found)
        if (not found and depth > 0 and not re.match(r'[✘✔◇➜↳]|bench:', line) and 'over debug budget' not in line
                and not split.match(line)
                and re.search(r'(?<![\w.])[0-9][0-9.e-]* (?:seconds|ms)\b|seconds: [0-9]', line)):
            unread.add((suite, re.sub(r'[0-9]+(?:\.[0-9]+)?(?:e-?[0-9]+)?', 'N', line)))
            unread_lines.append(line)
    logs[path] = cases, failed, tests, unread, unread_lines
    return logs[path]
if mode == '--lines':
    raw = scan(folder)[4]
    for line in raw[:5]: print(f'bench: no pairs form: {line}', file=sys.stderr)
    if len(raw) > 5: print(f'bench: {len(raw) - 5} more lines with no pairs form', file=sys.stderr)
    sys.exit(1 if raw else 0)
paths = sorted(glob.glob(f'{folder}/aa-*.log') + glob.glob(f'{folder}/main-*.log') + glob.glob(f'{folder}/branch-*.log'))
# A name that two tests of a log print is one case for each test in each log: "<name> (<test>)".
def two_tests(path):
    names = [name for found in scan(path)[2].values() for name in found]
    return {name for name in names if names.count(name) > 1}
twice = set().union(*(two_tests(p) for p in paths))
def read(path):
    cases = dict(scan(path)[0])
    for name in twice & cases.keys():
        del cases[name]
        for test, found in scan(path)[2].items():
            if name in found:
                cases[f'{name} ({test})'] = found[name]
                metric[f'{name} ({test})'] = metric[name]
    return cases
def runner(path): return scan(path)[1:3]
load = f'{folder}/load.txt'
load_lines = [l.strip() for l in open(load)] if os.path.exists(load) else []
# A void run ends the set, so its void line comes before the check for missing logs.
void = [l.split(': the bench is void: ', 1) for l in load_lines if ': the bench is void: ' in l]
if void:
    for run, line in void: print(f'NO VERDICT: {run} is void ({line.removeprefix("bench: void: ")})')
    sys.exit(1)
if not all(os.path.exists(f'{folder}/aa-{n}.log') for n in (1, 2)):
    print('NO VERDICT: no complete A/A pair'); sys.exit(1)
aa = [read(f'{folder}/aa-{n}.log') for n in (1, 2)]
pairs = []
for n in range(1, 1000):
    a, b = f'{folder}/main-{n}.log', f'{folder}/branch-{n}.log'
    if not (os.path.exists(a) and os.path.exists(b)): break
    pairs.append((read(a), read(b)))
if not pairs:
    print('NO VERDICT: no complete main and branch pair'); sys.exit(1)
# A failed bench or a side with no sample (a filter that matched no test) gives no verdict.
failed = [l for l in load_lines if l.endswith('the bench failed')]
# A failed bench with samples, a report line, and budget issues only is a budget miss (header):
# budget_miss gives its note, a NO VERDICT line, or None (the failure stays).
def budget_miss(name):
    path = f'{folder}/{name}.log'
    if not (os.path.exists(path) and read(path) and any(
            re.search(r'Test run with [1-9]', l) for l in open(path, errors='replace'))):
        return None
    failed, cases = runner(path)
    if not name.startswith('branch-'):
        return f'note: {name} failed its asserts after its report line; its samples count' if failed else None
    if any(not re.search(r'[(.]budget →', l) for issues in failed.values() for l in issues): return None
    others = [runner(p) for p in sorted(glob.glob(f'{folder}/aa-*.log') + glob.glob(f'{folder}/main-*.log'))]
    # An expectation is its test and the source line of its issue.
    def expectations(f):
        return {(t, m.group(1) if m else l) for t, issues in f.items() for l in issues
                for m in [re.search(r' at ([^\s:]+:[0-9]+):[0-9]+: ', l)]}
    if not expectations(failed) <= set().union(*(expectations(f) for f, _ in others)): return None
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
# A case needs a value in each log of both sides; a time line that no form reads gives no verdict.
worst, judged = 0, []
main_side, branch_side = aa + [m for m, _ in pairs], [b for _, b in pairs]
for case in sorted(set().union(*main_side, *branch_side)):
    on_main, on_branch = [case in c for c in main_side], [case in c for c in branch_side]
    if all(on_main) and all(on_branch):
        if metric[case] not in ('max', 'time'): judged.append(case); continue
        values = [' '.join(f'{c[case]:.2f}' for c in side) for side in (main_side, branch_side)]
        top = max(c[case] for c in main_side)
        if min(c[case] for c in branch_side) - top > max(0.10 * top, 1.0):
            print(f'NOT VERIFIED {case}: each branch value is over each main value (main {values[0]}; branch {values[1]})')
            worst = 1
        else:
            print(f'NO PAIR RULE {case}: one sample for each run (main {values[0]}; branch {values[1]}); '
                  'judge it by its absolute budget')
    elif all(on_branch) and not any(on_main): print(f'NO MAIN SIDE {case}: judge it by its absolute budget')
    else:
        print(f'NO VERDICT {case}: a value on one side only'); worst = 1
for suite, line in sorted(set().union(*(scan(p)[3] for p in paths))):
    print(f'NO VERDICT {suite}: the compare reads no case of the line "{line}"'); worst = 1
if failed or no_verdict or empty or problems:
    for line in failed: print(f'NOT VERIFIED: {line}')
    for line in no_verdict: print(line)
    for name in empty: print(f'NOT VERIFIED: no bench sample in {name}')
    for problem in problems: print(f'NOT VERIFIED: {problem}')
    sys.exit(1)
for case in judged:
    limit = max(0.10 * statistics.median([m[case] for m, _ in pairs] or [aa[0][case]]), 1.0)
    spread = abs(aa[0][case] - aa[1][case])
    over = sum(1 for m, b in pairs if b[case] - m[case] > limit)
    detail = ' '.join(f'{m[case]:.2f}/{b[case]:.2f}' for m, b in pairs)
    if spread > limit:
        print(f'INCONCLUSIVE {case} (A/A spread {spread:.2f} ms over the rule {limit:.2f} ms)')
    elif over == 0:
        print(f'VERIFIED {case}')
    elif over == len(pairs):
        print(f'NOT VERIFIED {case}'); worst = 1
    else:
        print(f'INCONCLUSIVE {case} ({over} of {len(pairs)} pairs over the rule {limit:.2f} ms)')
    print(f'  main/branch {metric[case]} ms per pair: {detail}; A/A {aa[0][case]:.2f}/{aa[1][case]:.2f}')
sys.exit(worst)
PY
