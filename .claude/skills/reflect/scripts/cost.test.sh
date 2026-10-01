#!/bin/bash
# Check each line that cost.sh prints for a fixture run folder: the phase blocks of decisions.tsv,
# the check and bench logs and their repeats, the controls, the late on-screen findings, the
# missed unknowns, the friction rows, the agents and the idle gaps of a transcript, and the pace
# lines from a fake gh. Check the lines with no transcript, with a failed gh, and for a folder with
# no logs/ and no controls/. Check that
# scripts/bench.sh prints its bench line before the build. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cost="$here/cost.sh"
bench="$(cd "$here/../../../../scripts" && pwd)/bench.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

run="$tmp/2026-09-20-fixture"
mkdir -p "$run/logs" "$run/controls/replay" "$run/controls/replay-old" "$run/pairs-a" "$run/logs/pairs-b"
{
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n'
  printf '2026-09-20T08:20\t1\tanalysis\tw\te\tdone\n'
  printf '2026-09-20T08:30\t2\tplan; missed unknown U9\tw\te\tdone\n'
  printf '2026-09-20T08:40\t2\tCorrection of the 08:30 row\tw\te\tdone\n'
  printf '2026-09-20T09:00\t4\tslice 1\tit failed once\te\tdone\n'
  printf '2026-09-20T10:00\t4\tk1 control\tw\tcontrols/k1.log\tsurvived\n'
  printf '2026-09-20T10:30\t7\tFinding V1 (NOT VERIFIED, C1 on screen)\tw\te\tback to Phase 4\n'
  printf '2026-09-20T11:00\t4\tfix V1\tw\te\tone flake\n'
  printf '2026-09-20T11:20\t7\tC2 re-check\tw\te\tVERIFIED\n'
  printf '2026-09-20T11:30\t9\tland\tw\te\tmerged\n'
} > "$run/decisions.tsv"
printf -- '- Landed: PR https://github.com/o/r/pull/7, merged.\n' > "$run/run.md"

printf 'check-changed: commit aaa tree dirty base  targets test\nclasses: tests\ntargets: test\nrisk: no\n' > "$run/logs/s1-check.log"
printf 'check-changed: commit aaa tree dirty base none targets test-filter\ntargets: test-filter\n' > "$run/logs/s1-filter.log"
printf 'check-changed: commit bbb tree clean base ccc targets check test-slow\ntargets: check test-slow\n' > "$run/logs/verify-check.log"
printf 'Current branch x is up to date.\ncheck-changed: commit bbb tree clean base ccc targets check test-slow\ntargets: check test-slow\n' > "$run/logs/land.log"
printf 'classes: docs tests\ntargets: check test-slow\nrisk: no\n' > "$run/logs/old-check.log"
printf "scripts/bench.sh 'LiveBench'\nbench: commit bbb tree clean filter LiveBench\n" > "$run/logs/b1.log"
printf 'bench: commit bbb tree clean filter LiveBench\n' > "$run/logs/b2.log"
printf "scripts/bench.sh 'LiveBench'\n" > "$run/logs/b3.log"
printf 'notes\n' > "$run/logs/row.txt"
: > "$run/pairs-a/load.txt"
: > "$run/logs/pairs-b/load.txt"
for k in k1 k2 k3; do printf '# mutation of A.swift\n# result: killed\n' > "$run/controls/$k.log"; done
printf 'backup\n' > "$run/controls/k1.log.orig"
printf '# replay k1\n# result: killed\n' > "$run/controls/replay/k1.log"
printf '# replay k2\n# result: killed\n' > "$run/controls/replay/k2.log"
cp "$run/controls/replay/k1.log" "$run/controls/replay-old/k1.log"
# The folder birth time: on APFS, a modification time before the birth time moves the birth time.
touch -t 202609200800 "$run"

transcript="$tmp/t.jsonl"
cat > "$transcript" <<'EOF'
{"type":"mode","mode":"normal"}
{"type":"user","timestamp":"2026-09-20T08:00:00.000Z","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"2026-09-20T08:01:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-09-20T08:02:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}},{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","timestamp":"2026-09-20T08:14:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-09-20T08:15:30.000Z","message":{"content":[{"type":"text","text":"Agent"},{"type":"tool_use","name":"Agent","input":{}}]}}
EOF

bin="$tmp/bin"
mkdir "$bin"
# The fake gh logs its arguments and prints merged pull requests: one on each day from 09-08 to
# 09-18, two on 09-19, and PR 7 on 09-20 at 12:00Z. FAKE_GH=fail exits 1.
cat > "$bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
[[ "${FAKE_GH:-}" == fail ]] && exit 1
{
  for d in 08 09 10 11 12 13 14 15 16 17 18; do echo "{\"number\":1$d,\"createdAt\":\"2026-09-${d}T10:00:00Z\",\"mergedAt\":\"2026-09-${d}T10:00:30Z\",\"title\":\"t\"}"; done
  echo '{"number":5,"createdAt":"2026-09-19T09:00:00Z","mergedAt":"2026-09-19T09:00:30Z","title":"t"}'
  echo '{"number":6,"createdAt":"2026-09-19T23:00:00Z","mergedAt":"2026-09-19T23:59:00Z","title":"t"}'
  echo '{"number":7,"createdAt":"2026-09-20T11:59:30Z","mergedAt":"2026-09-20T12:00:00Z","title":"t"}'
} | paste -sd, - | sed 's/^/[/; s/$/]/'
EOF
chmod +x "$bin/gh"

want="run: 2026-09-20-fixture
open: 2026-09-20T08:00
phase 1: 2026-09-20T08:00 to 2026-09-20T08:20, 20 min
phase 2: 2026-09-20T08:20 to 2026-09-20T08:40, 20 min
phase 4: 2026-09-20T08:40 to 2026-09-20T10:00, 80 min
phase 7: 2026-09-20T10:00 to 2026-09-20T10:30, 30 min
phase 4: 2026-09-20T10:30 to 2026-09-20T11:00, 30 min
phase 7: 2026-09-20T11:00 to 2026-09-20T11:20, 20 min
phase 9: 2026-09-20T11:20 to 2026-09-20T11:30, 10 min
checks: 5 logs, 1 filtered, 3 push checks, 1 repeated (same commit and targets)
benches: 3 bench logs, 2 pairs sets, 1 repeated (same commit and filter)
controls: 3 written, 2 replayed
late on-screen: 1
missed unknowns: 1
friction: 4
agents: 3
idle: 12 min in 1 gaps over 5 min
pace: 2026-09-20-fixture open to merge 4.0 h
pace: merges per day 2026-09-11 1 2026-09-12 1 2026-09-13 1 2026-09-14 1 2026-09-15 1 2026-09-16 1 2026-09-17 1 2026-09-18 1 2026-09-19 2 2026-09-20 1"

# check <name> <want> [args]: cost.sh exits 0 and prints each line of <want>, in order, and no other line.
check() {
  local name="$1" expect="$2" out code
  shift 2
  out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$@" 2>&1)"
  code=$?
  [[ $code -eq 0 ]] || fail "$name: exit $code: $out"
  if [[ "$out" != "$expect" ]]; then
    fail "$name: the output differs:"
    diff <(echo "$expect") <(echo "$out")
  fi
}

: > "$tmp/gh.log"
check 'a run with a transcript' "$want" "$run" "$transcript"
grep -qx 'gh pr list --state merged --limit 100 --json number,createdAt,mergedAt,title' "$tmp/gh.log" || fail "gh arguments: $(cat "$tmp/gh.log")"

no_transcript="$(sed -e 's/^agents: .*/agents: no transcript/' -e 's/^idle: .*/idle: no transcript/' <<<"$want")"
check 'no transcript' "$no_transcript" "$run"

no_gh="$(grep -v '^pace: ' <<<"$no_transcript")
pace: no gh data"
FAKE_GH=fail check 'gh fails' "$no_gh" "$run"

# A run folder with no logs/ and no controls/ (the early runs): zero counts, and the pace lines.
bare="$tmp/2026-09-19-bare"
mkdir "$bare"
cp "$run/decisions.tsv" "$run/run.md" "$bare/"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$bare" 2>&1)" || fail "no logs and no controls: exit $?: $out"
for line in 'checks: 0 logs, 0 filtered, 0 push checks, 0 repeated (same commit and targets)' \
  'benches: 0 bench logs, 0 pairs sets, 0 repeated (same commit and filter)' 'controls: 0 written, 0 replayed' 'friction: 4'; do
  grep -qxF -- "$line" <<<"$out" || fail "no logs and no controls: no line '$line' in: $out"
done
grep -q '^pace: merges per day ' <<<"$out" || fail "no logs and no controls: no pace line: $out"

out="$("$cost" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "no argument: exit $code: $out"

# bench.sh prints `bench: commit <HEAD> tree <clean|dirty> filter <filter>` before the build. A fake
# swift on PATH stands for the build and the test run.
b="$tmp/bench-repo"
mkdir -p "$b/scripts" "$b/Sources/App" "$b/Tests"
cp "$bench" "$b/scripts/bench.sh"
printf '// swift-tools-version:6.0\n' > "$b/Package.swift"
printf '{}\n' > "$b/Package.resolved"
printf '@main\nstruct App {}\n' > "$b/Sources/App/App.swift"
printf '.build\n' > "$b/.gitignore"
printf '#!/bin/bash\nexit 0\n' > "$bin/swift"
chmod +x "$bin/swift"
git -C "$b" init -q
git -C "$b" add -A
git -C "$b" commit -q -m base
head="$(git -C "$b" rev-parse HEAD)"
out="$(cd "$b" && PATH="$bin:$PATH" scripts/bench.sh FooBench 2>&1)" || fail "bench.sh on a clean tree exits $?: $out"
[[ "$(head -n 1 <<<"$out")" == "bench: commit $head tree clean filter FooBench" ]] || fail "bench.sh on a clean tree: $out"
echo x > "$b/x.txt"
out="$(cd "$b" && PATH="$bin:$PATH" scripts/bench.sh FooBench 2>&1)" || fail "bench.sh on a dirty tree exits $?: $out"
[[ "$(head -n 1 <<<"$out")" == "bench: commit $head tree dirty filter FooBench" ]] || fail "bench.sh on a dirty tree: $out"

[[ $failures -eq 0 ]] && echo "cost tests: all passed"
exit $((failures > 0))
