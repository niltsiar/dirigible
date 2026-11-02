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
controls: 3 written
late on-screen: 1
missed unknowns: 1
critical findings: 4
friction: 9
window: 2026-09-20T08:20 to 2026-09-20T11:30
lock: no tree for the Branch or Worktree line of run.md
agents: 3
workflows: 1
idle: 12 min in 1 gaps over 5 min
subagents: none
tokens: none
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
  -e 's/^subagents: .*/subagents: no transcript/' -e 's/^tokens: .*/tokens: no transcript/' <<<"$want")"
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
for line in 'checks: no logs folder' 'benches: no logs folder, 0 pairs sets' 'controls: 0 written' 'critical findings: 0' 'friction: 5'; do
  grep -qxF -- "$line" <<<"$out" || fail "no logs and no controls: no line '$line' in: $out"
done
grep -q '^pace: merges per day ' <<<"$out" || fail "no logs and no controls: no pace line: $out"

# The label decides. A phase 7 row is late on-screen when its result starts with NOT VERIFIED (after
# an optional criterion ID) and the row says on screen; a decision that only lists the word does not
# count. A review item is critical by its tag, the parenthesis after the number or ID, for the count
# and the skip: `critical: no` in the tag is no finding, and a later parenthesis changes nothing.
# label_run <phase> <decision> <result> [<review line under Act on>]: the cost.sh output of a new run.
label_n=0
label_run() {
  local d
  label_n=$((label_n + 1)) d="$tmp/2026-09-20-label-$label_n"
  mkdir -p "$d"
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-09-20T08:31\t%s\t%s\tw\te\t%s\n' "$1" "$2" "$3" > "$d/decisions.tsv"
  [[ -z "${4:-}" ]] || printf '# Plan gate round 1\n\n## Act on\n\n%s\n' "$4" > "$d/review-plan-1.md"
  touch -t 202609200800 "$d"
  (cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$d" 2>&1)
}
late_is() {
  local want="$1" out
  out="$(label_run "$2" "$3" "$4")"
  grep -qxF "late on-screen: $want" <<<"$out" || fail "late on-screen of ($2) $3 / $4: want $want: $(grep '^late' <<<"$out")"
}
late_is 0 7 'C1 on screen: none NOT VERIFIED or INCONCLUSIVE' 'VERIFIED'
late_is 1 7 'C1 on screen: none NOT VERIFIED or INCONCLUSIVE' 'NOT VERIFIED; back to Phase 4'
late_is 1 7 'C1 on-screen check' 'C1 NOT VERIFIED'
late_is 0 4 'C1 on screen: none NOT VERIFIED or INCONCLUSIVE' 'NOT VERIFIED; back to Phase 4'
crit_is() {
  local want="$1" out
  out="$(label_run 4 x done "$2")"
  grep -qxF "critical findings: $want" <<<"$out" || fail "critical findings of [$2]: want $want: $(grep '^critical' <<<"$out")"
}
crit_is 0 'G1 (warning, premortem; critical: no) A label that says critical: no.'
crit_is 1 'G2 (critical, premortem) A critical item.'
crit_is 1 'G3 (critical, premortem) The text quotes critical: no.'
crit_is 0 'G4 (warning, premortem) The text quotes (critical, x).'
crit_is 1 '1. (critical, premortem and harness) A numbered item.'
crit_is 1 '1. **(critical, premortem) A numbered item in bold.**'
crit_is 1 '| G5 (critical) | premortem | A table row. |'

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

# A timed bench and a trace of one commit and filter (bench.sh --trace ends its line with trace) are
# not a repeat: the rule asks for both.
traced="$tmp/2026-09-20-traced"
mkdir -p "$traced/logs"
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-09-20T08:31\t4\ta\tw\te\tdone\n' > "$traced/decisions.tsv"
printf 'bench: commit bbb tree clean filter LiveBench\n' > "$traced/logs/b1.log"
printf 'bench: commit bbb tree clean filter LiveBench trace\n' > "$traced/logs/b2.log"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$traced" 2>&1)" || fail "a bench and a trace: exit $?: $out"
grep -qxF 'benches: 2 bench logs, 0 pairs sets, 0 repeated (same commit and filter)' <<<"$out" || fail "a bench and a trace: $out"

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

# The lock minutes: the wait and hold lines of the tree in the Worktree line of run.md (relative to
# the checkout that holds the run folder), whose start is in the run window. A line of another tree,
# a line outside the window, and the old wait line of 4 columns (no tree) are not counted.
mkdir -p "$tmp/main" "$tmp/tree"
git -C "$tmp/main" init -q
git -C "$tmp/tree" init -q
lockrun="$tmp/main/.scratchpads/runs/2026-09-20-lock"
mkdir -p "$lockrun"
printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-09-20T08:00\t4\ta\tw\te\tdone\n2026-09-20T09:00\t4\tb\tw\te\tdone\n' > "$lockrun/decisions.tsv"
printf -- '- Worktree: ../tree (from origin/main abc)\n' > "$lockrun/run.md"
mine="$(git -C "$tmp/tree" rev-parse --show-toplevel)"
printf '2026-09-20T08:10:00\t600\tmake test\tmake test\t%s\n2026-09-20T08:20:00\t1200\tmake test\tmake test\t/other/tree\n2026-09-20T07:00:00\t3600\tmake test\tmake test\t%s\n2026-09-20T08:30:00\t900\tmake test\tmake test\n' \
  "$mine" "$mine" > "$tmp/tree/.git/dirigible-build-waits.log"
printf '2026-09-20T08:30:00\t1800\tmake test\t%s\n2026-09-20T08:40:00\t300\tmake test limit\t/other/tree\n2026-09-20T09:30:00\t600\tmake test\t%s\n' \
  "$mine" "$mine" > "$tmp/tree/.git/dirigible-build-holds.log"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$lockrun" 2>&1)" || fail "lock minutes: exit $?: $out"
grep -qxF 'lock: 10 min wait, 30 min hold' <<<"$out" || fail "lock minutes: $(grep -E '^lock|awk|error' <<<"$out")"

# The lock line also reads the worktree of each `- Branch:` line (its first word, backticks removed;
# a note can follow the name) and each `- Worktree:` line, and sums the seconds of all trees before
# it divides by 60. A tree that two lines name counts once. A run with no tree prints one line.
# lock_repo <name> [<branch>...]: a repo with one commit and a worktree for each branch; the tops
# of the trees are in $lock_trees.
lock_repo() {
  local name="$1" b
  shift
  mkdir -p "$tmp/$name"
  git -C "$tmp/$name" init -q
  git -C "$tmp/$name" commit -q --allow-empty -m init
  lock_trees=()
  for b in "$@"; do
    git -C "$tmp/$name" worktree add -q -b "$b" "$tmp/$name-${b##*/}"
    lock_trees+=("$(git -C "$tmp/$name-${b##*/}" rev-parse --show-toplevel)")
  done
}
# lock_lines <repo> <tree> <wait s> <hold s>: a wait line and a hold line of the tree, in the window.
lock_lines() {
  printf '2026-09-20T08:10:00\t%s\tmake test\tmake test\t%s\n' "$3" "$2" >> "$tmp/$1/.git/dirigible-build-waits.log"
  printf '2026-09-20T08:30:00\t%s\tmake test\t%s\n' "$4" "$2" >> "$tmp/$1/.git/dirigible-build-holds.log"
}
# lock_is <repo> <run.md text> <want>: cost.sh of a run folder in the repo prints the lock line <want>.
lock_n=0
lock_is() {
  local d out
  lock_n=$((lock_n + 1)) d="$tmp/$1/.scratchpads/runs/2026-09-20-lock-$lock_n"
  mkdir -p "$d"
  printf 'ts\tphase\tdecision\twhy\tevidence\tresult\n2026-09-20T08:00\t4\ta\tw\te\tdone\n2026-09-20T09:00\t4\tb\tw\te\tdone\n' > "$d/decisions.tsv"
  printf '%s\n' "$2" > "$d/run.md"
  out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$d" 2>&1)" || fail "lock line of [$2]: exit $?: $out"
  [[ "$(grep '^lock:' <<<"$out")" == "$3" ]] || fail "lock line of [$2]: want [$3]: $(grep -E '^lock|error' <<<"$out")"
}
lock_repo lk-a feat/lk-a
lock_lines lk-a "${lock_trees[0]}" 600 1800
lock_lines lk-a /other/tree 1200 300
printf '2026-09-20T07:00:00\t3600\tmake test\tmake test\t%s\n' "${lock_trees[0]}" >> "$tmp/lk-a/.git/dirigible-build-waits.log"
lock_is lk-a '- Branch: feat/lk-a (from origin/main abc1234)' 'lock: 10 min wait, 30 min hold'
lock_is lk-a '- Branch: `feat/lk-a`, worktree ../x' 'lock: 10 min wait, 30 min hold'
lock_is lk-a "$(printf -- '- Branch: feat/lk-a\n- Worktree: %s' "${lock_trees[0]}")" 'lock: 10 min wait, 30 min hold'
# Two trees give the sum of both: 50 s each is 1 min in all, and 0 min if each tree is divided first.
lock_repo lk-b feat/lk-b
lock_lines lk-b "${lock_trees[0]}" 50 50
lock_repo lk-c feat/lk-c  # lk-b names this tree in a Worktree line
lock_lines lk-c "${lock_trees[0]}" 50 50
lock_is lk-b "$(printf -- '- Branch: feat/lk-b\n- Worktree: %s' "${lock_trees[0]}")" 'lock: 1 min wait, 1 min hold'
lock_repo lk-d feat/lk-d1 feat/lk-d2
lock_lines lk-d "${lock_trees[0]}" 50 50
lock_lines lk-d "${lock_trees[1]}" 50 50
lock_is lk-d "$(printf -- '- Branch: feat/lk-d1\n- Branch: feat/lk-d2')" 'lock: 1 min wait, 1 min hold'
# A call with WITH_LOCK_NO_CAP=1 ends its wait and hold lines with the column nocap (the hold line has
# an empty fifth column): the minutes count as for any call.
lock_repo lk-f feat/lk-f
lock_lines lk-f "${lock_trees[0]}" 600 1800
printf '2026-09-20T08:20:00\t300\ttouch x\tmake test\t%s\tnocap\n' "${lock_trees[0]}" >> "$tmp/lk-f/.git/dirigible-build-waits.log"
printf '2026-09-20T08:40:00\t600\ttouch x\t%s\t\tnocap\n' "${lock_trees[0]}" >> "$tmp/lk-f/.git/dirigible-build-holds.log"
lock_is lk-f '- Branch: feat/lk-f' 'lock: 15 min wait, 40 min hold'
lock_repo lk-e feat/lk-e
# No tree: a Branch that no worktree holds, and a run.md with neither line.
no_tree='lock: no tree for the Branch or Worktree line of run.md'
lock_is lk-e '- Branch: feat/no-such-branch' "$no_tree"
lock_is lk-e '- Goal: x' "$no_tree"

# The tokens: each reply once by message.id and requestId (a reply line can repeat), each
# usage.iterations entry under its own model (an advisor_message names the advisor model), the cache
# writes split into 5 min and 1 h, and the attributed subagents added. A reply outside the window
# does not count.
tok="$tmp/tok.jsonl"
reply() { printf '{"type":"assistant","timestamp":"%s","requestId":"%s","message":{"id":"%s","model":"claude-opus-5-5","content":[],"usage":%s}}\n' "$1" "$2" "$3" "$4"; }
{
  reply 2026-09-20T09:00:00.000Z r1 m1 '{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"iterations":[{"type":"message","input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}]}'
  reply 2026-09-20T09:00:01.000Z r1 m1 '{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200},"iterations":[{"type":"message","input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}]}'
  reply 2026-09-20T09:10:00.000Z r2 m2 '{"input_tokens":5,"output_tokens":50,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"iterations":[{"type":"message","input_tokens":5,"output_tokens":50,"cache_read_input_tokens":500,"cache_creation_input_tokens":0},{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":7,"output_tokens":70,"cache_read_input_tokens":700,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":40}}]}'
  reply 2026-09-20T12:00:00.000Z r3 m3 '{"input_tokens":99,"output_tokens":99,"cache_read_input_tokens":99,"cache_creation_input_tokens":99}'
} > "$tok"
mkdir -p "$tmp/tok/subagents"
{ u 2026-09-20T09:00:00.000Z '"Run 2026-09-20-fixture, slice 1."'
  reply 2026-09-20T09:05:00.000Z r4 m4 '{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":4,"ephemeral_1h_input_tokens":5}}'
} > "$tmp/tok/subagents/agent-s.jsonl"
out="$(cd "$tmp" && PATH="$bin:$PATH" GH_LOG="$tmp/gh.log" "$cost" "$run" "$tok" 2>&1)" || fail "tokens: exit $?: $out"
want_tokens='tokens: claude-fable-5-1 in 7 out 70 cache-read 700 cache-write-5m 0 cache-write-1h 40
tokens: claude-opus-5-5 in 16 out 152 cache-read 1503 cache-write-5m 104 cache-write-1h 205'
[[ "$(grep '^tokens:' <<<"$out")" == "$want_tokens" ]] || fail "tokens: $(grep '^tokens:' <<<"$out")"

out="$("$cost" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "no argument: exit $code: $out"

# bench.sh prints `bench: commit <HEAD> tree <clean|dirty> filter <filter>` before the build. A fake
# swift on PATH stands for the build and the test run.
b="$tmp/bench-repo"
mkdir -p "$b/scripts" "$b/Sources/App" "$b/Tests"
cp "$bench" "${bench%/*}/with-lock.sh" "${bench%/*}/lock-words.sh" "$b/scripts/"
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
# Only a change in a bench input path (here Sources/) makes the tree dirty.
echo '// x' >> "$b/Sources/App/App.swift"
out="$(cd "$b" && PATH="$bin:$PATH" scripts/bench.sh FooBench 2>&1)" || fail "bench.sh on a dirty tree exits $?: $out"
[[ "$(head -n 1 <<<"$out")" == "bench: commit $head tree dirty filter FooBench" ]] || fail "bench.sh on a dirty tree: $out"

[[ $failures -eq 0 ]] && echo "cost tests: all passed"
exit $((failures > 0))
