#!/bin/bash
# Check scripts/flake-stats.sh on push-check logs that this test writes: the columns of one row for
# each log (tests, suite_s, slowest_s, the loads, the class idle or loaded, reruns, flake lines and
# names, red, lost), the near input of each threshold, the summary lines (the median of the slowest
# shard for each class), and --last <n> (the run folders with the newest push-check logs, also from
# a linked worktree, and a count that is no whole number over 0), and a log with the bytes of an
# earlier log (counted once). Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/flake-stats.sh"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
cd "$tmp" || exit 1
tab=$'\t'
header="log${tab}mtime${tab}tests${tab}suite_s${tab}slowest_s${tab}start_load${tab}end_load${tab}class${tab}reruns${tab}flake_lines${tab}flake_names${tab}red${tab}lost"

# mklog <file> <start load or -> <end load or -> <tests or -> <suite seconds> <shard seconds>...: a
# push-check log with a start load line, one section for each shard seconds value (the names 1, 2,
# 3, and cli), a summary line, and an end load line. A "-" leaves the line out. The mtime is
# 2026-11-01T08:30.
mklog() {
  local file="$1" sl="$2" el="$3" tests="$4" suite="$5" i=0 s names=(1 2 3 cli)
  shift 5
  {
    echo "check-changed: scripts/check-changed.sh gives check"
    [[ "$sl" == - ]] || echo "check-changed: load $sl, under 8: run the tests"
    for s in "$@"; do
      echo "test-shards: shard ${names[$i]} (/x/.build/test-shards/shard-${names[$i]}.log)"
      echo "✔ Test run with 5 tests in 1 suite passed after $s seconds."
      i=$((i + 1))
    done
    [[ "$tests" == - ]] || echo "test-shards: $tests of $tests tests in $suite s"
    [[ "$el" == - ]] || echo "check-changed: load $el, under 8: run the tests"
  } > "$file"
  touch -t 202611010830 "$file"
}
# row <file> <tests> <suite_s> <slowest_s> <start> <end> <class> <reruns> <flake_lines> <flake_names> <red> <lost>
row() { printf '%s\t2026-11-01T08:30\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
# check <name> <expected output> <argument>...: the exact output of the script, and its exit 0.
check() {
  local name="$1" want="$2" got code
  shift 2
  got="$("$script" "$@" 2>&1)"
  code=$?
  [[ $code -eq 0 ]] || { echo "FAIL: $name: exit $code: $got"; failures=$((failures + 1)); return; }
  [[ "$got" == "$want" ]] || { echo "FAIL: $name: got [$got], want [$want]"; failures=$((failures + 1)); }
}
# row_of <name> <expected row> <argument>...: the second line of the output is the row.
row_of() {
  local name="$1" want="$2" got
  shift 2
  got="$("$script" "$@" 2>&1 | sed -n 2p)"
  [[ "$got" == "$want" ]] || { echo "FAIL: $name: got [$got], want [$want]"; failures=$((failures + 1)); }
}

# One rerun and a flake line of 3 names; the slowest shard is 120.4 s, rounded.
mklog a.log 1.50 2.00 40 130 100.5 120.4 90 80
printf 'run-checks: rerun 1 of 2: ATests BTests CTests\nrun-checks: flake: ATests BTests CTests passed on rerun 1 of 2\n' >> a.log
touch -t 202611010830 a.log
row_of 'a rerun and a flake line' "$(row a.log 40 130 120 1.50 2.00 idle 1 1 3 0 0)" a.log
check 'the header' "$header
$(row a.log 40 130 120 1.50 2.00 idle 1 1 3 0 0)
flake-stats: 1 logs, 1 reruns, 1 flake lines, 3 flake names, 0 red, 0 lost
flake-stats: idle 1 logs, median slowest shard 120 s
flake-stats: loaded 0 logs, median slowest shard - s" a.log

# A log that is red after its reruns: red 1 and no flake line.
mklog b.log 1.00 1.00 40 130 100 100 100 100
printf 'run-checks: rerun 1 of 1: ATests\nrun-checks: red after 1 reruns: ATests\n' >> b.log
touch -t 202611010830 b.log
row_of 'red after the reruns' "$(row b.log 40 130 100 1.00 1.00 idle 1 0 0 1 0)" b.log

# The class: a load under the count of shards (4) is idle; a load at the count is loaded.
mklog c1.log 3.90 3.90 40 130 50 50 50 50
mklog c2.log 4.00 3.90 40 130 50 50 50 50
mklog c3.log 3.00 - 40 130 50 50 50 50
mklog c4.log 4.00 - 40 130 50 50 50 50
row_of 'start 3.9 and end 3.9' "$(row c1.log 40 130 50 3.90 3.90 idle 0 0 0 0 0)" c1.log
row_of 'start 4.0 and end 3.9' "$(row c2.log 40 130 50 4.00 3.90 loaded 0 0 0 0 0)" c2.log
row_of 'start 3.0, no end load' "$(row c3.log 40 130 50 3.00 - idle 0 0 0 0 0)" c3.log
row_of 'start 4.0, no end load' "$(row c4.log 40 130 50 4.00 - loaded 0 0 0 0 0)" c4.log

# No summary line: the columns tests, suite_s, slowest_s, and class are "-".
mklog d.log 1.00 - - - 50 50 50 50
row_of 'no summary line' "$(row d.log - - - 1.00 - - 0 0 0 0 0)" d.log

# A shard that ended past its limit counts once; the run-checks line with "a test process" does not.
mklog e.log 1.00 1.00 40 130 50 50 50
printf 'test-shards: shard 3: the test process ended before its report (over its limit of 2 s)\nrun-checks: no rerun: a test process ended before its report\n' >> e.log
touch -t 202611010830 e.log
row_of 'one lost shard' "$(row e.log 40 130 50 1.00 1.00 idle 0 0 0 0 1)" e.log

# The summary: the median of the slowest shard is the lower middle value of the idle logs.
mklog m1.log 1 1 40 100 100 10 10 10
mklog m2.log 1 1 40 100 300 10 10 10
mklog m3.log 1 1 40 100 200 10 10 10
check 'median of three idle logs' "$header
$(row m1.log 40 100 100 1 1 idle 0 0 0 0 0)
$(row m2.log 40 100 300 1 1 idle 0 0 0 0 0)
$(row m3.log 40 100 200 1 1 idle 0 0 0 0 0)
flake-stats: 3 logs, 0 reruns, 0 flake lines, 0 flake names, 0 red, 0 lost
flake-stats: idle 3 logs, median slowest shard 200 s
flake-stats: loaded 0 logs, median slowest shard - s" m1.log m2.log m3.log
check 'median of two idle logs and a loaded log' "$header
$(row m1.log 40 100 100 1 1 idle 0 0 0 0 0)
$(row m2.log 40 100 300 1 1 idle 0 0 0 0 0)
$(row c2.log 40 130 50 4.00 3.90 loaded 0 0 0 0 0)
flake-stats: 3 logs, 0 reruns, 0 flake lines, 0 flake names, 0 red, 0 lost
flake-stats: idle 2 logs, median slowest shard 100 s
flake-stats: loaded 1 logs, median slowest shard 50 s" m1.log m2.log c2.log

# Two logs with the same bytes are one push check: only the first counts. A log that differs in one
# byte counts too.
mklog dup1.log 1 1 40 130 50 50 50 50
cp dup1.log dup2.log
mklog dup3.log 1 1 40 130 50 50 50 51
touch -t 202611010830 dup1.log dup2.log dup3.log
check 'two logs with the same bytes' "$header
$(row dup1.log 40 130 50 1 1 idle 0 0 0 0 0)
$(row dup3.log 40 130 51 1 1 idle 0 0 0 0 0)
flake-stats: 2 logs, 0 reruns, 0 flake lines, 0 flake names, 0 red, 0 lost
flake-stats: idle 2 logs, median slowest shard 50 s
flake-stats: loaded 0 logs, median slowest shard - s" dup1.log dup2.log dup3.log

# --last <n> [<runs folder>]: the n run folders whose newest push-check log is newest.
runs="$tmp/runs"
for r in old mid new; do mkdir -p "$runs/$r/logs"; done
mklog "$runs/old/logs/push-check-1.log" 1 1 40 130 50 50 50 50
mklog "$runs/old/logs/push-check.log" 1 1 40 131 50 50 50 50
mklog "$runs/mid/logs/push-check.log" 1 1 40 132 50 50 50 50
mklog "$runs/new/logs/push-check.log" 1 1 40 133 50 50 50 50
touch -t 202610010800 "$runs/old/logs/push-check-1.log"
touch -t 202610020800 "$runs/old/logs/push-check.log"
touch -t 202610100800 "$runs/mid/logs/push-check.log"
touch -t 202610200800 "$runs/new/logs/push-check.log"
mkdir -p "$runs/nolog/logs" && echo x > "$runs/nolog/logs/other.log"
logs_of() { "$script" "$@" 2>&1 | awk -F'\t' 'NR > 1 && !/^flake-stats:/ { print $1 }' | sed "s|$runs/||" | sort | paste -sd' ' -; }
[[ "$(logs_of --last 2 "$runs")" == 'mid/logs/push-check.log new/logs/push-check.log' ]] ||
  { echo "FAIL: --last 2: [$(logs_of --last 2 "$runs")]"; failures=$((failures + 1)); }
[[ "$(logs_of --last 3 "$runs")" == 'mid/logs/push-check.log new/logs/push-check.log old/logs/push-check-1.log old/logs/push-check.log' ]] ||
  { echo "FAIL: --last 3: [$(logs_of --last 3 "$runs")]"; failures=$((failures + 1)); }
# --last reads the logs of two run folders with the same bytes once.
mkdir -p "$runs/copy/logs"
cp "$runs/new/logs/push-check.log" "$runs/copy/logs/push-check-2.log"
touch -t 202610210800 "$runs/copy/logs/push-check-2.log"
[[ "$(logs_of --last 1 "$runs")" == 'copy/logs/push-check-2.log' && "$(logs_of --last 2 "$runs")" == 'copy/logs/push-check-2.log' ]] ||
  { echo "FAIL: --last with a copy of a log: [$(logs_of --last 2 "$runs")]"; failures=$((failures + 1)); }
rm -rf "$runs/copy"
for bad in 0 x -1 1.5 ''; do
  out="$("$script" --last "$bad" "$runs" 2>&1)"
  code=$?
  [[ $code -eq 2 && "$out" == usage:* && "$out" != *flake-stats:\ * ]] || { echo "FAIL: --last [$bad]: exit $code: $out"; failures=$((failures + 1)); }
done
out="$("$script" --last 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || { echo "FAIL: --last with no count: exit $code: $out"; failures=$((failures + 1)); }

# The default runs folder is .scratchpads/runs of the main checkout, also from a linked worktree.
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/.scratchpads/runs/r1/logs"
cp "$script" "$repo/scripts/flake-stats.sh"
mklog "$repo/.scratchpads/runs/r1/logs/push-check.log" 1 1 40 130 50 50 50 50
git -C "$repo" init -q -b main && git -C "$repo" add scripts &&
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base &&
  git -C "$repo" worktree add -q --detach "$tmp/wt"
want="$repo/.scratchpads/runs/r1/logs/push-check.log"
[[ "$(cd "$tmp/wt" && scripts/flake-stats.sh --last 1 2>&1 | awk -F'\t' 'NR == 2 { print $1 }')" == "$want" ]] ||
  { echo "FAIL: --last from a worktree: [$(cd "$tmp/wt" && scripts/flake-stats.sh --last 1 2>&1)]"; failures=$((failures + 1)); }
[[ "$(cd "$repo" && scripts/flake-stats.sh --last 1 2>&1 | awk -F'\t' 'NR == 2 { print $1 }')" == "$want" ]] ||
  { echo "FAIL: --last from the main checkout"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "flake-stats tests: all passed"
exit $((failures > 0))
