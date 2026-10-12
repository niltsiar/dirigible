#!/bin/bash
# Check each line that cost.sh prints for a fixture run folder: the phase blocks of decisions.tsv,
# the check and bench logs and their repeats, the controls, the late on-screen findings, the missed
# unknowns by result token, the critical findings of the review files, the friction rows by result
# token, the run window, the agents, the workflows, and the idle gaps of a transcript in that window,
# and the pace lines from a fake gh. Check the lines with no transcript, with a failed gh, and for a
# folder with no logs/ and no controls/. Check that scripts/bench.sh prints its bench line before
# the build.
# Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cost="$here/cost.sh"
bench="$(cd "$here/../../../../scripts" && pwd)/bench.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE CHECK_LOAD_MAX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TZ=UTC
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

run="$tmp/2026-09-20-fixture"
mkdir -p "$run/logs" "$run/controls/replay" "$run/controls/replay-old" "$run/pairs-a" "$run/logs/pairs-b"
{
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n'
  printf '2026-09-20T08:20\t1\tanalysis\tw\te\tdone\n'
  printf '2026-09-20T08:30\t2\tplan; missed unknown U9\tw\te\tdone\n'
  printf '2026-09-20T08:35\t2\tU13: friction counts rows with NOT VERIFIED, survived, flake, failed, or missed unknown\tw\te\tdefault; C7.2\n'
  printf '2026-09-20T08:36\t2\tU9 from the premortem\tw\te\tmissed unknown U9\n'
  printf '2026-09-20T08:40\t2\tCorrection of the 08:30 row\tw\te\tdone\n'
  printf '2026-09-20T09:00\t4\tslice 1\tit failed once\te\tdone\n'
  printf '2026-09-20T09:30\t4\tslice 2\tw\te\tDone; no flake in this check\n'
  printf '2026-09-20T09:40\t4\teval\tw\te\tDC4 FAIL on E1, E4\n'
  printf '2026-09-20T09:45\t4\tplan fixes\tw\te\t4 failed fixes corrected\n'
  printf '2026-09-20T10:00\t4\tk1 control\tw\tcontrols/k1.log\tsurvived\n'
  printf '2026-09-20T10:30\t7\tFinding V1 (NOT VERIFIED, C1 on screen)\tw\te\tNOT VERIFIED; back to Phase 4\n'
  printf '2026-09-20T11:00\t4\tfix V1\tw\te\tflake: one rerun of the check\n'
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
# The critical findings: a parenthesis with critical on a line of a top review-*.md, under the Act on
# heading or under no section heading; not a summary line, an indented line (a Fix sub-bullet that
# quotes the format), a line under another heading, a fix-check file, or a review file in a subfolder.
mkdir -p "$run/eval/sets"
{
  printf '# Plan gate round 1\n\n'
  printf -- '- **Panel:** premortem 3 raised, devils-advocate 1 of 6 (critical), 1 survived.\n\n'
  printf '## Act on\n\n'
  printf '### G1 (critical, harness). The TOTAL row fails.\n\n'
  printf -- '- **A1 (Critical, premortem).** The real osascript exits 1.\n'
  printf -- '  - Fix: each critical line writes (critical, <lens>).\n'
  printf 'P2 (warning, eval). Not critical.\n'
  printf 'No critical item survived.\n\n'
  printf '## Dismissed\n\n'
  printf 'D1 (critical, devils-advocate). Refuted.\n'
} > "$run/review-plan-1.md"
printf '# Code gate round 1\n\nG3 (critical, eval). A flat list with no section heading.\n' > "$run/review-diff-1.md"
printf '# Code gate round 2\n\n## Act-On\n\nG4 (critical, harness). A heading with a hyphen.\n' > "$run/review-diff-2.md"
printf '| P10 (critical) | yes |\n' > "$run/fix-check-plan.md"
printf 'G9 (critical, eval). A copy.\n' > "$run/eval/sets/review-diff-1.md"
# The folder birth time: on APFS, a modification time before the birth time moves the birth time.
touch -t 202609200800 "$run"

transcript="$tmp/t.jsonl"
cat > "$transcript" <<'EOF'
{"type":"mode","mode":"normal"}
{"type":"assistant","timestamp":"2026-09-20T08:10:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-09-20T08:21:00.000Z","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"2026-09-20T08:22:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-09-20T08:23:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}},{"type":"tool_use","name":"Bash","input":{}}]}}
{"type":"user","timestamp":"2026-09-20T08:35:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-09-20T08:36:30.000Z","message":{"content":[{"type":"text","text":"Agent"},{"type":"tool_use","name":"Agent","input":{}},{"type":"tool_use","name":"Workflow","input":{"name":"review-panel"}}]}}
{"type":"assistant","timestamp":"2026-09-20T12:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}
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
critical findings: 4
friction: 9
window: 2026-09-20T08:20 to 2026-09-20T11:30
agents: 3
workflows: 1
idle: 12 min in 1 gaps over 5 min
subagents: none
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

no_transcript="$(sed -e 's/^agents: .*/agents: no transcript/' -e 's/^workflows: .*/workflows: no transcript/' -e 's/^idle: .*/idle: no transcript/' \
  -e 's/^subagents: .*/subagents: no transcript/' <<<"$want")"
check 'no transcript' "$no_transcript" "$run"

no_gh="$(grep -v '^pace: ' <<<"$no_transcript")
pace: no gh data"
FAKE_GH=fail check 'gh fails' "$no_gh" "$run"

# The subagents of the session (subagents/ next to the transcript, at any depth: a Workflow puts its
# agents in subagents/workflows/wf_*/) get one line each when their first user message names the
# run, with no letter, digit, or hyphen after the name, and their time span overlaps the subagent
# window: the folder birth (08:00Z) to the end of the run window (11:30Z). So the agent that opens
# the run before its first row (08:20Z) counts. The others are unattributed: a run with a longer
# name, another run, and a file that names this run and another run but runs after the window.
sub="$tmp/t/subagents"
mkdir -p "$sub/workflows/wf_x"
u() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":%s}}\n' "$1" "$2"; }
bash_use() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"%s"}}]}}\n' "$1" "$2" "$3"; }
result() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s,"content":"x"}]}}\n' "$1" "$2" "$3"; }
{
  u 2026-09-20T09:00:00.000Z '"Run 2026-09-20-fixture, slice 1."'
  bash_use 2026-09-20T09:01:00.000Z a1 'make test'
  result 2026-09-20T09:02:00.000Z a1 true
  bash_use 2026-09-20T09:03:00.000Z a2 'make test'
  result 2026-09-20T09:04:00.000Z a2 false
  bash_use 2026-09-20T09:20:00.000Z a3 'git status'
  result 2026-09-20T09:21:00.000Z a3 false
} > "$sub/agent-one.jsonl"
{
  u 2026-09-20T10:00:00.000Z '[{"type":"text","text":"Review the plan of 2026-09-20-fixture."}]'
  printf '{"type":"assistant","timestamp":"2026-09-20T10:02:00.000Z","message":{"content":[{"type":"tool_use","id":"b1","name":"Read","input":{"file_path":"x"}}]}}\n'
} > "$sub/workflows/wf_x/agent-two.jsonl"
{ u 2026-09-20T08:10:00.000Z '"Run 2026-09-20-fixture, analysis."'; bash_use 2026-09-20T08:40:00.000Z f1 ls; } > "$sub/agent-early.jsonl"
{ u 2026-09-20T08:05:00.000Z '"Open run 2026-09-20-fixture."'; bash_use 2026-09-20T08:15:00.000Z g1 pwd; } > "$sub/agent-opener.jsonl"
{ u 2026-09-20T09:00:00.000Z '"Run 2026-09-20-fixture-2, slice 1."'; bash_use 2026-09-20T09:01:00.000Z c1 ls; } > "$sub/agent-longer.jsonl"
{ u 2026-09-20T09:00:00.000Z '"Run 2026-09-21-other."'; bash_use 2026-09-20T09:01:00.000Z d1 ls; } > "$sub/agent-other.jsonl"
{ u 2026-09-20T13:00:00.000Z '"Compare 2026-09-20-fixture with 2026-09-21-other."'; bash_use 2026-09-20T13:01:00.000Z e1 ls; } > "$sub/agent-late.jsonl"
out="$(cd "$tmp" && TZ=UTC PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$run" "$transcript" 2>&1)" || fail "subagents: exit $?: $out"
for line in 'subagent: agent-one: 3 tool calls, 21 min, 1 errors (make test), repeated: make test x2, gaps: 1 over 5 min (16 min)' \
  'subagent: agent-two: 1 tool calls, 2 min, 0 errors, repeated: none, gaps: 0 over 5 min (0 min)' \
  'subagent: agent-early: 1 tool calls, 30 min, 0 errors, repeated: none, gaps: 1 over 5 min (30 min)' \
  'subagent: agent-opener: 1 tool calls, 10 min, 0 errors, repeated: none, gaps: 1 over 5 min (10 min)' \
  'unattributed: 3 files'; do
  grep -qxF -- "$line" <<<"$out" || fail "subagents: no line '$line' in: $(grep -E '^(subagent|unattributed)' <<<"$out")"
done
[[ "$(grep -c '^subagent: ' <<<"$out")" == 4 ]] || fail "subagents: want 4 subagent lines: $(grep '^subagent' <<<"$out")"
rm -rf "$tmp/t"

# A run folder with no logs/ and no controls/ (the early runs): no false zero for the checks and the
# benches, zero controls, and the pace lines.
bare="$tmp/2026-09-19-bare"
mkdir "$bare"
cp "$run/decisions.tsv" "$run/run.md" "$bare/"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$bare" 2>&1)" || fail "no logs and no controls: exit $?: $out"
for line in 'checks: no logs folder' 'benches: no logs folder, 0 pairs sets' 'controls: 0 written, 0 replayed' 'critical findings: 0' 'friction: 5'; do
  grep -qxF -- "$line" <<<"$out" || fail "no logs and no controls: no line '$line' in: $out"
done
grep -q '^pace: merges per day ' <<<"$out" || fail "no logs and no controls: no pace line: $out"

# A block whose first row comes over 30 min after its start (a wait before the work) gets a
# suffix; 30 min gets none. A bench log with a load wait line counts as a bench, not as a check. The
# delta check of land.sh (a `stamp: delta` line) counts as a check.
late="$tmp/2026-09-20-late"
mkdir -p "$late/logs"
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-09-20T08:31\t1\ta\tw\te\tdone\n2026-09-20T09:01\t2\tb\tw\te\tdone\n2026-09-20T09:05\t2\tc\tw\te\tdone\n' > "$late/decisions.tsv"
printf 'bench: commit bbb tree clean filter LiveBench\ncheck-changed: load 3.00, under 4: run the tests\nbench: load 3.00\n' > "$late/logs/b1.log"
printf 'stamp: delta check\nclasses: sources\n' > "$late/logs/land.log"
touch -t 202609200800 "$late"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$late" 2>&1)" || fail "a late first row: exit $?: $out"
for line in 'phase 1: 2026-09-20T08:00 to 2026-09-20T08:31, 31 min, first row after 31 min' \
  'phase 2: 2026-09-20T08:31 to 2026-09-20T09:05, 34 min' \
  'checks: 1 logs, 0 filtered, 0 push checks, 0 repeated (same commit and targets)' \
  'benches: 1 bench logs, 0 pairs sets, 0 repeated (same commit and filter)'; do
  grep -qxF -- "$line" <<<"$out" || fail "a late first row: no line '$line' in: $out"
done

# A run whose first row is phase 0 (run 2026-10-07-heap-corruption): the phase compares as text, so
# phase 0 starts a block. As a number it equals the unset phase, and cost.sh printed date errors.
zero="$tmp/2026-09-20-zero"
mkdir "$zero"
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-09-20T08:20\t0\topen\tw\te\tdone\n2026-09-20T08:40\t1\ta\tw\te\tdone\n2026-09-20T09:00\t2\tb\tw\te\tdone\n' > "$zero/decisions.tsv"
touch -t 202609200800 "$zero"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$zero" 2>&1)" || fail "a first row of phase 0: exit $?: $out"
for line in 'phase 0: 2026-09-20T08:00 to 2026-09-20T08:20, 20 min' \
  'phase 1: 2026-09-20T08:20 to 2026-09-20T08:40, 20 min' \
  'phase 2: 2026-09-20T08:40 to 2026-09-20T09:00, 20 min'; do
  grep -qxF -- "$line" <<<"$out" || fail "a first row of phase 0: no line '$line' in: $out"
done
! grep -qE '^date:|syntax error' <<<"$out" || fail "a first row of phase 0: an error line in: $out"

# The run window is in epoch seconds: the transcript is in UTC, the run times are local. The window
# is 08:20 to 11:30 local: 08:20Z to 11:30Z under UTC, 06:20Z to 09:30Z under UTC+2, so the 10:00Z
# record counts only under UTC.
printf '%s\n' '{"type":"assistant","timestamp":"2026-09-20T08:30:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}' \
  '{"type":"assistant","timestamp":"2026-09-20T10:00:00.000Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{}}]}}' > "$tmp/tz.jsonl"
for zone in UTC:2 Etc/GMT-2:1; do
  out="$(cd "$tmp" && TZ="${zone%:*}" PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$run" "$tmp/tz.jsonl" 2>&1)"
  grep -qx "agents: ${zone#*:}" <<<"$out" || fail "run window in TZ ${zone%:*}: want agents: ${zone#*:}: $(grep '^agents' <<<"$out")"
done

out="$("$cost" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "no argument: exit $code: $out"

# bench.sh prints `bench: commit <HEAD> tree <clean|dirty> filter <filter>` before the build. A fake
# swift on PATH stands for the build and the test run.
b="$tmp/bench-repo"
mkdir -p "$b/scripts" "$b/Sources/App" "$b/Tests"
cp "$bench" "${bench%/*}/with-lock.sh" "$b/scripts/"
printf '// swift-tools-version:6.0\n' > "$b/Package.swift"
printf '{}\n' > "$b/Package.resolved"
printf '@main\nstruct App {}\n' > "$b/Sources/App/App.swift"
printf '.build\n' > "$b/.gitignore"
printf '#!/bin/bash\nexit 0\n' > "$bin/swift"
chmod +x "$bin/swift"
# A stub check-changed.sh logs the load wait call of bench.sh and does not wait.
printf '#!/bin/bash\necho "max=${CHECK_LOAD_MAX:-cores} $*" >> "%s"\n' "$tmp/wait.log" > "$b/scripts/check-changed.sh"
chmod +x "$b/scripts/check-changed.sh"
git -C "$b" init -q
git -C "$b" add -A
git -C "$b" commit -q -m base
head="$(git -C "$b" rev-parse HEAD)"
out="$(cd "$b" && PATH="$bin:$PATH" scripts/bench.sh FooBench 2>&1)" || fail "bench.sh on a clean tree exits $?: $out"
[[ "$(head -n 1 <<<"$out")" == "bench: commit $head tree clean filter FooBench" ]] || fail "bench.sh on a clean tree: $out"
# After the build, bench.sh waits with the default load maximum of check-changed.sh (the core count:
# its own build just raised the load), and prints the load before and after the run.
[[ "$(cat "$tmp/wait.log" 2>/dev/null)" == "max=cores --wait-load bench" ]] || fail "bench.sh wait call: [$(cat "$tmp/wait.log" 2>/dev/null)]"
[[ "$(grep -c '^bench: load [0-9.]*$' <<<"$out")" == 2 ]] || fail "bench.sh load lines: $out"
echo x > "$b/x.txt"
out="$(cd "$b" && PATH="$bin:$PATH" scripts/bench.sh FooBench 2>&1)" || fail "bench.sh on a dirty tree exits $?: $out"
[[ "$(head -n 1 <<<"$out")" == "bench: commit $head tree dirty filter FooBench" ]] || fail "bench.sh on a dirty tree: $out"

[[ $failures -eq 0 ]] && echo "cost tests: all passed"
exit $((failures > 0))
