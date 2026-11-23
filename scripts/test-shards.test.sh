#!/bin/bash
# Check that test-shards.sh builds once, lists the tests, and runs every listed test in exactly one
# shard: a free function (an ID with no slash) too, the CLI tests in their own shard, and no
# AppBundleTests or DiskImageTests test. Check that a shard that crashes, exits 0 with no report
# line, runs fewer tests than it listed, or matches no test (exit 69) prints the text that
# run-checks.sh reads as no rerun ("the test process ended before its report"), and fails the run
# after the other shards end. Check that a failed test fails the run with its line once in the
# output, that a report line with no suite count counts, that TEST_SHARDS sets the count with the CLI shard in it (default: the physical cores), that the
# weights file balances the shards and names its stale keys, that a failed build runs no shard, that the build, the list,
# and the shards share one hold of the lock, that a journal in the default log folder or a store at the
# default Favorites path fails the run,
# and that a TERM leaves no test process alive. Check that a call with neither DIRIGIBLE_PUSH_CHECK=1
# (run-checks.sh sets it with a base) nor DIRIGIBLE_FULL_SUITE=1 (a person sets it) exits 1 with the
# reason, before the build. Check the shard limit: the value from TEST_SHARD_LIMIT or from the newest
# push-check hold (also from a linked worktree), a shard or the test list past it (one line, exit 1,
# no live test process, steps.log, the file <lock>/shard-limit, the column limit on the hold line),
# and a bad value (exit 2, no build).
# A fake swift and a stub test-helper.sh stand in for the toolchain. make test-hooks runs it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'pkill -f "$tmp/root/scripts/test-helper.sh" 2>/dev/null; rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE TEST_SHARDS DIRIGIBLE_BUILD_LOCK DIRIGIBLE_LOCKED_SCRIPT DIRIGIBLE_FULL_SUITE DIRIGIBLE_PUSH_CHECK
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root"
mkdir -p "$root/scripts" "$tmp/bin"
cp "$here/test-shards.sh" "$here/with-lock.sh" "$here/lock-words.sh" "$root/scripts/"
export FAKE_DIR="$tmp" FAKE_PID_FILE="$root/.git/dirigible-build.lock/pid"
# The fake swift logs its arguments and the lock hold; FAKE_BUILD_FAIL makes the build fail.
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
[[ -z "${FAKE_BUILD_FAIL:-}" ]] || { echo "error: the build failed"; exit 1; }
EOF
# The stub runner: --list-tests prints the list. Else it runs the IDs of the list that match its
# --filter (an extended regex, as Swift Testing matches the ID), and prints the lines of Swift
# Testing. A name in FAKE_CRASH, FAKE_FAIL, FAKE_SHORT, FAKE_NOREPORT, FAKE_HANG, FAKE_SLOW, or
# FAKE_JOURNAL, or FAKE_FAVORITES changes the run of the shard that has it: exit 132 with no report, a failed test,
# one test fewer in the report, exit 0 with no report, a wait of 60 s, a wait of 1 s before the
# tests, a journal in DIRIGIBLE_LOG_FOLDER, or a store at DIRIGIBLE_FAVORITES. FAKE_LIST_HANG makes the --list-tests call wait 60 s.
cat > "$root/scripts/test-helper.sh" <<'EOF'
#!/bin/bash
echo "runner $*" >> "$FAKE_DIR/args.log"
echo "logs ${DIRIGIBLE_LOG_FOLDER:-none}" >> "$FAKE_DIR/args.log"
echo "favorites ${DIRIGIBLE_FAVORITES:-none}" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
filter="" skips=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list-tests)
            [[ -z "${FAKE_LIST_HANG:-}" ]] || { echo $$ >> "$FAKE_DIR/hang.pid"; sleep 60; }
            cat "$FAKE_DIR/list.txt"; exit 0 ;;
        --filter) filter="$2"; shift ;;
        --skip) skips+=("$2"); shift ;;
    esac
    shift
done
ids="$(grep -E -- "$filter" "$FAKE_DIR/list.txt")"
for s in ${skips[@]+"${skips[@]}"}; do ids="$(grep -vE -- "$s" <<<"$ids")"; done
has() { [[ -n "$1" ]] && grep -q "$1" <<<"$ids"; }
[[ -n "$ids" ]] || { echo "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."; exit 69; }
if has "${FAKE_HANG:-}"; then echo $$ >> "$FAKE_DIR/hang.pid"; echo "◇ Test hang() started."; sleep 60; fi
has "${FAKE_SLOW:-}" && sleep 1
has "${FAKE_CRASH:-}" && { echo "◇ Test crash() started."; exit 132; }
has "${FAKE_JOURNAL:-}" && : > "${DIRIGIBLE_LOG_FOLDER:-/nonexistent}/2026-10-16-192000-app-1.tsv"
has "${FAKE_FAVORITES:-}" && { mkdir -p "$(dirname "$DIRIGIBLE_FAVORITES")" && : > "$DIRIGIBLE_FAVORITES"; }
n=0 code=0
while IFS= read -r id; do
    name="${id##*[./]}"
    [[ "$name" == "${FAKE_SHORT:-none}()" ]] && continue
    n=$((n + 1))
    if [[ "$name" == "${FAKE_FAIL:-none}()" ]]; then
        echo "✘ Test $name failed after 0.1 seconds with 1 issue."
        code=1
    else
        echo "✔ Test $name passed after 0.1 seconds."
    fi
done <<<"$ids"
has "${FAKE_NOREPORT:-}" && exit 0
suites=" in 1 suite"
# A real run of free functions only prints "in 0 suites"; FAKE_NOSUITE drops the part.
[[ -z "${FAKE_NOSUITE:-}" ]] || suites=""
if [[ $code -eq 0 ]]; then echo "✔ Test run with $n tests$suites passed after 0.1 seconds."
else echo "✘ Test run with $n tests$suites failed after 0.1 seconds with 1 issue."; fi
exit "$code"
EOF
chmod +x "$tmp/bin/swift" "$root/scripts/test-helper.sh"
git -C "$root" init -q && git -C "$root" add -A &&
    git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

# The list: two app suites (one with a parameterized test), an audio suite, a free function, two
# CLI tests, and one test each of the app bundle and disk image suites, which no shard runs.
cat > "$tmp/list.txt" <<'EOF'
DirigibleTests.ATests/a1()
DirigibleTests.ATests/a2(value:)
DirigibleTests.BTests/b1()
DirigibleAudioTests.CTests/c1()
DirigibleCoreTests.freeFunction()
DirigibleCLITests.DTests/d1()
DirigibleCLITests.DTests/d2()
DirigibleTests.AppBundleTests/bundle()
DirigibleTests.DiskImageTests/image()
EOF

# run <environment assignments>: a call from another folder with fresh logs; sets code and out.
# The call has DIRIGIBLE_FULL_SUITE=1 unless an assignment changes it.
run() {
    : > "$tmp/args.log" && : > "$tmp/lock.log"
    (cd / && env PATH="$tmp/bin:$PATH" DIRIGIBLE_FULL_SUITE=1 "$@" "${script:-$root/scripts/test-shards.sh}") > "$tmp/out" 2>&1
    code=$?
}
ran() { grep -cE "^(✔|✘) Test $1 (passed|failed)" "$tmp/out"; }

# The refusal: no marker, an empty value, or a value other than 1 exits 1 with the reason before
# any build. The push check marker and the override of a person let the run pass.
for env in 'DIRIGIBLE_FULL_SUITE=' 'DIRIGIBLE_FULL_SUITE=0' 'DIRIGIBLE_FULL_SUITE=yes DIRIGIBLE_PUSH_CHECK=0'; do
    run TEST_SHARDS=3 $env
    [[ $code -eq 1 ]] || fail "refusal with [$env]: exit $code, want 1: $(cat "$tmp/out")"
    for word in FILTER 'push check' DIRIGIBLE_FULL_SUITE; do
        grep -qF -- "$word" "$tmp/out" || fail "refusal with [$env]: no '$word' in the text: $(cat "$tmp/out")"
    done
    [[ ! -s "$tmp/args.log" && ! -s "$tmp/lock.log" ]] || fail "refusal with [$env]: a build or runner started: $(cat "$tmp/args.log")"
done
run TEST_SHARDS=3 DIRIGIBLE_FULL_SUITE= DIRIGIBLE_PUSH_CHECK=1
[[ $code -eq 0 ]] || fail "push check marker: exit $code: $(cat "$tmp/out")"
[[ "$(grep -c '^swift build --build-tests$' "$tmp/args.log")" -eq 1 ]] || fail "push check marker: no build: $(cat "$tmp/args.log")"

# (a) Each listed test runs once; the CLI tests in their own shard; no app bundle or disk image test.
run TEST_SHARDS=3
[[ $code -eq 0 ]] || fail "pass: exit $code: $(cat "$tmp/out")"
for t in 'a1\(\)' 'a2\(value:\)' 'b1\(\)' 'c1\(\)' 'freeFunction\(\)' 'd1\(\)' 'd2\(\)'; do
    [[ "$(ran "$t")" -eq 1 ]] || fail "pass: $t did not run once: $(cat "$tmp/out")"
done
[[ "$(ran 'bundle\(\)')$(ran 'image\(\)')" == 00 ]] || fail "pass: an app bundle or disk image test ran"
grep -qE '^test-shards: 7 of 7 tests in [0-9]+ s$' "$tmp/out" || fail "pass: no count line: $(tail -3 "$tmp/out")"
[[ "$(grep -c '^runner .*--filter' "$tmp/args.log")" -eq 3 ]] || fail "pass: not 2 shards and the CLI shard: $(cat "$tmp/args.log")"
grep -q "^runner .*--filter ^(DirigibleCLITests\\\\.)" "$tmp/args.log" || fail "pass: no CLI shard: $(cat "$tmp/args.log")"
[[ "$(grep -c '^swift build --build-tests$' "$tmp/args.log")" -eq 1 ]] || fail "pass: not one build: $(cat "$tmp/args.log")"
grep -q -- "--test-bundle-path $root/.build/debug/DirigiblePackageTests.xctest/Contents/MacOS/DirigiblePackageTests" "$tmp/args.log" ||
    fail "pass: the bundle path: $(cat "$tmp/args.log")"
[[ -f "$root/.build/test-shards/shard-1.log" && -f "$root/.build/test-shards/shard-cli.log" ]] || fail "pass: no shard logs"
# Each runner gets the empty guard folder as its journal folder.
[[ "$(grep '^logs ' "$tmp/args.log" | sort -u)" == "logs $root/.build/test-shards/default-logs" ]] ||
    fail "pass: the journal folder: $(grep '^logs ' "$tmp/args.log" | sort -u)"
# Each runner gets a Favorites store path under .build/test-shards that no run creates.
[[ "$(grep '^favorites ' "$tmp/args.log" | sort -u)" == "favorites $root/.build/test-shards/default-favorites/Favorites.dirigible" ]] ||
    fail "pass: the Favorites path: $(grep '^favorites ' "$tmp/args.log" | sort -u)"
[[ ! -e "$root/.build/test-shards/default-favorites" ]] || fail "pass: a guard folder after a clean run"
# One hold of the lock of the repo for the build, the list, and the shards.
[[ "$(grep -cE '^([0-9]+) \1$' "$tmp/lock.log")" -eq 5 && "$(sort -u "$tmp/lock.log" | wc -l | tr -d ' ')" -eq 1 ]] ||
    fail "pass: no one hold of the lock: $(cat "$tmp/lock.log")"

# The weights file: a heavy suite gets a shard of its own; a key with no weight counts 0.5 s a test.
# With no weights file, no stale line.
grep -q 'stale weights' "$tmp/out" && fail "pass: a stale line with no weights file"
printf 'DirigibleTests.BTests\t100\n' > "$root/scripts/test-shards.weights"
run TEST_SHARDS=5
[[ $code -eq 0 ]] || fail "weights: exit $code"
grep -qF -- '--filter ^(DirigibleTests\.BTests)(/|$)' "$tmp/args.log" || fail "weights: BTests is not alone: $(cat "$tmp/args.log")"
# A stale weights file shows in one line: the keys with no weight and the weight keys with no
# test. The CLI keys need no weight.
want='test-shards: stale weights: no weight: DirigibleAudioTests.CTests DirigibleCoreTests.freeFunction() DirigibleTests.ATests; no test: none'
grep -qxF "$want" "$tmp/out" || fail "weights: no stale line: $(grep stale "$tmp/out")"
printf 'DirigibleTests.BTests\t1\nDirigibleTests.ATests\t1\nDirigibleAudioTests.CTests\t1\nDirigibleCoreTests.freeFunction()\t1\nDirigibleTests.GoneTests\t1\n' > "$root/scripts/test-shards.weights"
run TEST_SHARDS=5
grep -qxF 'test-shards: stale weights: no weight: none; no test: DirigibleTests.GoneTests' "$tmp/out" || fail "weights: no stale key line: $(grep stale "$tmp/out")"
rm "$root/scripts/test-shards.weights"

# (f) The default is one shard for each physical core, the CLI shard in the count: a fake sysctl
# gives 3 cores, so 2 shards and the CLI shard.
printf '#!/bin/bash\n[[ "$*" == "-n hw.physicalcpu" ]] && echo 3\n' > "$tmp/bin/sysctl"
chmod +x "$tmp/bin/sysctl"
run
[[ $code -eq 0 ]] || fail "default: exit $code: $(cat "$tmp/out")"
[[ "$(grep -c '^runner .*--filter' "$tmp/args.log")" -eq 3 ]] || fail "default: not 3 runners for 3 cores: $(cat "$tmp/args.log")"
rm "$tmp/bin/sysctl"
# A count of 1 still keeps the CLI shard apart: 1 shard and the CLI shard.
run TEST_SHARDS=1
[[ $code -eq 0 && "$(grep -c '^runner .*--filter' "$tmp/args.log")" -eq 2 ]] || fail "one: exit $code: $(cat "$tmp/args.log")"

# A report line with no suite count counts its tests.
run TEST_SHARDS=3 FAKE_NOSUITE=1
[[ $code -eq 0 ]] || fail "no suite count: exit $code: $(tail -5 "$tmp/out")"
grep -qE '^test-shards: 7 of 7 tests in' "$tmp/out" || fail "no suite count: the count line: $(tail -3 "$tmp/out")"

# (c) A failed test fails the run; the other shards run to their end; the failed line shows once.
run TEST_SHARDS=3 FAKE_FAIL=b1
[[ $code -eq 1 ]] || fail "failed test: exit $code"
[[ "$(grep -c '^✘ Test b1() failed after' "$tmp/out")" -eq 1 ]] || fail "failed test: the failed line: $(cat "$tmp/out")"
[[ "$(ran 'd2\(\)')" -eq 1 ]] || fail "failed test: the CLI shard did not end"
grep -qF 'ended before its report' "$tmp/out" && fail "failed test: a rerunnable failure says the report ended"

# (b), (d), (e), and a crash: a lost test is never a flake.
for c in FAKE_CRASH=c1 FAKE_NOREPORT=c1 FAKE_SHORT=c1; do
    run TEST_SHARDS=3 "$c"
    [[ $code -eq 1 ]] || fail "$c: exit $code"
    grep -qE '^test-shards: shard [0-9]+: the test process ended before its report' "$tmp/out" ||
        fail "$c: no report-end line: $(tail -5 "$tmp/out")"
    [[ "$(ran 'd1\(\)')" -eq 1 ]] || fail "$c: the CLI shard did not end"
done
run TEST_SHARDS=3 FAKE_SHORT=c1
grep -qE '^test-shards: shard [0-9]+ ran 1 of 2 tests' "$tmp/out" || fail "short: no count message: $(tail -5 "$tmp/out")"
grep -qE '^test-shards: 6 of 7 tests in' "$tmp/out" || fail "short: the count line: $(tail -3 "$tmp/out")"
# (e) A shard that matches no test: a wrapper of the stub gives exit 69 and a report of 0 tests
# for each shard but the CLI shard.
mv "$root/scripts/test-helper.sh" "$tmp/helper.real"
cat > "$root/scripts/test-helper.sh" <<EOF
#!/bin/bash
[[ " \$* " == *" --list-tests "* ]] && exec "$tmp/helper.real" "\$@"
[[ " \$* " == *DirigibleCLITests* ]] && exec "$tmp/helper.real" "\$@"
echo "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."
exit 69
EOF
chmod +x "$root/scripts/test-helper.sh"
run TEST_SHARDS=2
[[ $code -eq 1 ]] || fail "no match: exit $code"
grep -qE '^test-shards: shard 1: the test process ended before its report' "$tmp/out" || fail "no match: no report-end line: $(tail -5 "$tmp/out")"
mv "$tmp/helper.real" "$root/scripts/test-helper.sh"

# A test that writes a journal to the default folder fails the run and names the file; the next
# run starts with an empty folder.
run TEST_SHARDS=3 FAKE_JOURNAL=c1
[[ $code -eq 1 ]] || fail "journal: exit $code"
grep -qxF 'test-shards: a test wrote a journal to the default log folder: 2026-10-16-192000-app-1.tsv' "$tmp/out" ||
    fail "journal: no message: $(tail -3 "$tmp/out")"
run TEST_SHARDS=3
[[ $code -eq 0 ]] || fail "journal: the next run: exit $code: $(tail -3 "$tmp/out")"

# A test that writes the default Favorites store fails the run and names the path; the next run
# removes it first.
run TEST_SHARDS=3 FAKE_FAVORITES=c1
[[ $code -eq 1 ]] || fail "favorites: exit $code"
grep -qxF "test-shards: a test wrote the default Favorites store: $root/.build/test-shards/default-favorites/Favorites.dirigible" "$tmp/out" ||
    fail "favorites: no message: $(tail -3 "$tmp/out")"
run TEST_SHARDS=3
[[ $code -eq 0 ]] || fail "favorites: the next run: exit $code: $(tail -3 "$tmp/out")"

# (g) A failed build runs no shard.
run TEST_SHARDS=3 FAKE_BUILD_FAIL=1
[[ $code -ne 0 ]] || fail "build: exit 0"
grep -q '^runner' "$tmp/args.log" && fail "build: a runner ran: $(cat "$tmp/args.log")"

# The shard limit L (C7): TEST_SHARD_LIMIT, else max(2400, 1.5 x the newest push-check hold of the
# holds log in the git common dir, a line with no fifth column limit). Each step (the list, each
# shard) runs under it; a step past it gets TERM, the run prints one line for it, and the other
# shards run to their end.
holds="$root/.git/dirigible-build-holds.log" steps="$root/.build/test-shards/steps.log"
lock="$root/.git/dirigible-build.lock"
tab=$'\t'
hold_line() { printf '2026-11-05T10:00:00\t%s\t%s\t/tree%s\n' "$1" "$2" "${3:+$tab$3}"; }
push='make check-changed BASE=origin/main'
# limit_of <name>: a pass run; lim is the <L> of its line "each shard has a limit of <L> s".
limit_of() {
    run TEST_SHARDS=3
    [[ $code -eq 0 ]] || fail "limit $1: exit $code: $(tail -3 "$tmp/out")"
    lim="$(sed -n 's/^test-shards: each shard has a limit of \([0-9]*\) s$/\1/p' "$tmp/out")"
}
rm -f "$holds"
limit_of none; [[ "$lim" == 2400 ]] || fail "limit, no holds log: $(grep 'each shard' "$tmp/out")"
{ hold_line 1300 "$push"; } > "$holds"
limit_of 1300; [[ "$lim" == 2400 ]] || fail "limit, newest push hold 1300: $(grep 'each shard' "$tmp/out")"
{ hold_line 1700 "$push"; } > "$holds"
limit_of 1700; [[ "$lim" == 2550 ]] || fail "limit, newest push hold 1700: $(grep 'each shard' "$tmp/out")"
{ hold_line 2500 "$push"; } > "$holds"
limit_of 2500; [[ "$lim" == 3750 ]] || fail "limit, newest push hold 2500: $(grep 'each shard' "$tmp/out")"
# A push check that a limit ended (fifth column limit) and a hold of another command are no base.
{ hold_line 2500 "$push"; hold_line 9000 "$push" limit; hold_line 9000 'make test-hooks'; } > "$holds"
limit_of 'limit lines'; [[ "$lim" == 3750 ]] || fail "limit, a limit line and another command after 2500: $(grep 'each shard' "$tmp/out")"
rm -f "$holds"
run TEST_SHARDS=3 TEST_SHARD_LIMIT=0
[[ $code -eq 0 ]] && grep -qxF 'test-shards: no shard limit (TEST_SHARD_LIMIT=0)' "$tmp/out" || fail "limit 0: exit $code: $(head -3 "$tmp/out")"
run TEST_SHARDS=3 TEST_SHARD_LIMIT=abc
[[ $code -eq 2 ]] && grep -qF 'TEST_SHARD_LIMIT' "$tmp/out" || fail "limit abc: exit $code: $(cat "$tmp/out")"
[[ ! -s "$tmp/args.log" ]] || fail "limit abc: a build or runner started: $(cat "$tmp/args.log")"

# A call from a linked worktree reads the holds log of the main .git: a newest push hold of 2500 gives 3750.
git -C "$root" worktree add -q --detach "$tmp/wt"
{ hold_line 2500 "$push"; } > "$holds"
script="$tmp/wt/scripts/test-shards.sh"
limit_of worktree; [[ "$lim" == 3750 ]] || fail "limit, from a worktree: $(grep 'each shard' "$tmp/out")"
unset script
rm -f "$holds"

# A pass under a limit: each step has a start and an end line in steps.log, and no limit line.
run TEST_SHARDS=3 FAKE_SLOW=c1 TEST_SHARD_LIMIT=30
[[ $code -eq 0 ]] || fail "slow shard under its limit: exit $code: $(tail -3 "$tmp/out")"
grep -q 'over its limit' "$tmp/out" && fail "slow shard under its limit: a limit line: $(grep 'over its' "$tmp/out")"
for step in 'list' 'shard 1' 'shard 2' 'shard cli'; do
    for event in start end; do
        [[ "$(grep -cE "^[0-9T:-]+ $step $event\$" "$steps")" -eq 1 ]] || fail "steps.log: no '$step $event' line: $(cat "$steps")"
    done
done
grep -q ' limit$' "$steps" && fail "slow shard under its limit: a limit line in steps.log: $(cat "$steps")"

# A shard past its limit: one line for it, exit 1, each other shard reports in full, no test process
# of it stays, steps.log names it, and the hold line of the lock gets the column limit.
: > "$tmp/hang.pid"
run TEST_SHARDS=3 FAKE_HANG=c1 TEST_SHARD_LIMIT=2
[[ $code -eq 1 ]] || fail "shard limit: exit $code, want 1"
grep -qxF 'test-shards: shard 2: the test process ended before its report (over its limit of 2 s)' "$tmp/out" ||
    fail "shard limit: no limit line: $(grep -E 'test-shards: shard' "$tmp/out")"
[[ "$(grep -c 'over its limit' "$tmp/out")" -eq 1 ]] || fail "shard limit: not one limit line: $(grep 'over its limit' "$tmp/out")"
grep -q 'shard cli: the test process ended' "$tmp/out" && fail "shard limit: a lost line for the CLI shard"
for t in 'a1\(\)' 'a2\(value:\)' 'b1\(\)' 'd1\(\)' 'd2\(\)'; do
    [[ "$(ran "$t")" -eq 1 ]] || fail "shard limit: $t did not run once: $(cat "$tmp/out")"
done
! kill -0 "$(cat "$tmp/hang.pid")" 2>/dev/null || fail "shard limit: the hung test process is alive"
grep -qE '^[0-9T:-]+ shard 2 limit$' "$steps" || fail "shard limit: no 'shard 2 limit' in steps.log: $(cat "$steps")"
for step in 'shard 1' 'shard cli'; do
    grep -qE "^[0-9T:-]+ $step end\$" "$steps" || fail "shard limit: no '$step end' in steps.log: $(cat "$steps")"
done
[[ "$(tail -n 1 "$holds" | awk -F'\t' '{ print $5 }')" == limit ]] || fail "shard limit: the hold line has no column limit: $(tail -n 1 "$holds")"
# With the lock folder of the call, the limit leaves <lock>/shard-limit; a pass under its limit leaves none.
mkdir -p "$lock" && echo 4242 > "$lock/pid"
run TEST_SHARDS=3 FAKE_SLOW=c1 TEST_SHARD_LIMIT=30 DIRIGIBLE_LOCKED_SCRIPT="$root/scripts/test-shards.sh" DIRIGIBLE_BUILD_LOCK=4242
[[ $code -eq 0 && ! -e "$lock/shard-limit" ]] || fail "shard limit, pass: exit $code, shard-limit file [$(ls "$lock")]"
run TEST_SHARDS=3 FAKE_HANG=c1 TEST_SHARD_LIMIT=2 DIRIGIBLE_LOCKED_SCRIPT="$root/scripts/test-shards.sh" DIRIGIBLE_BUILD_LOCK=4242
[[ -e "$lock/shard-limit" ]] || fail "shard limit: no file $lock/shard-limit [$(ls "$lock")]"
rm -rf "$lock"

# A test list past its limit: its line, exit 1, and no shard starts.
: > "$tmp/hang.pid"
run TEST_SHARDS=3 FAKE_LIST_HANG=1 TEST_SHARD_LIMIT=2
[[ $code -eq 1 ]] || fail "list limit: exit $code, want 1"
grep -qxF 'test-shards: the test list: the test process ended before its report (over its limit of 2 s)' "$tmp/out" ||
    fail "list limit: no limit line: $(cat "$tmp/out")"
grep -q '^runner .*--filter' "$tmp/args.log" && fail "list limit: a shard started: $(cat "$tmp/args.log")"
grep -qE '^[0-9T:-]+ list limit$' "$steps" || fail "list limit: no 'list limit' in steps.log: $(cat "$steps")"
! kill -0 "$(cat "$tmp/hang.pid")" 2>/dev/null || fail "list limit: the hung list process is alive"

# A TERM stops every shard, leaves no test process, keeps the logs, names only the shard that ran,
# prints its tail, and exits 143.
: > "$tmp/hang.pid"
: > "$tmp/args.log" && : > "$tmp/lock.log"
# The lock marker skips the with-lock.sh wrap, so the TERM and the exit code are the script's own.
# kill logs each pid that has ended when a signal goes to it: the number can belong to another process.
: > "$tmp/stale.log"
(STALE_LOG="$tmp/stale.log"; export STALE_LOG
    kill() { local a; if [[ "$1" != -0 ]]; then for a in "$@"; do [[ "$a" =~ ^[0-9]+$ ]] && ! builtin kill -0 "$a" 2>/dev/null && echo "$a" >> "$STALE_LOG"; done; fi; builtin kill "$@"; }
    export -f kill
    cd / && exec env PATH="$tmp/bin:$PATH" TEST_SHARDS=3 FAKE_HANG=c1 FAKE_SLOW=d1 DIRIGIBLE_FULL_SUITE=1 DIRIGIBLE_LOCKED_SCRIPT="$root/scripts/test-shards.sh" \
    "$root/scripts/test-shards.sh") > "$tmp/out" 2>&1 &
pid=$!
for _ in $(seq 100); do [[ -s "$tmp/hang.pid" ]] && break; sleep 0.1; done
[[ -s "$tmp/hang.pid" ]] || fail "term: the hanging shard did not start"
# The TERM comes after each other shard wrote its report, so only the hanging shard still runs.
settled() {
    local f
    [[ "$(ls "$root/.build/test-shards"/shard-*.log 2>/dev/null | wc -l)" -eq 3 ]] || return 1
    for f in "$root/.build/test-shards"/shard-*.log; do grep -qE 'Test run with|Test hang\(\) started' "$f" || return 1; done
}
for _ in $(seq 600); do settled && break; sleep 0.1; done
settled || fail "term: a shard neither ended nor hung"
kill -TERM "$pid"
wait "$pid"
code=$?
[[ $code -eq 143 ]] || fail "term: exit $code, want 143"
[[ ! -s "$tmp/stale.log" ]] || fail "term: stop signalled a shard that had ended (pid $(tr '\n' ' ' < "$tmp/stale.log"))"
[[ "$(grep -c '^test-shards: shard .* stopped' "$tmp/out")" -eq 1 ]] || fail "term: not only the running shard named: $(grep stopped "$tmp/out")"
sleep 0.5
! kill -0 "$(cat "$tmp/hang.pid")" 2>/dev/null || fail "term: a test process is alive"
pgrep -f "$root/scripts/test-helper.sh" > /dev/null && fail "term: a runner is alive"
grep -q '◇ Test hang() started.' "$tmp/out" || fail "term: no tail of the unfinished shard: $(cat "$tmp/out")"
[[ -f "$root/.build/test-shards/shard-cli.log" ]] || fail "term: no shard logs"

[[ $failures -eq 0 ]] || { echo "test-shards.test.sh: $failures failures"; exit 1; }
echo "test-shards.test.sh: all passed"
