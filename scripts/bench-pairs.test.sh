#!/bin/bash
# Check that bench-pairs.sh gives each case the verdict of its A/A pair and its main/branch pairs,
# and that --compare refuses logs whose provenance is not one clean commit per side with the bench
# inputs of HEAD. Run by `make test-hooks`.
set -uo pipefail
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A repo with the bench inputs and a copy of the script: --compare checks the branch commit of the
# logs against HEAD of the tree that holds the script.
r="$tmp/repo"
mkdir -p "$r/scripts" "$r/Sources" "$r/Tests" "$r/docs"
cp "$(dirname "$0")/bench-pairs.sh" "$r/scripts/"
for f in Sources/A.swift Tests/T.swift Package.swift Package.resolved scripts/bench.sh docs/d.md; do echo x > "$r/$f"; done
g() { git -C "$r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q
commit() { g add -A && g commit -qm "$1"; }
commit base
pairs="$r/scripts/bench-pairs.sh"
branch="$(g rev-parse HEAD)"
main=0123456789abcdef0123456789abcdef01234567

# The commit line of bench.sh, then one log line per case, in the format of the benches:
# "<Suite>Benchmark <case>: p50 ... p95 ...". The aa-* and main-* logs name $main, the branch-*
# logs name $branch, each on a clean tree.
log() { # log <file> <p95 ms of case a> <p95 ms of case b>
  local c="$main"
  [[ "${1##*/}" != branch-* ]] || c="$branch"
  printf 'bench: commit %s tree clean filter X\nXBenchmark a: p50 0.001 seconds, p95 %s seconds\nXBenchmark b: p50 0.001 seconds, p95 %s seconds\n' \
    "$c" "$(echo "$2 / 1000" | bc -l)" "$(echo "$3 / 1000" | bc -l)" > "$1"
}
mkdir "$tmp/v"
log "$tmp/v/aa-1.log" 10 10
log "$tmp/v/aa-2.log" 10.2 10
log "$tmp/v/main-1.log" 10 10
log "$tmp/v/branch-1.log" 10.3 13
log "$tmp/v/main-2.log" 10.1 10
log "$tmp/v/branch-2.log" 10.2 13.5
out="$("$pairs" --compare "$tmp/v" 2>&1)"
grep -q '^VERIFIED XBenchmark a$' <<< "$out" || fail "a case in the rule is VERIFIED: $out"
grep -q '^NOT VERIFIED XBenchmark b$' <<< "$out" || fail "a case over the rule in each pair is NOT VERIFIED: $out"

# The A/A pair of main moves more than the rule: no verdict from the branch numbers.
log "$tmp/v/aa-2.log" 13 10
out="$("$pairs" --compare "$tmp/v" 2>&1)"
grep -q '^INCONCLUSIVE XBenchmark a (A/A' <<< "$out" || fail "an A/A spread over the rule is INCONCLUSIVE: $out"

# Over the rule in one pair only: INCONCLUSIVE, not a pick of the clean pair.
log "$tmp/v/aa-2.log" 10 10
log "$tmp/v/branch-2.log" 10.2 10.1
out="$("$pairs" --compare "$tmp/v" 2>&1)"
grep -q '^INCONCLUSIVE XBenchmark b (1 of 2 pairs' <<< "$out" || fail "one pair over the rule is INCONCLUSIVE: $out"

# A bench that prints p50 and max (NavigationKeyBenchmark) has no p95: the pairs compare its p50.
logmax() { # logmax <file> <p50 ms>
  local c="$main"
  [[ "${1##*/}" != branch-* ]] || c="$branch"
  printf 'bench: commit %s tree clean filter X\nNavigationKeyBenchmark crossfade, fit: p50 %s seconds, max 0.09 seconds\n' \
    "$c" "$(echo "$2 / 1000" | bc -l)" > "$1"
}
mkdir "$tmp/m"
logmax "$tmp/m/aa-1.log" 53
logmax "$tmp/m/aa-2.log" 53.5
logmax "$tmp/m/main-1.log" 53
logmax "$tmp/m/branch-1.log" 49
logmax "$tmp/m/main-2.log" 53.2
logmax "$tmp/m/branch-2.log" 49.3
out="$("$pairs" --compare "$tmp/m" 2>&1)"
code=$?
[[ $code -eq 0 ]] && grep -q '^VERIFIED NavigationKeyBenchmark crossfade, fit$' <<< "$out" &&
  grep -qF 'main/branch p50 ms per pair: 53.00/49.00 53.20/49.30; A/A 53.00/53.50' <<< "$out" || fail "a p50 and max bench: exit $code: $out"

# A side with no sample (a filter that matched no test), or a bench that failed, gives exit 1.
mkdir "$tmp/none"
for f in aa-1 aa-2 main-1 branch-1; do : > "$tmp/none/$f.log"; done
out="$("$pairs" --compare "$tmp/none" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no bench sample in aa-1.log'* ]] || fail "no sample: exit $code: $out"
cp "$tmp"/v/*.log "$tmp/none/"
: > "$tmp/none/branch-2.log"
out="$("$pairs" --compare "$tmp/none" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no bench sample in branch-2.log'* ]] || fail "a branch side with no sample: exit $code: $out"
cp "$tmp/v/branch-2.log" "$tmp/none/"
echo 'main-1: the bench failed' > "$tmp/none/load.txt"
out="$("$pairs" --compare "$tmp/none" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'main-1: the bench failed'* ]] || fail "a failed bench: exit $code: $out"

# A bench that fails only its budget asserts prints its samples and a report line of 1 test or
# more: the main side of a fix of a budget miss. Its samples count, with a note, and the verdict
# stays. A failed bench with no report line (above) still gives exit 1.
mkdir "$tmp/f"
cp "$tmp"/m/*.log "$tmp/f/"
miss() { # miss <test> [<budget word>]: the issue line of a budget expectation
  printf '✘ Test %s recorded an issue at X.swift:1:1: Expectation failed: (value → 0.009 seconds) <= (%s → 0.008 seconds)' "$1" "${2:-budget}"
}
for f in aa-1 aa-2 main-1 main-2; do
  { miss 't()'; echo; echo 'Test run with 1 test in 1 suite failed after 7.3 seconds with 2 issues.'; } >> "$tmp/f/$f.log"
done
printf 'aa-1: the bench failed\naa-2: the bench failed\nmain-1: the bench failed\nmain-2: the bench failed\n' > "$tmp/f/load.txt"
out="$("$pairs" --compare "$tmp/f" 2>&1)"
code=$?
[[ $code -eq 0 ]] && grep -q '^VERIFIED NavigationKeyBenchmark crossfade, fit$' <<< "$out" &&
  grep -qxF 'note: main-1 failed its asserts after its report line; its samples count' <<< "$out" ||
  fail "a main side that misses its budget: exit $code: $out"

# The exception is only for the aa-* and main-* sides: a branch bench that fails a budget assert
# that no aa or main log fails stays a failure.
{ miss 'u()'; echo; echo 'Test run with 1 test in 1 suite failed after 7.3 seconds with 2 issues.'; } >> "$tmp/f/branch-1.log"
echo 'branch-1: the bench failed' >> "$tmp/f/load.txt"
out="$("$pairs" --compare "$tmp/f" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'NOT VERIFIED: branch-1: the bench failed'* ]] || fail "a branch side that misses its budget: exit $code: $out"

# A branch budget miss that main shares counts, with a note: each failed test of the branch log also
# fails in an aa or main log, each of its issues is a budget expectation, and it prints a case with a
# value on both sides. slog <log> <line>... writes a runner log of the pair set $tmp/$pset: the
# commit line, the lines, and a report line.
mkdir "$tmp/s"
pset=s
slog() {
  local f="$tmp/$pset/$1.log" c="$main"
  shift
  [[ "${f##*/}" != branch-* ]] || c="$branch"
  { echo "bench: commit $c tree clean filter X"; printf '%s\n' "$@"
    echo '✘ Test run with 2 tests in 2 suites failed after 2.000 seconds with 1 issue.'; } > "$f"
}
A() { printf 'XBenchmark a: p50 0.001 seconds, p95 %s seconds' "$(echo "$1 / 1000" | bc -l)"; }
t_on=('◇ Suite XBenchmark started.' '◇ Test t() started.')
t_ok='✔ Test t() passed after 1.000 seconds.'
t_bad='✘ Test t() failed after 1.000 seconds with 1 issue.'
p_on=('◇ Suite PeakComputeBenchmark started.' '◇ Test p() started.')
p_ok='✔ Test p() passed after 1.000 seconds.'
p_bad='✘ Test p() failed after 1.000 seconds with 1 issue.'
no_budget() { printf '✘ Test %s recorded an issue at X.swift:2:1: Expectation failed: (count → 3) == 4' "$1"; }
# judged <name> <exit> <line>...: --compare of $tmp/$pset exits <exit> and prints each line.
judged() {
  local name="$1" want="$2" l
  shift 2
  out="$("$pairs" --compare "$tmp/$pset" 2>&1)"
  code=$?
  [[ $code -eq $want ]] || { fail "$name: exit $code: $out"; return; }
  for l in "$@"; do grep -qxF "$l" <<< "$out" || { fail "$name: no line \"$l\": $out"; return; }; done
}
# no_claim <name>: the last compare printed no shared note and no NO VERDICT line.
no_claim() { [[ "$out" != *'shared budget miss'* && "$out" != *'NO VERDICT'* ]] || fail "$1: a shared note or a NO VERDICT line: $out"; }
slog aa-1 "${t_on[@]}" "$(A 10)" "$t_ok"
slog aa-2 "${t_on[@]}" "$(A 10.1)" "$t_ok"
slog main-1 "${t_on[@]}" "$(A 10)" "$(miss 't()')" "$t_bad"
slog branch-1 "${t_on[@]}" "$(A 10.2)" "$(miss 't()')" "$t_bad"
printf 'main-1: the bench failed\nbranch-1: the bench failed\n' > "$tmp/s/load.txt"
judged 'a branch budget miss that main shares' 0 'note: shared budget miss in branch-1: t()' \
  'note: main-1 failed its asserts after its report line; its samples count' 'VERIFIED XBenchmark a'
slog branch-1 "${t_on[@]}" "$(A 10.2)" "$(miss 't()')" "$t_bad" '◇ Test u() started.' "$(miss 'u()')" \
  '✘ Test u() failed after 1.000 seconds with 1 issue.'
judged 'a branch budget miss of a test that no aa or main log fails' 1 'NOT VERIFIED: branch-1: the bench failed'
no_claim 'a branch budget miss of a test that no aa or main log fails'
slog branch-1 "${t_on[@]}" "$(A 10.2)" "$(no_budget 't()')" "$t_bad"
judged 'a shared failed test with an issue that is no budget expectation' 1 'NOT VERIFIED: branch-1: the bench failed'
no_claim 'a shared failed test with an issue that is no budget expectation'
slog branch-1 "${t_on[@]}" "$(A 10.2)" "$t_ok"
judged 'a failed branch log with no failed test' 1 'NO VERDICT branch-1: no failed test'
# A filter of two suites: the shared failed test p() prints no case line (as PeakComputeBenchmark in
# an optimized build), so no case of it has a value on both sides.
slog aa-1 "${t_on[@]}" "$(A 10)" "$t_ok" "${p_on[@]}" "$p_ok"
slog aa-2 "${t_on[@]}" "$(A 10.1)" "$t_ok" "${p_on[@]}" "$p_ok"
slog main-1 "${t_on[@]}" "$(A 10)" "$t_ok" "${p_on[@]}" "$(miss 'p()')" "$p_bad"
slog branch-1 "${t_on[@]}" "$(A 10.2)" "$t_ok" "${p_on[@]}" "$(miss 'p()')" "$p_bad"
judged 'a shared failed test with no case line' 1 'NO VERDICT branch-1: p() has no case with a value on both sides'
# The aa and main note needs a failed test and budget issues only, in each budget text form; a
# failed test of an aa or main log needs no case.
slog aa-1 "${t_on[@]}" "$(A 10)" "$t_ok" "${p_on[@]}" "$(miss 'p()' Self.budget)" "$p_bad"
slog main-1 "${t_on[@]}" "$(A 10)" "$t_ok" "${p_on[@]}" "$(miss 'p()' MouseEventBenchmark.budget)" "$p_bad"
slog branch-1 "${t_on[@]}" "$(A 10.2)" "$t_ok" "${p_on[@]}" "$p_ok"
printf 'aa-1: the bench failed\nmain-1: the bench failed\n' > "$tmp/s/load.txt"
judged 'an aa and a main log that miss the budget of a test with no case line' 0 'VERIFIED XBenchmark a' \
  'note: aa-1 failed its asserts after its report line; its samples count' \
  'note: main-1 failed its asserts after its report line; its samples count'
slog aa-1 "${t_on[@]}" "$(A 10)" "$t_ok"
slog main-1 "${t_on[@]}" "$(A 10)" "$(no_budget 't()')" "$t_bad"
printf 'main-1: the bench failed\n' > "$tmp/s/load.txt"
judged 'a main log that fails an expectation that is no budget' 1 'NOT VERIFIED: main-1: the bench failed'
slog main-1 "${t_on[@]}" "$(A 10)" "$t_ok"
judged 'a failed main log with no failed test' 1 'NOT VERIFIED: main-1: the bench failed'

# A case in each branch log and in no aa or main log has no main side: the compare names it, and the
# exit stays. A case with a value in some logs of a side only, or on the main side only, gets no
# verdict. B <p95 ms> is a line of case b.
B() { printf 'XBenchmark b: p50 0.001 seconds, p95 %s seconds' "$(echo "$1 / 1000" | bc -l)"; }
mkdir "$tmp/c"
pset=c
for f in aa-1 aa-2 main-1 main-2; do slog "$f" "$(A 10)"; done
slog branch-1 "$(A 10)" "$(B 5)"
slog branch-2 "$(A 10)" "$(B 5)"
judged 'a case in each branch log only' 0 'NO MAIN SIDE XBenchmark b: judge it by its absolute budget' 'VERIFIED XBenchmark a'
slog branch-2 "$(A 10)"
judged 'a case in one of two branch logs only' 1 'NO VERDICT XBenchmark b: a value on one side only' 'VERIFIED XBenchmark a'
for f in aa-1 aa-2 main-1 branch-1 branch-2; do slog "$f" "$(A 10)" "$(B 5)"; done
judged 'a case with no value in one main log' 1 'NO VERDICT XBenchmark b: a value on one side only'
slog main-2 "$(A 10)" "$(B 5)"
for f in branch-1 branch-2; do slog "$f" "$(A 10)"; done
judged 'a case of the aa and main logs with no branch value' 1 'NO VERDICT XBenchmark b: a value on one side only'

# Each time line form that a bench prints is a case, with the value of its form; a line gives the
# cases of its first form only. A p90 with no unit, a line with no time, and an over debug budget
# line are no case.
mkdir "$tmp/forms"
pset=forms
forms=(
  '◇ Suite EditBenchmark started.'
  'EditBenchmark nudge of 1,000 clips on 8 tracks: p95 0.0123 seconds'
  'SnapSearchBenchmark fit: p95 0.002 seconds, set-up 0.5 seconds, snapped 0 of 120'
  'LiveTakeBenchmark width step, fit: max 0.0075 seconds'
  'HeaderDragBenchmark rows, fit: one-off events Esc 0.001 seconds, up at 400 0.002 seconds, double-click 0.003 seconds, AX step 0.004 seconds, up at 400 0.005 seconds; max 0.0055 seconds'
  'TranscribeBenchmark 1 h of Spanish: 95.5 seconds'
  'WhisperEngineBenchmark C10 30 s vad true at 0.5: stop to return 0.3 seconds'
  'ExportBenchmark: 600 s of 8 tracks to AAC 256 in 3.25 seconds'
  'LoudnessExportBenchmark: 600 s of 8 tracks to WAV 1 with podcast in 4.5 seconds: 5 renders, 2 trial passes, 2 encodes, 0 read-backs'
  'bench report: TranscriptSaveBenchmark edit p90 0.011 seconds, autosave p90 0.012 seconds, words change save p90 0.013 seconds, open p90 0.014 seconds'
  'bench report: TranscriptTextBenchmark main-actor apply p90 0.02 seconds, off-main build p90 0.03 seconds, runs [0.02 seconds, 0.03 seconds]'
  'bench report: TranscriptTextBenchmark selection change over 27000 units: drag step p90 1.5 ms (max 2.0, draw p90 0.5), Shift-Right move from 40 units p90 1.6 ms (max 2.1, draw p90 0.6), from 27000 27000 units p90 1.7 ms (max 2.2, draw p90 0.7), Select All 3.0 ms'
  '◇ Suite AutoLevelBenchmark started.'
  'bench report: 4 clips of 2 h took 1.25 seconds'
  '◇ Suite ReadBenchmark started.'
  'bench report: silences of 66.5 min took 0.5 seconds, nearest pause took 0.25 seconds'
  '◇ Suite LiveLoudnessBenchmark started.'
  'bench report: a step at 2 h: p50 0.0004 seconds, p95 0.0006 seconds'
  '◇ Suite DiagnosticLogBenchmark started.'
  'bench report: a journal note: mean 5e-05 seconds, p99 0.00015 seconds, max 0.001 seconds'
  '◇ Suite SessionFileBenchmark started.'
  'bench report: ride fixture 4: size 1000 B, open 0.1 seconds, save 0.2 seconds; no ride: size 900 B, open 0.05 seconds, save 0.15 seconds; the ride adds open 0.05 seconds, save 0.07 seconds'
  'bench report: ride fixture 4 peak RSS 12 MB (12582912 B)'
  '◇ Suite FinalizeBenchmark started.'
  'finalize: (status: 0, peakBytes: 123, seconds: 0.75), no pending take: (status: 0, peakBytes: 1, seconds: 0.5), dd: (status: 0, peakBytes: 1, seconds: 0.25)'
  '◇ Suite LoudnessBenchmark started.'
  'bench report: 1 h of stereo audio took 5.1 seconds over debug budget 4 seconds'
  '◇ Suite LaneRenderBenchmark started.'
  'LaneRenderBenchmark dense envelope, fit: p50 0.006116054 seconds, p95 0.0077946 seconds'
)
for f in aa-1 aa-2 main-1 branch-1; do slog "$f" "${forms[@]}"; done
judged 'each time line form' 0
while IFS='|' read -r c v; do
  grep -A1 -xF "VERIFIED $c" <<< "$out" | grep -qF "per pair: $v/$v; A/A $v/$v" || fail "form case \"$c\" with $v ms: $out"
done <<'EOF'
EditBenchmark nudge of 1,000 clips on 8 tracks|12.30
SnapSearchBenchmark fit|2.00
LiveTakeBenchmark width step, fit|7.50
HeaderDragBenchmark rows, fit, one-off|5.50
TranscribeBenchmark 1 h of Spanish|95500.00
WhisperEngineBenchmark C10 30 s vad true at 0.5: stop to return|300.00
ExportBenchmark 600 s of 8 tracks to AAC 256|3250.00
LoudnessExportBenchmark 600 s of 8 tracks to WAV 1 with podcast|4500.00
TranscriptSaveBenchmark edit|11.00
TranscriptSaveBenchmark autosave|12.00
TranscriptSaveBenchmark words change save|13.00
TranscriptSaveBenchmark open|14.00
TranscriptTextBenchmark main-actor apply|20.00
TranscriptTextBenchmark off-main build|30.00
TranscriptTextBenchmark drag step|1.50
TranscriptTextBenchmark Shift-Right move from 40 units|1.60
TranscriptTextBenchmark from 27000 27000 units|1.70
AutoLevelBenchmark 4 clips of 2 h|1250.00
ReadBenchmark silences of 66.5 min|500.00
ReadBenchmark nearest pause|250.00
LiveLoudnessBenchmark a step at 2 h|0.60
DiagnosticLogBenchmark a journal note mean|0.05
DiagnosticLogBenchmark a journal note p99|0.15
SessionFileBenchmark ride fixture 4 open|100.00
SessionFileBenchmark ride fixture 4 save|200.00
SessionFileBenchmark ride fixture 4 adds save|70.00
FinalizeBenchmark finalize|750.00
LaneRenderBenchmark dense envelope, fit|7.79
EOF
n="$(grep -cE '^(VERIFIED|INCONCLUSIVE|NOT VERIFIED|NO )' <<< "$out")"
[[ "$n" -eq 28 ]] || fail "each time line form: 28 verdict lines, not $n: $out"

# A time line in a suite that no form reads gets no verdict: the compare names the line once, each
# number as N. A line with no time and a runner line (✘, ↳) are no such line.
mkdir "$tmp/u"
pset=u
for f in aa-1 aa-2 main-1 branch-1; do
  slog "$f" '◇ Suite BarBenchmark started.' 'BarBenchmark x: p50 0.001 seconds, p95 0.002 seconds' \
    '◇ Suite FooBenchmark started.' "FooBenchmark x: mean 0.1${f: -1} seconds"
done
judged 'an unread time line' 1 'NO VERDICT FooBenchmark: the compare reads no case of the line "FooBenchmark x: mean N seconds"'
[[ "$(grep -c '^NO VERDICT' <<< "$out")" -eq 1 ]] || fail "an unread time line is named once: $out"
for f in aa-1 aa-2 main-1 branch-1; do
  slog "$f" '◇ Suite LiveTakeBenchmark started.' 'LiveTakeBenchmark tick, fit: p50 0.001 seconds, p95 0.002 seconds' \
    'LiveTakeBenchmark width step, fit: max 0.0075 seconds' 'LiveTakeBenchmark tick, fit: 3 ticks changed new columns, 2 turns'
done
judged 'a LiveTake log' 0
no_claim 'a LiveTake log'
for f in aa-1 aa-2 main-1 branch-1; do
  slog "$f" "${t_on[@]}" "$(A 10)" '✘ Test t() recorded an issue at X.swift:1:1: Expectation failed: (value → 0.01 seconds) <= (budget → 0.008 seconds)' \
    '↳ fit: p95 0.01 seconds' "$t_bad"
done
judged 'a read line, an issue line, and a runner comment with a time' 0 'VERIFIED XBenchmark a'
no_claim 'a read line, an issue line, and a runner comment with a time'

# Provenance: the pairs give the verdict only when the aa-* and main-* logs name one commit, the
# branch-* logs name one commit, each log ran on a clean tree, and the branch commit has the
# Sources, Tests, Package.swift, Package.resolved, and scripts/bench.sh of HEAD. A set in the
# rule exits 0; each case below changes one log or HEAD and expects exit 1 with the reason.
log "$tmp/v/branch-1.log" 10.3 10.2
mkdir "$tmp/p"
# refused <name> <reason>: --compare of $tmp/p exits 1 with "NOT VERIFIED: <reason>".
refused() {
  out="$("$pairs" --compare "$tmp/p" 2>&1)"
  code=$?
  [[ $code -eq 1 ]] && grep -qF "NOT VERIFIED: $2" <<< "$out" || fail "$1: exit $code: $out"
}
fresh() { rm -f "$tmp/p"/*; cp "$tmp"/v/*.log "$tmp/p/"; }
line() { # line <log> <new first line>
  { echo "$2"; sed 1d "$tmp/p/$1"; } > "$tmp/p/x" && mv "$tmp/p/x" "$tmp/p/$1"
}
fresh
out="$("$pairs" --compare "$tmp/p" 2>&1)"
[[ $? -eq 0 ]] || fail "a set in the rule with good provenance: $out"
line branch-2.log "bench: commit 1111111111111111111111111111111111111111 tree clean filter X"
refused 'branch logs of two commits' 'the branch logs name 2 commits'
fresh
line main-2.log "bench: commit 1111111111111111111111111111111111111111 tree clean filter X"
refused 'aa and main logs of two commits' 'the aa and main logs name 2 commits'
fresh
line branch-1.log "bench: commit $branch tree dirty filter X"
refused 'a branch log on a dirty tree' 'branch-1.log ran on a dirty tree'
fresh
line main-1.log "bench: commit $main tree dirty filter X"
refused 'a main log on a dirty tree' 'main-1.log ran on a dirty tree'
fresh
line aa-1.log 'XBenchmark a: p50 0.001 seconds, p95 0.01 seconds'
refused 'a log with no commit line' 'no bench commit line in aa-1.log'
fresh
echo y > "$r/docs/d.md"
commit docs
out="$("$pairs" --compare "$tmp/p" 2>&1)"
[[ $? -eq 0 ]] || fail "a branch commit that differs from HEAD only in docs/: $out"
echo y > "$r/Sources/A.swift"
commit sources
refused 'a branch commit with other Sources' 'the branch commit differs from HEAD in Sources'
branch="$(g rev-parse HEAD)"
log "$tmp/v/branch-1.log" 10.3 10.2
log "$tmp/v/branch-2.log" 10.2 10.1
fresh
echo y > "$r/Package.resolved"
commit resolved
refused 'a branch commit with another Package.resolved' 'the branch commit differs from HEAD in Package.resolved'
branch="$(g rev-parse HEAD)"
log "$tmp/v/branch-1.log" 10.3 10.2
log "$tmp/v/branch-2.log" 10.2 10.1
fresh
echo y > "$r/scripts/bench.sh"
commit bench
refused 'a branch commit with another bench script' 'the branch commit differs from HEAD in scripts/bench.sh'
# The main side and the branch side name one commit: an A/A comparison, not a verdict.
branch="$(g rev-parse HEAD)"
log "$tmp/v/branch-1.log" 10.3 10.2
log "$tmp/v/branch-2.log" 10.2 10.1
fresh
for f in aa-1 aa-2 main-1 main-2; do line "$f.log" "bench: commit $branch tree clean filter X"; done
refused 'the same commit on both sides' 'the main and branch logs name the same commit'

# A pair run refuses an out folder in a git tree that git does not ignore (its logs would make the
# tree dirty), before it makes the folder or runs a bench.
out="$("$pairs" "$r" X 1 "$r/pairs-out" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == *'is in a git tree and git does not ignore it'* ]] || fail "an out folder in a tree: exit $code: $out"
[[ ! -e "$r/pairs-out" ]] || fail 'an out folder in a tree: the folder was made'

# bench.sh has no Makefile line of its own: its test runs here.
bash "$(dirname "$0")/bench.test.sh" || failures=$((failures + 1))
# with-lock.sh has no Makefile line of its own either (a Makefile change makes the push class bundle).
bash "$(dirname "$0")/with-lock.test.sh" || failures=$((failures + 1))

[[ $failures -eq 0 ]] && echo "bench-pairs tests: all passed"
exit $((failures > 0))
