#!/bin/bash
# Check that check-changed.sh prints the right three lines for each kind of change, fails closed
# on a bad or empty base, still sees a moved floor file, and that each risk floor path exists.
# Check that `make check-changed` of the real Makefile exits nonzero when the script does, and
# runs no target (not the default goal `setup`) for an empty target list. Check that FILTER
# gives test-filter in place of test, and reaches the swift calls through make. Check that a
# passing make check-changed with BASE writes the stamp, and a red one does not. Check that the push
# adds test-slow-push only for risk, a slow test, a Makefile change, or no passed slow run today,
# and PUSH_RUN=<names> for a changed PUSH_SKIP file. Check that test-slow-push has no test of a
# PUSH_SKIP file outside PUSH_RUN, that a passing make test-slow or test-slow-push writes the
# date, and that check-slow-gates fails on a PUSH_SKIP name with no file or with no Benchmark.
# Check that the recipe waits for a load under the core count before Swift tests, stops the wait
# at CHECK_LOAD_WAIT, and reads no load for docs targets. Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/scripts/check-changed.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A git or make value of an outer run must not reach the temporary repos of this test.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKEFLAGS MFLAGS MAKELEVEL BASE FILTER

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
today="$(date +%F)"

# The stdin cases run in a repo of their own, so the slow-run date of this clone does not change them.
# It has a passed slow run today and one slow test.
e="$tmp/e"
git init -q "$e"
echo "$today" > "$e/.git/dirigible-slow-date"
mkdir -p "$e/Tests/DirigibleCoreTests"
printf 'guard ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1" else { return }\nfunc testLong() {}\n' \
  > "$e/Tests/DirigibleCoreTests/LongTests.swift"

# expect <name> <want> [--push]: the paths come from stdin, and the whole output must be <want>.
expect() {
  local name="$1" want="$2" got
  shift 2
  got="$(cd "$e" && "$script" --paths "$@")" || { fail "$name: exit $?"; return; }
  [[ "$got" == "$want" ]] || fail "$name: got [$got], want [$want]"
}
out() { printf 'classes: %s\ntargets: %s\nrisk: %s' "$1" "$2" "$3"; }

expect 'docs only' "$(out docs check-docs no)" <<<'.claude/skills/tdd/SKILL.md'
expect 'a probe script' "$(out tooling check-fast no)" <<<'scripts/probe.sh'
expect 'a skill doc and a skill script' "$(out 'docs tooling' check-fast no)" \
  <<<$'.claude/skills/deliver/SKILL.md\n.claude/skills/deliver/scripts/new-run.sh'
expect 'Makefile local' "$(out bundle check no)" <<<'Makefile'
expect 'Makefile before the push' "$(out bundle 'check test-slow-push test-dmg' no)" --push <<<'Makefile'
expect 'Package.swift local' "$(out build check no)" <<<'Package.swift'
expect 'Package.swift before the push' "$(out build check no)" --push <<<'Package.swift'
expect 'Tests only' "$(out tests test no)" <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'Tests only before the push' "$(out tests check no)" --push <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'app sources local' "$(out sources test no)" <<<'Sources/DirigibleApp/AppDelegate.swift'
expect 'app sources before the push' "$(out sources check no)" --push <<<'Sources/DirigibleApp/AppDelegate.swift'
expect 'capture sources' "$(out sources-risk 'check test-slow-push' yes)" --push \
  <<<'Sources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'capture sources local' "$(out sources-risk test yes)" <<<'Sources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'session writer' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/SessionWriter.swift'
expect 'Makefile and capture sources' "$(out 'sources-risk bundle' 'check test-slow-push test-dmg' yes)" --push \
  <<<$'Makefile\nSources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'Support' "$(out bundle 'check test-dmg' no)" --push <<<'Support/Info.plist'
expect 'bundle script before the push' "$(out bundle 'check test-dmg' no)" --push <<<'scripts/bundle.sh'
expect 'bundle script' "$(out bundle check no)" <<<'scripts/bundle.sh'
expect 'app bundle test' "$(out bundle check no)" <<<'Tests/DirigibleTests/AppBundleTests.swift'
expect 'guide converter' "$(out bundle check no)" <<<'scripts/guide-html.swift'
expect 'unknown top-level file' "$(out build check no)" <<<'unknown.txt'
expect 'docs and sources' "$(out 'docs sources' 'check-docs test' no)" \
  <<<$'docs/guide.md\nSources/DirigibleApp/AppDelegate.swift'
expect 'docs, tooling, and the Makefile before the push' "$(out 'docs tooling bundle' 'check test-slow-push test-dmg' no)" --push \
  <<<$'AGENTS.md\nscripts/check-changed.sh\nMakefile'
expect 'empty list, no base' "$(out none none no)" </dev/null

# test-slow before the push: a slow test (a file with the gate) adds it; the local targets do not.
expect 'a slow test before the push' "$(out tests 'check test-slow-push' no)" --push <<<'Tests/DirigibleCoreTests/LongTests.swift'
expect 'a slow test local' "$(out tests test no)" <<<'Tests/DirigibleCoreTests/LongTests.swift'
# No passed slow run today: a push with check adds it once; a docs or tooling push does not.
echo 2000-01-01 > "$e/.git/dirigible-slow-date"
expect 'no slow run today, Tests' "$(out tests 'check test-slow-push' no)" --push <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'no slow run today, docs' "$(out docs check-docs no)" --push <<<'docs/guide.md'
expect 'no slow run today, tooling' "$(out tooling check-fast no)" --push <<<'scripts/probe.sh'
rm "$e/.git/dirigible-slow-date"
expect 'no date file' "$(out sources 'check test-slow-push' no)" --push <<<'Sources/DirigibleApp/AppDelegate.swift'
echo "$today" > "$e/.git/dirigible-slow-date"
# A changed bench file that PUSH_SKIP of the Makefile names runs test-slow-push with PUSH_RUN, so
# its tests run and the tests of the other PUSH_SKIP files do not. Two files give one sorted word.
expect 'a PUSH_SKIP bench before the push' "$(out tests 'check test-slow-push PUSH_RUN=LoudnessBenchmark' no)" --push <<<'Tests/DirigibleAudioTests/LoudnessBenchmark.swift'
expect 'two PUSH_SKIP benches before the push' "$(out tests 'check test-slow-push PUSH_RUN=EditBenchmark,LoudnessBenchmark' no)" --push \
  <<<$'Tests/DirigibleAudioTests/LoudnessBenchmark.swift\nTests/DirigibleCoreTests/EditBenchmark.swift'
expect 'the Makefile and a PUSH_SKIP bench before the push' "$(out 'tests bundle' 'check test-slow-push test-dmg PUSH_RUN=LoudnessBenchmark' no)" --push \
  <<<$'Makefile\nTests/DirigibleAudioTests/LoudnessBenchmark.swift'
# Outside a git repo there is no date, so the push runs the slow tests.
got="$(cd "$tmp" && "$script" --paths --push <<<'Tests/A.swift')" || fail "outside a repo: exit $?"
[[ "$got" == "$(out tests 'check test-slow-push' no)" ]] || fail "outside a repo: got [$got]"

# FILTER: the tests of the slice in place of all tests. The other targets do not change.
FILTER=ClipTests expect 'tests with FILTER' "$(out tests test-filter no)" <<<'Tests/DirigibleCoreTests/SessionTests.swift'
FILTER=ClipTests expect 'docs with FILTER' "$(out docs check-docs no)" <<<'docs/guide.md'
FILTER=ClipTests expect 'bundle with FILTER' "$(out bundle check no)" <<<'Makefile'
FILTER='ClipTests TrackTests' expect 'tooling and sources with FILTER' "$(out 'tooling sources' 'check-fast test-filter' no)" \
  <<<$'scripts/probe.sh\nSources/DirigibleApp/AppDelegate.swift'
# FILTER before the push: exit nonzero with the reason, because the push runs the full targets.
got="$(FILTER=ClipTests "$script" --paths --push 2>&1 <<<'Tests/A.swift')" && fail 'FILTER with --push exits 0'
[[ "$got" == *"FILTER is for the tdd loop of a slice"* ]] || fail "FILTER with --push: no reason: $got"

# Floor case: each risk floor path exists, so a rename cannot drop a file out of the floor.
floor="$("$script" --floor)" || fail "--floor exits $?"
[[ -n "$floor" ]] || fail '--floor prints no path'
for p in $floor; do
  [[ -e "$repo/$p" ]] || fail "floor path $p does not exist; change the floor in check-changed.sh"
done

# A temporary repo with one commit on main.
g() { git -C "$tmp/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
new_repo() {
  rm -rf "$tmp/r"
  mkdir -p "$tmp/r/docs" "$tmp/r/scripts" "$tmp/r/Sources/DirigibleCore"
  g init -q -b main
  printf 'a\n' > "$tmp/r/docs/a.md"
  printf 'b\n' > "$tmp/r/scripts/b.sh"
  printf 'w\n' > "$tmp/r/Sources/DirigibleCore/SessionWriter.swift"
  g add -A
  g commit -q -m base
}
run_in() { (cd "$tmp/r" && "$script" "$@"); }

# No base: the changed file and the untracked file, not the committed file with no change.
new_repo
printf 'b2\n' > "$tmp/r/scripts/b.sh"
mkdir -p "$tmp/r/Tests"
printf 't\n' > "$tmp/r/Tests/T.swift"
got="$(run_in)" || fail "no base: exit $?"
[[ "$got" == "$(out 'tooling tests' 'check-fast test' no)" ]] || fail "no base: got [$got]"

# A base that does not exist: exit nonzero and nothing on stdout.
new_repo
got="$(run_in does-not-exist 2>/dev/null)" && fail 'a bad base exits 0'
[[ -z "$got" ]] || fail "a bad base prints [$got]"

# FILTER with a base: exit nonzero with the reason.
new_repo
printf 'b2\n' > "$tmp/r/scripts/b.sh"
got="$(cd "$tmp/r" && FILTER=ClipTests "$script" main 2>&1)" && fail 'FILTER with a base exits 0'
[[ "$got" == *"FILTER is for the tdd loop of a slice"* ]] || fail "FILTER with a base: no reason: $got"

# A base with no diff: exit 1 and the reason.
new_repo
err="$(run_in main 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "a base with no diff: expected exit 1, got $code"
[[ "$err" == *"no changed paths against main"* ]] || fail "a base with no diff: no reason: $err"

# A branch with a Sources commit against its base: the push targets.
new_repo
g switch -q -c feat/x
mkdir -p "$tmp/r/Sources/DirigibleApp"
printf 'x\n' > "$tmp/r/Sources/DirigibleApp/X.swift"
g add -A
g commit -q -m x
got="$(run_in main)" || fail "a Sources branch: exit $?"
[[ "$got" == "$(out sources 'check test-slow-push' no)" ]] || fail "a Sources branch with no slow run today: got [$got]"
echo "$today" > "$tmp/r/.git/dirigible-slow-date"
got="$(run_in main)" || fail "a Sources branch: exit $?"
[[ "$got" == "$(out sources check no)" ]] || fail "a Sources branch with a slow run today: got [$got]"

# A move of a floor file: --no-renames lists the old path, so risk stays yes.
new_repo
g switch -q -c feat/move
mkdir -p "$tmp/r/Sources/DirigibleCore/Session"
g mv Sources/DirigibleCore/SessionWriter.swift Sources/DirigibleCore/Session/SessionWriter.swift
g commit -q -m move
got="$(run_in main)" || fail "a moved floor file: exit $?"
[[ "$got" == *$'\nrisk: yes' ]] || fail "a moved floor file: got [$got]"

# make check-changed with the real Makefile and script. A wrong recipe runs the default goal
# `setup`, which sets core.hooksPath, so each case also checks that the value stays unset.
# make exits 2 when a recipe fails, so a refused case asserts a nonzero exit and its reason.
make_case() {
  local name="$1" reason="$2" code
  shift 2
  output="$(make -s -C "$tmp/r" check-changed "$@" 2>&1)"
  code=$?
  if [[ -z "$reason" ]]; then
    [[ $code -eq 0 ]] || fail "$name: expected exit 0, got $code: $output"
  else
    [[ $code -ne 0 ]] || fail "$name: expected a nonzero exit, got 0"
    [[ "$output" == *"$reason"* ]] || fail "$name: no '$reason' in: $output"
  fi
  [[ -z "$(g config --get core.hooksPath)" ]] || fail "$name: the default goal ran (core.hooksPath is set)"
}
make_repo() {
  new_repo
  cp "$repo/Makefile" "$tmp/r/Makefile"
  cp "$script" "$tmp/r/scripts/check-changed.sh"
  cp "$repo/scripts/check-stamp.sh" "$repo/scripts/test-filter.sh" "$repo/scripts/run-checks.sh" "$tmp/r/scripts/"
  g add -A
  g commit -q -m make
}
make_repo; make_case 'make check-changed with a bad base' 'does-not-exist' BASE=does-not-exist
make_repo; make_case 'make check-changed with a base with no diff' 'no changed paths against main' BASE=main
make_repo; make_case 'make check-changed with no changed path' ''
# The first line names the commit, the tree state, the base, and the targets (cost.sh reads it).
[[ "$output" == "check-changed: commit $(g rev-parse HEAD) tree clean base none targets none"$'\n'* ]] ||
  fail "make check-changed: no check-changed line first: $output"

# FILTER reaches the swift calls through the recipe and the sub-make: one --filter for each word.
make_repo
mkdir -p "$tmp/bin" "$tmp/r/Tests/DirigibleCoreTests"
printf '#!/bin/bash\necho "swift $*" >> "%s"\necho "Test run with 2 tests passed after 0.1 seconds."\n' "$tmp/swift.log" > "$tmp/bin/swift"
chmod +x "$tmp/bin/swift"
printf 't\n' > "$tmp/r/Tests/DirigibleCoreTests/T.swift"
: > "$tmp/swift.log"
# A fake sysctl gives 8 cores and the loads of $tmp/load, one line for each call; the last line
# stays. A fake sleep logs its seconds, so a wait takes no time.
cat > "$tmp/bin/sysctl" <<EOF
#!/bin/bash
echo "\$*" >> "$tmp/sysctl.log"
case "\$2" in
  hw.ncpu) echo 8 ;;
  vm.loadavg) echo "{ \$(head -n 1 "$tmp/load") 1.00 1.00 }"; [[ \$(wc -l < "$tmp/load") -gt 1 ]] && sed -i '' 1d "$tmp/load" ;;
esac
exit 0
EOF
printf '#!/bin/bash\necho "$1" >> "%s"\n' "$tmp/sleep.log" > "$tmp/bin/sleep"
# A fake pgrep logs its arguments and prints the first line of $tmp/procs, one line for each
# call; the last line stays. An empty line is no match: no output and exit 1, as the real pgrep.
cat > "$tmp/bin/pgrep" <<EOF
#!/bin/bash
echo "\$*" >> "$tmp/pgrep.log"
line="\$(head -n 1 "$tmp/procs")"
[[ \$(wc -l < "$tmp/procs") -gt 1 ]] && sed -i '' 1d "$tmp/procs"
[[ -n "\$line" ]] || exit 1
echo "\$line"
EOF
: > "$tmp/procs"
chmod +x "$tmp/bin/sysctl" "$tmp/bin/sleep" "$tmp/bin/pgrep"
echo 1.00 > "$tmp/load"
PATH="$tmp/bin:$PATH" make_case 'make check-changed with FILTER' '' "FILTER=ATests BTests"
[[ "$output" == *"targets: test-filter"* ]] || fail "make check-changed with FILTER: no test-filter target: $output"
[[ "$(cat "$tmp/swift.log")" == "swift test --skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests --filter ATests --filter BTests" ]] ||
  fail "make check-changed with FILTER: swift calls: $(cat "$tmp/swift.log")"

# The load wait: before Swift tests, the recipe waits until the 1-minute load is under the core
# count, prints each load that it reads, and after CHECK_LOAD_WAIT seconds runs the tests anyway.
: > "$tmp/swift.log"; : > "$tmp/sleep.log"
printf '9.50\n8.00\n2.00\n' > "$tmp/load"
PATH="$tmp/bin:$PATH" make_case 'a high load, then a low load' '' FILTER=ATests
[[ "$output" == *"load 9.50, not under 8"*"load 8.00, not under 8"*"load 2.00, under 8"* ]] || fail "a high load: no load lines in order: $output"
[[ "$(cat "$tmp/sleep.log")" == $'10\n10' ]] || fail "a high load: sleeps [$(cat "$tmp/sleep.log")]"
[[ -s "$tmp/swift.log" ]] || fail 'a high load: the tests did not run after the wait'
: > "$tmp/swift.log"; : > "$tmp/sleep.log"
echo 9.50 > "$tmp/load"
CHECK_LOAD_WAIT=20 CHECK_LOAD_MAX=4.5 PATH="$tmp/bin:$PATH" make_case 'a load that stays high' '' FILTER=ATests
[[ "$output" == *"load 9.50 after 20 s, not under 4.5: run the tests"* ]] || fail "a load that stays high: no stop line: $output"
[[ "$(cat "$tmp/sleep.log")" == $'10\n10' ]] || fail "a load that stays high: sleeps [$(cat "$tmp/sleep.log")]"
[[ -s "$tmp/swift.log" ]] || fail 'a load that stays high: the tests did not run'
# The default cap is 300 s, so the wait and the tests of a slice fit in one 600 s Bash call. The
# load lines go to stderr.
: > "$tmp/sleep.log"
echo 9.50 > "$tmp/load"
got="$(CHECK_LOAD_MAX=4.5 PATH="$tmp/bin:$PATH" "$script" --wait-load test 2> "$tmp/wait.err")" || fail "the default cap exits $?"
[[ -z "$got" ]] || fail "the default cap: load lines on stdout: [$(tail -n 1 <<<"$got")]"
grep -q 'load 9.50 after 300 s, not under 4.5: run the tests' "$tmp/wait.err" || fail "the default cap: no stop line at 300 s: $(tail -n 1 "$tmp/wait.err")"
[[ "$(wc -l < "$tmp/sleep.log" | tr -d ' ')" == 30 ]] || fail "the default cap: $(wc -l < "$tmp/sleep.log") sleeps, want 30"
# Targets with no Swift test read no load.
: > "$tmp/sysctl.log"
got="$(PATH="$tmp/bin:$PATH" "$script" --wait-load check-docs check-fast 2>&1)" || fail "--wait-load with docs targets exits $?"
[[ -z "$got" && ! -s "$tmp/sysctl.log" ]] || fail "--wait-load with docs targets read the load: [$got] [$(cat "$tmp/sysctl.log")]"

# A test of another tree (a swiftpm-testing-helper whose command line does not hold
# <root>/.build/, also a nested worktree) makes the wait go on at a low load. A helper of this
# tree does not. The wait matches the executable path, not the bare word.
wait_case() {
  : > "$tmp/sleep.log"; : > "$tmp/pgrep.log"; echo 1.00 > "$tmp/load"
  got="$(cd "$tmp/r" && PATH="$tmp/bin:$PATH" "$script" --wait-load test 2> "$tmp/wait.err")"
}
root="$(git -C "$tmp/r" rev-parse --show-toplevel)"
other="101 $root/.claude/worktrees/x/.build/debug/swiftpm-testing-helper --test-bundle-path $root/.claude/worktrees/x/.build/debug/T.xctest"
printf '%s\n%s\n\n' "$other" "$other" > "$tmp/procs"
wait_case || fail "a test of another tree: exit $?"
# The wait line names the helper with its command line, so its tree is known.
[[ "$(grep -cF "a test of another tree runs (pid ${other/ /: }): wait 10 s" "$tmp/wait.err")" == 2 ]] || fail "a test of another tree: wait lines: $(cat "$tmp/wait.err")"
[[ "$(tail -n 1 "$tmp/wait.err")" == "check-changed: load 1.00, under 8: run the tests" ]] || fail "a test of another tree: last line: $(tail -n 1 "$tmp/wait.err")"
[[ "$(cat "$tmp/sleep.log")" == $'10\n10' ]] || fail "a test of another tree: sleeps [$(cat "$tmp/sleep.log")]"
grep -qx -- "-lf /swiftpm-testing-helper " "$tmp/pgrep.log" || fail "a test of another tree: pgrep arguments [$(head -n 1 "$tmp/pgrep.log")]"
printf '102 %s/.build/debug/swiftpm-testing-helper --test-bundle-path %s/.build/debug/T.xctest\n' "$root" "$root" > "$tmp/procs"
wait_case || fail "a test of this tree: exit $?"
[[ ! -s "$tmp/sleep.log" ]] && ! grep -q 'wait 10 s' "$tmp/wait.err" || fail "a test of this tree: it waited: $(cat "$tmp/wait.err")"
: > "$tmp/procs"
wait_case || fail "no test and a low load: exit $?"
[[ ! -s "$tmp/sleep.log" && "$(cat "$tmp/wait.err")" == "check-changed: load 1.00, under 8: run the tests" ]] || fail "no test and a low load: [$(cat "$tmp/wait.err")]"
printf '%s\n' "$other" > "$tmp/procs"
CHECK_LOAD_WAIT=20 wait_case || fail "a test of another tree that stays: exit $?"
[[ "$(cat "$tmp/sleep.log")" == $'10\n10' ]] || fail "a test of another tree that stays: sleeps [$(cat "$tmp/sleep.log")]"
[[ "$(tail -n 1 "$tmp/wait.err")" == "check-changed: a test of another tree runs after 20 s (pid ${other/ /: }): run the tests" ]] || fail "a test of another tree that stays: last line: $(tail -n 1 "$tmp/wait.err")"
: > "$tmp/procs"

# make test-slow and make test-slow-push write the date of today after a pass, and nothing after
# a red run. The temporary repo has no bench file, so PUSH_SKIP is empty on the command line.
for target in test-slow test-slow-push; do
  make_repo
  printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/swift"
  PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" $target PUSH_SKIP= > /dev/null 2>&1 && fail "make $target with a red swift exits 0"
  [[ ! -e "$tmp/r/.git/dirigible-slow-date" ]] || fail "a red make $target wrote the date"
  printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/swift"
  PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" $target PUSH_SKIP= > /dev/null 2>&1 || fail "make $target with a green swift exits nonzero"
  [[ "$(cat "$tmp/r/.git/dirigible-slow-date" 2>/dev/null)" == "$today" ]] || fail "a passing make $target did not write the date"
done

# test-slow-push passes no func of a PUSH_SKIP file to swift; test-slow passes each slow func.
make_repo
mkdir -p "$tmp/r/Tests/DirigibleAudioTests"
gate='guard ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1" else { return }'
printf '%s\nfunc aSkippedBench() {}\n' "$gate" > "$tmp/r/Tests/DirigibleAudioTests/LoudnessBenchmark.swift"
printf '%s\nfunc aKeptSlowTest() {}\n' "$gate" > "$tmp/r/Tests/DirigibleAudioTests/KeptTests.swift"
printf '#!/bin/bash\necho "swift $*" >> "%s"\n' "$tmp/swift.log" > "$tmp/bin/swift"
: > "$tmp/swift.log"
PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" test-slow-push PUSH_SKIP=LoudnessBenchmark > /dev/null 2>&1 || fail 'make test-slow-push exits nonzero'
[[ "$(cat "$tmp/swift.log")" == *"--filter aKeptSlowTest" ]] || fail "make test-slow-push: swift calls [$(cat "$tmp/swift.log")]"
# PUSH_RUN names a PUSH_SKIP file whose slow tests run in test-slow-push.
: > "$tmp/swift.log"
PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" test-slow-push PUSH_SKIP=LoudnessBenchmark PUSH_RUN=LoudnessBenchmark > /dev/null 2>&1 || fail 'make test-slow-push with PUSH_RUN exits nonzero'
[[ "$(cat "$tmp/swift.log")" == *aSkippedBench* && "$(cat "$tmp/swift.log")" == *aKeptSlowTest* ]] || fail "make test-slow-push with PUSH_RUN: swift calls [$(cat "$tmp/swift.log")]"
# PUSH_RUN with two names, joined with a comma as check-changed.sh prints it, brings back both files.
printf '%s\nfunc aSecondBench() {}\n' "$gate" > "$tmp/r/Tests/DirigibleAudioTests/EditBenchmark.swift"
: > "$tmp/swift.log"
PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" test-slow-push PUSH_SKIP='LoudnessBenchmark EditBenchmark' PUSH_RUN=EditBenchmark,LoudnessBenchmark > /dev/null 2>&1 || fail 'make test-slow-push with two PUSH_RUN names exits nonzero'
[[ "$(cat "$tmp/swift.log")" == *aSkippedBench* && "$(cat "$tmp/swift.log")" == *aSecondBench* ]] || fail "make test-slow-push with two PUSH_RUN names: swift calls [$(cat "$tmp/swift.log")]"
: > "$tmp/swift.log"
PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" test-slow PUSH_SKIP=LoudnessBenchmark > /dev/null 2>&1 || fail 'make test-slow exits nonzero'
[[ "$(cat "$tmp/swift.log")" == *aSkippedBench* && "$(cat "$tmp/swift.log")" == *aKeptSlowTest* ]] || fail "make test-slow: swift calls [$(cat "$tmp/swift.log")]"
# check-slow-gates fails on a PUSH_SKIP name with no file under Tests/, with the reason.
got="$(make -s -C "$tmp/r" check-slow-gates PUSH_SKIP='LoudnessBenchmark NoSuchBench' 2>&1)" && fail 'a PUSH_SKIP name with no file: exit 0'
[[ "$got" == *"PUSH_SKIP names NoSuchBench, which has no file under Tests/"* ]] || fail "a PUSH_SKIP name with no file: no reason: $got"
make -s -C "$tmp/r" check-slow-gates PUSH_SKIP=LoudnessBenchmark > /dev/null 2>&1 || fail 'check-slow-gates with a PUSH_SKIP file: exit nonzero'
# check-slow-gates fails on a PUSH_SKIP name that is not a bench file, also when the file exists.
got="$(make -s -C "$tmp/r" check-slow-gates PUSH_SKIP='LoudnessBenchmark KeptTests' 2>&1)" && fail 'a PUSH_SKIP name with no Benchmark: exit 0'
[[ "$got" == *"PUSH_SKIP names KeptTests, which is not a Benchmark file"* ]] || fail "a PUSH_SKIP name with no Benchmark: no reason: $got"

# The stamp: a passing check with BASE appends it, a red check or no BASE does not.
# A stub script gives the targets stub-ok or stub-red of the copied Makefile.
stamp_repo() {
  make_repo
  printf '#!/bin/bash\nprintf "classes: docs\\ntargets: %s\\nrisk: no\\n"\n' "$1" > "$tmp/r/scripts/check-changed.sh"
  printf '\nstub-ok:\n\t@true\nstub-red:\n\t@false\n' >> "$tmp/r/Makefile"
  g commit -q -am stub
}
stamp_read() { (cd "$tmp/r" && scripts/check-stamp.sh read main); }
stamp_repo stub-ok
make_case 'make check-changed with BASE' '' BASE=main
[[ "$(stamp_read)" == "$(g rev-parse HEAD) stub-ok" ]] || fail "make check-changed with BASE: stamp [$(stamp_read)]: $output"
stamp_repo stub-ok
make_case 'make check-changed with no BASE' ''
[[ "$(stamp_read)" == 'no stamp' ]] || fail "make check-changed with no BASE: stamp [$(stamp_read)]"
stamp_repo stub-red
make_case 'make check-changed with BASE and a red target' 'Error' BASE=main
[[ "$(stamp_read)" == 'no stamp' ]] || fail "a red target: stamp [$(stamp_read)]"
# A script output with no targets line fails, so an empty list never passes.
make_repo
printf '#!/bin/bash\necho "classes: none"\n' > "$tmp/r/scripts/check-changed.sh"
g commit -q -am stub
make_case 'make check-changed with no targets line' 'no targets line'

# The rerun of run-checks.sh through the recipe. A fake swift fails its first call with a failed
# test line, so the real test recipe is red; a fake test-filter.sh passes or fails by FAKE_FILTER.
# A red test that passes on a rerun writes the stamp; a red rerun writes none.
cat > "$tmp/bin/swift" <<EOF
#!/bin/bash
echo "swift \$*" >> "$tmp/swift.log"
n=\$((\$(cat "$tmp/swift.n" 2>/dev/null || echo 0) + 1))
echo "\$n" > "$tmp/swift.n"
[[ \$n -eq 1 ]] || exit 0
echo "✘ Test aFlake() failed after 1.0 seconds with 1 issue."
exit 1
EOF
rerun_repo() {
  stamp_repo test
  printf '#!/bin/bash\nif [[ "$FAKE_FILTER" == pass ]]; then echo "✔ Test aFlake() passed after 1.0 seconds."; exit 0; fi\necho "✘ Test aFlake() failed after 1.0 seconds with 1 issue."\nexit 1\n' > "$tmp/r/scripts/test-filter.sh"
  g commit -q -am fake-filter
  rm -f "$tmp/swift.n"
  : > "$tmp/swift.log"
}
rerun_repo
FAKE_FILTER=pass PATH="$tmp/bin:$PATH" make_case 'a red test that passes on a rerun' '' BASE=main
[[ "$(stamp_read)" == "$(g rev-parse HEAD) test" ]] || fail "a red test that passes on a rerun: stamp [$(stamp_read)]: $output"
[[ "$output" == *"run-checks: flake: aFlake passed on rerun 1 of 3"* ]] || fail "a red test that passes on a rerun: no flake line: $output"
rerun_repo
FAKE_FILTER=red PATH="$tmp/bin:$PATH" make_case 'a red rerun' 'red after 3 reruns' BASE=main
[[ "$(stamp_read)" == 'no stamp' ]] || fail "a red rerun: stamp [$(stamp_read)]"
# The test recipe runs the CLI process also when process 1 fails, and exits nonzero.
rerun_repo
PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" test > /dev/null 2>&1 && fail 'make test with a red process 1 exits 0'
[[ "$(sed -n 2p "$tmp/swift.log")" == 'swift test --filter DirigibleCLITests' ]] || fail "make test with a red process 1: calls [$(cat "$tmp/swift.log")]"

[[ $failures -eq 0 ]] && echo "check-changed tests: all passed"
exit $((failures > 0))
