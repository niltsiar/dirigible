#!/bin/bash
# Check scripts/test-stress.sh in a temporary repo with copies of with-lock.sh, lock-words.sh,
# loop.sh, and test-stress.sh, a fake sysctl (1 CPU, a load from a file), a fake sleep, and a stub
# Makefile: the busy processes and TEST_SHARD_LIMIT that make sees, no busy process after the exit,
# the load wait (exit 3 and no make call), the hold and the shard limit (the default of 6600 s with
# and without history, and with WITH_LOCK_MAX_HOLD), the refusal of a hold that gives a shard under
# 2400 s (a full-suite call only: a --filter call has no limit but the hold, and no floor), of a
# call that holds the lock, and of an out folder with a summary.txt, a TERM to the
# caller and to the child of the lock (the stub make and each busy process are dead when the lock
# goes), the table of red tests (most reds first, a run with an exit and no failed test, a loop that
# stops early), and the exit status. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
pids=""
trap 'kill $pids 2>/dev/null; pkill -f "$tmp/" 2>/dev/null; rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE DIRIGIBLE_BUILD_LOCK DIRIGIBLE_LOCKED_SCRIPT WITH_LOCK_MAX_WAIT WITH_LOCK_MAX_HOLD TEST_SHARD_LIMIT
export WITH_LOCK_RETRY=0.1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

repo="$tmp/repo" lock="$tmp/repo/.git/dirigible-build.lock" holds="$tmp/repo/.git/dirigible-build-holds.log"
mkdir -p "$repo/scripts/flake-monitor" "$tmp/bin" "$tmp/stub"
cp "$here/with-lock.sh" "$here/lock-words.sh" "$repo/scripts/"
cp "$here/flake-monitor/loop.sh" "$repo/scripts/flake-monitor/"
cp "$here/test-stress.sh" "$repo/scripts/"
git -C "$repo" init -q
stress="$repo/scripts/test-stress.sh"
# The fake sysctl: 1 CPU, and the load in $tmp/load. The fake sleep returns at once, so the load
# wait of 180 s takes no time. Each other word goes to the real command.
cat > "$tmp/bin/sysctl" <<EOF
#!/bin/bash
case "\$*" in
    '-n hw.ncpu') echo 1 ;;
    '-n vm.loadavg') echo "{ \$(cat "$tmp/load") \$(cat "$tmp/load") \$(cat "$tmp/load") }" ;;
    *) exec /usr/sbin/sysctl "\$@" ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sysctl" "$tmp/bin/sleep"
echo 2.50 > "$tmp/load"
# The stub make: $STRESS_OUT is the out folder. Each run counts itself in $STRESS_OUT/n, writes its
# limit, the maxhold of the lock, and the number of live busy processes, writes the pid of make, and
# prints the failed tests of $STRESS_FAIL (one word list for each run, split by a comma).
printf 'test-filter: test\ntest:\n' > "$tmp/stub/Makefile"
printf '\t@n=$$(cat "$$STRESS_OUT/n" 2>/dev/null || echo 0); n=$$((n + 1)); echo $$n > "$$STRESS_OUT/n"; echo $$PPID > "$$STRESS_OUT/make.pid"\n' >> "$tmp/stub/Makefile"
printf '\t@alive=0; for p in $$(cat "$$STRESS_OUT/busy.pids"); do kill -0 $$p 2>/dev/null && alive=$$((alive + 1)); done; echo "busy=$$alive limit=$$TEST_SHARD_LIMIT maxhold=$$(cat "$$STRESS_LOCK/maxhold")"\n' >> "$tmp/stub/Makefile"
printf '\t@[ -z "$$STRESS_SLEEP" ] || /bin/sleep "$$STRESS_SLEEP"\n' >> "$tmp/stub/Makefile"
printf '\t@fails=$$(echo "$$STRESS_FAIL" | cut -d, -f$$(cat "$$STRESS_OUT/n")); for f in $$fails; do echo "✘ Test $$f() failed after 1.0 seconds with 1 issue."; done; [ -z "$$fails" ] || exit 1\n' >> "$tmp/stub/Makefile"
printf '#!/bin/bash\n' > "$tmp/bin/make"
printf 'exec /usr/bin/make -s --no-print-directory -C "%s" "$@"\n' "$tmp/stub" >> "$tmp/bin/make"
chmod +x "$tmp/bin/make"
export STRESS_LOCK="$lock"
dead() { ! kill -0 "$1" 2>/dev/null; }

# stress <out> <argument>...: a lane call; code and out hold the result.
stress() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  STRESS_OUT="$dir" PATH="$tmp/bin:$PATH" "$stress" "$@" "$dir" > "$tmp/out" 2>&1
  code=$?
}
rm -f "$holds"

# A green lane of 2 runs under a hold of 9600 s: the stub make sees the 2 busy processes (2 x 1 CPU)
# and the shard limit of 2400 s; no busy process lives after the exit.
export STRESS_FAIL=""
WITH_LOCK_MAX_HOLD=9600 stress "$tmp/o1" --runs 2
[[ $code -eq 0 ]] || fail "green lane: exit $code: $(cat "$tmp/out")"
[[ "$(cat "$tmp/o1/stress-1.log" "$tmp/o1/stress-2.log" 2>/dev/null | sort -u)" == 'busy=2 limit=2400 maxhold=9600' ]] ||
  fail "green lane: the stub make saw [$(cat "$tmp/o1/stress-1.log" "$tmp/o1/stress-2.log" 2>/dev/null | sort -u | paste -sd'|' -)]"
for p in $(cat "$tmp/o1/busy.pids" 2>/dev/null); do dead "$p" || fail "green lane: busy process $p lives"; done
[[ "$(wc -l < "$tmp/o1/busy.pids" 2>/dev/null | tr -d ' ')" == 2 ]] || fail "green lane: not 2 busy pids: $(cat "$tmp/o1/busy.pids" 2>/dev/null)"
grep -q '^test-stress: 0 red tests in 2 runs at a 1-minute load of ' "$tmp/out" || fail "green lane: no last line: $(tail -3 "$tmp/out")"

# The table of red tests: a() in both runs and b() in one; most reds first.
export STRESS_FAIL="a b,a"
WITH_LOCK_MAX_HOLD=9600 stress "$tmp/o2" --runs 2
[[ $code -eq 1 ]] || fail "red lane: exit $code"
want="$(printf 'test-stress: a red in 2 of 2 runs\ntest-stress: b red in 1 of 2 runs\ntest-stress: 2 red tests in 2 runs at a 1-minute load of 2.50')"
[[ "$(grep '^test-stress: ' "$tmp/out")" == "$want" ]] || fail "red lane: the table: $(grep '^test-stress: ' "$tmp/out")"
# A run with a nonzero exit and no failed test: a make that fails with no failed line.
printf 'test:\n\t@exit 1\n' > "$tmp/stub/Makefile.exit"
cp "$tmp/stub/Makefile" "$tmp/stub/Makefile.keep"
cp "$tmp/stub/Makefile.exit" "$tmp/stub/Makefile"
stress "$tmp/o3"
[[ $code -eq 1 ]] && grep -qx 'test-stress: run 1 ended with exit 2 and no failed test' "$tmp/out" || fail "no failed test: exit $code: $(grep '^test-stress' "$tmp/out")"
cp "$tmp/stub/Makefile.keep" "$tmp/stub/Makefile"

# The loop stops before run 2 (its load falls under the minimum): the lane fails and says so.
export STRESS_FAIL=""
cp "$tmp/stub/Makefile" "$tmp/stub/Makefile.keep"
printf '\t@echo 0.10 > "%s/load"\n' "$tmp" >> "$tmp/stub/Makefile"
echo 2.50 > "$tmp/load"
WITH_LOCK_MAX_HOLD=9600 stress "$tmp/o4" --runs 2
[[ $code -ne 0 ]] && grep -q 'the loop ended with exit 3 after 1 of 2 runs' "$tmp/out" || fail "early stop: exit $code: $(grep '^test-stress' "$tmp/out")"
cp "$tmp/stub/Makefile.keep" "$tmp/stub/Makefile"
echo 2.50 > "$tmp/load"

# A load under the CPU count for 180 s: exit 3, the message, and no make call.
echo 0.50 > "$tmp/load"
stress "$tmp/o5"
[[ $code -eq 3 ]] && grep -qx 'test-stress: the load source made no load' "$tmp/out" || fail "no load: exit $code: $(cat "$tmp/out")"
[[ ! -e "$tmp/o5/n" ]] || fail 'no load: make ran'
for p in $(cat "$tmp/o5/busy.pids" 2>/dev/null); do dead "$p" || fail "no load: busy process $p lives"; done
echo 2.50 > "$tmp/load"

# The hold and the shard limit: the default hold is 6600 s (the Bash background ceiling of 7200 s
# less a margin), with or without a push-check history, so 1 run gets a shard limit of 3300 s. A
# caller hold wins: 6600 s with 1 run, 9600 s with 2 runs.
printf '2026-10-17T10:00:00\t2500\tmake check-changed BASE=origin/main\t/t/a\n' > "$holds"
stress "$tmp/o6"
[[ "$(cat "$tmp/o6/stress-1.log")" == 'busy=2 limit=3300 maxhold=6600' ]] || fail "hold with history: [$(cat "$tmp/o6/stress-1.log" 2>/dev/null)]"
rm -f "$holds"
stress "$tmp/o7"
[[ "$(cat "$tmp/o7/stress-1.log")" == 'busy=2 limit=3300 maxhold=6600' ]] || fail "hold with no history: [$(cat "$tmp/o7/stress-1.log" 2>/dev/null)]"
WITH_LOCK_MAX_HOLD=7000 stress "$tmp/o8"
[[ "$(cat "$tmp/o8/stress-1.log")" == 'busy=2 limit=3500 maxhold=7000' ]] || fail "hold from the caller: [$(cat "$tmp/o8/stress-1.log" 2>/dev/null)]"
WITH_LOCK_MAX_HOLD=0 stress "$tmp/o8b" --runs 5
[[ "$(cat "$tmp/o8b/stress-5.log" 2>/dev/null)" == 'busy=2 limit=0 maxhold=0' ]] || fail "no hold limit: [$(cat "$tmp/o8b/stress-5.log" 2>/dev/null)]"

# A hold that gives a shard under 2400 s is refused with exit 2 before the lock, with the largest
# --runs that fits and no busy process. A shard of exactly 2400 s passes (a hold of 4800 s, 1 run).
refused() { # <name> <hold, or - for the default> <runs> <message>
  local dir="$tmp/r-$1"
  if [[ "$2" == - ]]; then stress "$dir" --runs "$3"; else WITH_LOCK_MAX_HOLD="$2" stress "$dir" --runs "$3"; fi
  [[ $code -eq 2 ]] && grep -qxF "test-stress: $4" "$tmp/out" && [[ ! -e "$dir/busy.pids" && ! -d "$lock" ]] ||
    fail "refusal $1: exit $code: $(cat "$tmp/out")"
}
refused default - 2 '--runs 2 with a hold of 6600 s gives each shard 1650 s, under the floor of 2400 s; the largest --runs that fits is 1, or set WITH_LOCK_MAX_HOLD to 9600 or more'
refused three 10000 3 '--runs 3 with a hold of 10000 s gives each shard 1666 s, under the floor of 2400 s; the largest --runs that fits is 2, or set WITH_LOCK_MAX_HOLD to 14400 or more'
refused near 9599 2 '--runs 2 with a hold of 9599 s gives each shard 2399 s, under the floor of 2400 s; the largest --runs that fits is 1, or set WITH_LOCK_MAX_HOLD to 9600 or more'
refused none 4000 1 '--runs 1 with a hold of 4000 s gives each shard 2000 s, under the floor of 2400 s; no --runs fits, so set WITH_LOCK_MAX_HOLD to 4800 or more'
WITH_LOCK_MAX_HOLD=4800 stress "$tmp/o8c"
[[ "$(cat "$tmp/o8c/stress-1.log" 2>/dev/null)" == 'busy=2 limit=2400 maxhold=4800' ]] || fail "a shard of exactly 2400 s: [$(cat "$tmp/o8c/stress-1.log" 2>/dev/null)]"

# A --filter call has no per-run limit and no floor: test-filter.sh reads no TEST_SHARD_LIMIT, so the
# hold bounds the whole call and the lane exports no limit. A hold of 0 is no limit, and a short
# hold is no refusal.
stress "$tmp/o8d" --runs 15 --filter 'someTest'
[[ $code -eq 0 ]] || fail "filter, 15 runs: exit $code: $(cat "$tmp/out")"
[[ "$(cat "$tmp/o8d"/stress-*.log 2>/dev/null | sort | uniq -c | tr -s ' ')" == ' 15 busy=2 limit= maxhold=6600' ]] || fail "filter, 15 runs: [$(cat "$tmp/o8d"/stress-*.log 2>/dev/null | sort | uniq -c | paste -sd'|' -)]"
WITH_LOCK_MAX_HOLD=0 stress "$tmp/o8e" --runs 3 --filter 'someTest'
[[ "$(cat "$tmp/o8e/stress-3.log" 2>/dev/null)" == 'busy=2 limit= maxhold=0' ]] || fail "filter, no hold limit: [$(cat "$tmp/o8e/stress-3.log" 2>/dev/null)]"
WITH_LOCK_MAX_HOLD=20 stress "$tmp/o8f" --runs 15 --filter 'someTest'
[[ $code -eq 0 && "$(cat "$tmp/o8f"/stress-*.log 2>/dev/null | sort | uniq -c | tr -s ' ')" == ' 15 busy=2 limit= maxhold=20' ]] ||
  fail "filter, a short hold: exit $code: $(cat "$tmp/out")"

# A call that holds the lock already exits 2 with the reason and starts no busy process; so does an
# out folder with a summary.txt. The self-wrap (the marker) runs, as the cases above show.
mkdir -p "$tmp/o9"
STRESS_OUT="$tmp/o9" DIRIGIBLE_BUILD_LOCK=4242 PATH="$tmp/bin:$PATH" "$stress" "$tmp/o9" > "$tmp/out" 2>&1
code=$?
[[ $code -eq 2 ]] && grep -qx 'test-stress: run it with no with-lock.sh word; it takes the lock with its own hold limit' "$tmp/out" && [[ ! -e "$tmp/o9/busy.pids" ]] ||
  fail "a call that holds the lock: exit $code: $(cat "$tmp/out")"
mkdir -p "$tmp/o10" && : > "$tmp/o10/summary.txt"
stress "$tmp/o10"
[[ $code -eq 2 && ! -e "$tmp/o10/busy.pids" ]] || fail "an out folder with a summary.txt: exit $code: $(cat "$tmp/out")"

# A TERM to the pid that the caller started, and a TERM to the pid of <lock>/child (the script alone):
# the stub make and each busy process are dead when the lock folder goes.
for target in caller child; do
  dir="$tmp/t-$target"
  mkdir -p "$dir"
  (STRESS_SLEEP=30 STRESS_OUT="$dir" PATH="$tmp/bin:$PATH" exec "$stress" "$dir" > "$tmp/term-$target.out" 2>&1) &
  caller=$!
  pids="$pids $caller"
  for _ in $(seq 100); do [[ -s "$dir/make.pid" ]] && break; /bin/sleep 0.1; done
  [[ -s "$dir/make.pid" ]] || { fail "term $target: the stub make did not start"; kill -KILL "$caller" 2>/dev/null; continue; }
  make_pid="$(cat "$dir/make.pid")"
  if [[ $target == caller ]]; then kill -TERM "$caller"; else kill -TERM "$(cat "$lock/child")"; fi
  for _ in $(seq 100); do [[ -d "$lock" ]] || break; /bin/sleep 0.1; done
  [[ ! -d "$lock" ]] || fail "term $target: the lock stays"
  dead "$make_pid" || fail "term $target: the stub make lives when the lock goes"
  for p in $(cat "$dir/busy.pids"); do dead "$p" || fail "term $target: busy process $p lives"; done
  wait "$caller" 2>/dev/null
done

[[ $failures -eq 0 ]] && echo "test-stress tests: all passed"
exit $((failures > 0))
