#!/bin/bash
# Check that run-checks.sh runs make -k on its arguments, and reruns only the failed Swift tests
# of a red test or test-slow-push target. The fake make prints the lines of GNU Make 3.81
# (probe-make-k of run 2026-10-08-workflow-speed-3): the Error and not-remade lines on stderr, a
# backtick before the target name, and exit 2. Cases: a pass on rerun 2 (the flake line and one
# dirigible-flakes line), red on 3 reruns, parameterized names, a level-0 make prefix, each
# refusal with no rerun (also a crashed shard of test-shards.sh), a lock wait that ends at its limit (exit 75, and no 75 for a red hook test that quotes the limit line), CHECK_RISK=yes (1 rerun), the fast and slow split with the slow env, a
# later try with only the names that did not pass again, a real make on a stub Makefile, the
# static gates first (a red gate stops the check before test, also for the goals static test-filter; a gate runs once; a nested make
# still runs a gate), --flakes (the read route of the flakes file), the partial stamp line, the
# RERUN word (its two modes, no make call, one flake line for each name), the push check marker
# that only a run with BASE gives make, the secret scan that only a run with BASE starts, and the
# wiki pages of a failed test (a line wiki: <test>: <page> on the flake path and the red path, no
# line for a wiki with no page or a page of .obsidian, one warning with no wiki). Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKE MAKEFLAGS MFLAGS MAKELEVEL CHECK_RISK DIRIGIBLE_SLOW_TESTS BASE DIRIGIBLE_PUSH_CHECK DIRIGIBLE_WIKI SINCE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A repo with a copy of run-checks.sh, a fake check-changed.sh that logs the load wait, and a
# fake test-filter.sh. The fake test-filter.sh logs its arguments and DIRIGIBLE_SLOW_TESTS. Its
# call number n counts in $tmp/tries; while n is under FAKE_PASS_AT, it prints a failed line for
# each name and exits 1 (FAKE_AGAIN limits the failed names to that one name). Each other name
# gets a pass line, except FAKE_SILENT, which gets no line (a test that did not run). While red,
# FAKE_BOTH also gets a pass line beside its failed line (the same name in a second suite).
# FAKE_SKIP gets a skip line and no pass line when DIRIGIBLE_SLOW_TESTS is not 1 (a slow test).
w="$tmp/w"
mkdir -p "$w/scripts" "$tmp/bin"
git init -q "$w"
git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
cp "$repo/scripts/run-checks.sh" "$w/scripts/run-checks.sh"
printf '#!/bin/bash\necho "check-changed $*" >> "$FAKE_LOG"\n' > "$w/scripts/check-changed.sh"
printf '#!/bin/bash\necho "check-commits $*" >> "$FAKE_LOG"\nexit "${FAKE_COMMITS_CODE:-0}"\n' > "$w/scripts/check-commits.sh"
cat > "$w/scripts/test-filter.sh" <<'EOF'
#!/bin/bash
echo "test-filter slow=${DIRIGIBLE_SLOW_TESTS:-} $*" >> "$FAKE_LOG"
n=$(($(cat "$FAKE_TRIES") + 1))
echo "$n" > "$FAKE_TRIES"
red=0
((n < FAKE_PASS_AT)) && red=1
[[ -z "${FAKE_QUOTE:-}" ]] || echo "with-lock: still waiting after 120 s (quoted by a red test)" >&2
for a in "$@"; do
  [[ $a == --* || $a == "${FAKE_SILENT:-}" ]] && continue
  if [[ -n "${FAKE_LOCK75:-}" ]]; then
    echo "with-lock: still waiting after 120 s (WITH_LOCK_MAX_WAIT); run the same command again" >&2
    exit 75
  fi
  if [[ $a == "${FAKE_SKIP:-}" && "${DIRIGIBLE_SLOW_TESTS:-}" != 1 ]]; then echo "➜ Test $a() skipped"; continue; fi
  if ((red)) && [[ -z "${FAKE_AGAIN:-}" || $a == "$FAKE_AGAIN" ]]; then
    echo "✘ Test $a() failed after 1.0 seconds with 1 issue."
    [[ $a != "${FAKE_BOTH:-}" ]] || echo "✔ Test $a() passed after 1.0 seconds."
  else
    echo "✔ Test $a() passed after 1.0 seconds."
  fi
done
exit $red
EOF
chmod +x "$w/scripts/"*.sh
# The fake make logs its arguments. For the goal static (the pre-pass of the static gates) it
# exits 0. Else it prints the lines of $tmp/lines in order: a line that starts with 2: goes to
# stderr, else to stdout. It exits with $tmp/code. The stub Makefile gives the static gates.
printf 'STATIC_GATES := lint check-sizes\n' > "$w/Makefile"
cat > "$tmp/bin/make" <<'EOF'
#!/bin/bash
echo "make $*" >> "$FAKE_LOG"
[[ " $* " == *" static "* ]] && exit 0
echo "push-check=${DIRIGIBLE_PUSH_CHECK:-unset}" >> "$FAKE_LOG.env"
for f in "$(git rev-parse --path-format=absolute --git-dir)"/dirigible-check-running/*; do
  p="${f##*/}"
  [[ -e $f ]] && kill -0 "$p" 2>/dev/null && [[ "$(cat "$f")" == "$(ps -o lstart= -p "$p")" ]] &&
    echo "live mark $p" >> "$FAKE_LOG.marks"
done
while IFS= read -r l; do
  case "$l" in 2:*) echo "${l#2:}" >&2 ;; *) echo "$l" ;; esac
done < "$FAKE_LINES"
exit "$(cat "$FAKE_CODE")"
EOF
chmod +x "$tmp/bin/make"
head="$(git -C "$w" rev-parse HEAD)"
flakes="$w/.git/dirigible-flakes"
red_test=$'✘ Test aFlake() failed after 1.0 seconds with 1 issue.\n2:make[1]: *** [test] Error 1\n2:make[1]: Target `check\' not remade because of errors.'

# run <pass at> <make code> <make lines> [args]: runs run-checks.sh in the repo with the fakes;
# sets code and out. The calls are in $tmp/log.
run() {
  local pass="$1"
  printf '%s\n' "$3" > "$tmp/lines"
  echo "$2" > "$tmp/code"
  echo 0 > "$tmp/tries"
  : > "$tmp/log"
  rm -f "$flakes"
  shift 3
  out="$(cd "$w" && PATH="$tmp/bin:$PATH" FAKE_LOG="$tmp/log" FAKE_LINES="$tmp/lines" FAKE_CODE="$tmp/code" \
    FAKE_TRIES="$tmp/tries" FAKE_PASS_AT="$pass" scripts/run-checks.sh "${@:-check}" 2>&1)"
  code=$?
}
filters() { grep '^test-filter ' "$tmp/log"; }

# A pass with no rerun.
run 1 0 'ok'
[[ $code -eq 0 ]] || fail "a pass: exit $code: $out"
# The load wait comes after the static gates and before the main make.
[[ "$(cat "$tmp/log")" == $'make -k static\ncheck-changed --wait-load check\nmake -k -o lint -o check-sizes check' ]] || fail "a pass: calls [$(cat "$tmp/log")]"

# A lock wait that ends at its limit (exit 75 of with-lock.sh) is no red test: run-checks.sh ends
# in exit 75, with no rerun, whether the wait is in the main make or in a rerun.
lock_line=$'2:with-lock: still waiting after 120 s (WITH_LOCK_MAX_WAIT); run the same command again\n2:make[1]: *** [test] Error 75\n2:make[1]: Target `check\' not remade because of errors.'
run 1 2 "$lock_line"
[[ $code -eq 75 && -z "$(filters)" ]] || fail "a lock wait in the main make: exit $code (want 75, no rerun): $out"
FAKE_LOCK75=1 run 2 2 "$red_test"
[[ $code -eq 75 && "$(filters | wc -l | tr -d ' ')" == 1 ]] || fail "a lock wait in a rerun: exit $code (want 75, one rerun call): $out"
unset FAKE_LOCK75
# The text of the limit line inside the output of a red hook test is no lock wait: the 75 comes from
# the make error line of a target, and only when every make error is a 75, or from the exit status
# of a rerun. With BASE the wait limit is 0, so a push check never ends in 75.
quoted=$'with-lock: still waiting after 120 s (WITH_LOCK_MAX_WAIT); run the same command again'
run 1 2 "$quoted"$'\n2:make[1]: *** [test-hooks] Error 1'
[[ $code -eq 1 && "$out" == *'no rerun: no red test or test-slow-push target'* ]] ||
  fail "a red test-hooks that quotes the limit line: exit $code (want 1, no 75): $out"
run 1 2 $'FAIL: a lock case\nmake[1]: *** [test] Error 75\n'"$quoted"$'\n2:make[1]: *** [test-hooks] Error 1'
[[ $code -eq 1 && "$out" == *'no rerun: a target other than test and test-slow-push failed'* ]] ||
  fail "a red test-hooks that quotes a make 75 line: exit $code (want 1, no 75): $out"
BASE=HEAD run 1 2 "$lock_line"
[[ $code -eq 1 && "$out" == *'no rerun: a red target with no failed test line'* ]] ||
  fail "a push check with a lock line: exit $code (want 1, no 75): $out"
FAKE_QUOTE=1 run 9 2 "$red_test"
[[ $code -eq 1 && "$out" == *'run-checks: red after 3 reruns: aFlake'* ]] ||
  fail "a red rerun that quotes the limit line: exit $code (want 1, red after 3 reruns): $out"
unset FAKE_QUOTE

# A test failure that passes on rerun 2: the load wait before each rerun, a flake line, and one
# dirigible-flakes line with HEAD and the load.
run 2 2 "$red_test" check FILTER=
[[ $code -eq 0 ]] || fail "a pass on rerun 2: exit $code: $out"
want="make -k static FILTER=
check-changed --wait-load check
make -k -o lint -o check-sizes check FILTER=
check-changed --wait-load test
test-filter slow= --exact aFlake
check-changed --wait-load test
test-filter slow= --exact aFlake"
[[ "$(cat "$tmp/log")" == "$want" ]] || fail "a pass on rerun 2: calls [$(cat "$tmp/log")]"
grep -qx 'run-checks: flake: aFlake passed on rerun 2 of 3' <<<"$out" || fail "a pass on rerun 2: no flake line: $out"
grep -qxE "$head aFlake load [0-9]+(\.[0-9]+)?" "$flakes" || fail "a pass on rerun 2: flakes [$(cat "$flakes" 2>/dev/null)]"
[[ "$(wc -l < "$flakes" | tr -d ' ')" == 1 ]] || fail "a pass on rerun 2: $(wc -l < "$flakes") flakes lines"

# Red on 3 reruns: exit 1 and no flakes line.
run 9 2 "$red_test"
[[ $code -eq 1 ]] || fail "red on 3 reruns: exit $code"
[[ "$(filters | wc -l | tr -d ' ')" == 3 ]] || fail "red on 3 reruns: $(filters | wc -l) reruns"
grep -q 'run-checks: red after 3 reruns: aFlake' <<<"$out" || fail "red on 3 reruns: no reason: $out"
[[ ! -e "$flakes" ]] || fail "red on 3 reruns: flakes [$(cat "$flakes")]"

# A later try reruns only the names that did not pass again.
FAKE_AGAIN=bTest run 2 2 $'✘ Test aTest() failed after 1.0 seconds with 1 issue.\n✘ Test bTest() failed after 1.0 seconds with 1 issue.\n2:make[1]: *** [test] Error 1'
[[ "$(filters)" == $'test-filter slow= --exact aTest bTest\ntest-filter slow= --exact bTest' ]] || fail "a later try: reruns [$(filters)]"
grep -qx 'run-checks: flake: aTest bTest passed on rerun 2 of 3' <<<"$out" || fail "a later try: no flake line: $out"

# A name with no pass line in a rerun (its process did not run) stays in the rerun list, also
# when the rerun exits 0.
FAKE_SILENT=bTest run 1 2 $'✘ Test aTest() failed after 1.0 seconds with 1 issue.\n✘ Test bTest() failed after 1.0 seconds with 1 issue.\n2:make[1]: *** [test] Error 1'
[[ $code -eq 1 ]] || fail "a name with no pass line: exit $code: $out"
[[ "$(filters)" == $'test-filter slow= --exact aTest bTest\ntest-filter slow= --exact bTest\ntest-filter slow= --exact bTest' ]] || fail "a name with no pass line: reruns [$(filters)]"
grep -q 'run-checks: red after 3 reruns: bTest' <<<"$out" || fail "a name with no pass line: no reason: $out"
[[ ! -e "$flakes" ]] || fail "a name with no pass line: flakes [$(cat "$flakes")]"

# A name with a failed line and a pass line in one rerun (two suites have the name) stays in the
# rerun list, so the next try reruns it.
FAKE_BOTH=aFlake run 2 2 "$red_test"
[[ $code -eq 0 ]] || fail "a name in two suites: exit $code: $out"
[[ "$(filters | wc -l | tr -d ' ')" == 2 ]] || fail "a name in two suites: reruns [$(filters)]"
grep -qx 'run-checks: flake: aFlake passed on rerun 2 of 3' <<<"$out" || fail "a name in two suites: no flake line: $out"

# Parameterized names, and a level-0 make prefix (the delta path of land.sh).
run 1 2 $'✘ Test f(x:) with 2 test cases failed after 1.0 seconds with 1 issue.\n✘ Test g(a:b:) failed after 1.0 seconds with 1 issue.\n2:make: *** [test] Error 1'
[[ $code -eq 0 && "$(filters)" == 'test-filter slow= --exact f g' ]] || fail "parameterized names: exit $code, reruns [$(filters)]: $out"

# The fast and slow split: names before the [test] Error line rerun with no slow env; names
# after it and before the [test-slow-push] Error line rerun with the slow env, one at a time.
DIRIGIBLE_SLOW_TESTS=1 run 1 2 $'✘ Test aFast() failed after 1.0 seconds with 1 issue.\n2:make[1]: *** [test] Error 1\n2:make[1]: Target `check\' not remade because of errors.\n✘ Test aSlow() failed after 9.0 seconds with 1 issue.\n2:make[1]: *** [test-slow-push] Error 1' check test-slow-push
[[ $code -eq 0 ]] || fail "fast and slow: exit $code: $out"
[[ "$(filters)" == $'test-filter slow= --exact aFast\ntest-filter slow=1 --exact --no-parallel aSlow' ]] || fail "fast and slow: reruns [$(filters)]"
[[ "$(cut -d' ' -f2 "$flakes" | paste -sd' ' -)" == 'aFast aSlow' ]] || fail "fast and slow: flakes [$(cat "$flakes")]"
run 1 2 $'✘ Test aSlow() failed after 9.0 seconds with 1 issue.\n2:make[1]: *** [test-slow-push] Error 1' check test-slow-push
[[ $code -eq 0 && "$(filters)" == 'test-filter slow=1 --exact --no-parallel aSlow' ]] || fail "only slow: exit $code, reruns [$(filters)]"

# CHECK_RISK=yes: 1 rerun at most.
CHECK_RISK=yes run 3 2 "$red_test"
[[ $code -eq 1 && "$(filters | wc -l | tr -d ' ')" == 1 ]] || fail "risk, red: exit $code, reruns [$(filters)]"
[[ ! -e "$flakes" ]] || fail "risk, red: flakes [$(cat "$flakes")]"
CHECK_RISK=yes run 1 2 "$red_test"
[[ $code -eq 0 ]] || fail "risk, a pass: exit $code: $out"
grep -qx 'run-checks: flake: aFlake passed on rerun 1 of 1' <<<"$out" || fail "risk, a pass: no flake line: $out"
[[ -s "$flakes" ]] || fail 'risk, a pass: no flakes line'

# no_rerun <name> <reason> <make lines>: exit 1 with the reason, no rerun, and no flakes line.
no_rerun() {
  run 1 2 "$3"
  [[ $code -eq 1 ]] || fail "$1: exit $code"
  grep -qF "run-checks: no rerun: $2" <<<"$out" || fail "$1: no reason '$2': $out"
  [[ -z "$(filters)" ]] || fail "$1: reruns [$(filters)]"
  [[ ! -e "$flakes" ]] || fail "$1: flakes [$(cat "$flakes")]"
}
no_rerun 'a red lint' 'no red test or test-slow-push target' $'2:make[1]: *** [lint] Error 1'
no_rerun 'a red test-app' 'a target other than test and test-slow-push failed' "$red_test"$'\n2:make[1]: *** [test-app] Error 1'
no_rerun 'a target other than check not remade' 'a target other than check is not remade' "$red_test"$'\n2:make[1]: Target `test-dmg\' not remade because of errors.'
no_rerun 'a crash' 'a test process crashed' "error: Exited with unexpected signal code 11"$'\n'"$red_test"
no_rerun 'an issue of no test' 'an issue of no test' "✘ Test «unknown» recorded an issue at A.swift:1:1: Issue recorded"$'\n'"$red_test"
# A failed test and then an early end with no report: a rerun of the failed test would hide the
# tests that never ran.
no_rerun 'a test process with no report' 'a test process ended before its report' "swift-test: the test process ended before its report (swift test --skip X)"$'\n'"$red_test"
# A shard of test-shards.sh that crashed (exit 132, no report) beside a shard with a failed test.
no_rerun 'a shard that crashed' 'a test process ended before its report' "✘ Test aFlake() failed after 1.0 seconds with 1 issue."$'\n'"test-shards: shard 2: the test process ended before its report (no report line, exit 132)"$'\n2:make[1]: *** [test] Error 1'
no_rerun 'a red test with no test line' 'a red target with no failed test line' $'2:make[1]: *** [test] Error 1'
no_rerun 'a failed test line after the last Error line' 'a failed test line of no red target' "$red_test"$'\n✘ Test late() failed after 1.0 seconds with 1 issue.'

# A real make on a stub Makefile: the real stderr bytes, the backtick, and exit 2 reach the parser.
printf 'check: test\ntest:\n\t@echo "✘ Test aFlake() failed after 1.0 seconds with 1 issue."; exit 1\n' > "$w/Makefile"
echo 0 > "$tmp/tries"
: > "$tmp/log"
rm -f "$flakes"
out="$(cd "$w" && FAKE_LOG="$tmp/log" FAKE_TRIES="$tmp/tries" FAKE_PASS_AT=1 scripts/run-checks.sh check 2>&1)"
code=$?
[[ $code -eq 0 ]] || fail "a real make: exit $code: $out"
grep -qx 'run-checks: flake: aFlake passed on rerun 1 of 3' <<<"$out" || fail "a real make: no flake line: $out"

# The static gates first, with a real make on a stub Makefile. A red gate stops the check before
# the test recipe, with the reason. With green gates, each gate recipe runs once and test runs. A
# goal with no check, check-fast, or static gets no pre-pass. GNU make does not pass -o to a nested make, so
# a nested make of a gate still runs it.
cat > "$w/Makefile" <<'EOF'
STATIC_GATES := lint check-sizes
static: $(STATIC_GATES)
check: $(STATIC_GATES) test
test-filter:
	@echo test-filter >> "$$COUNT"
check-fast: $(STATIC_GATES)
lint:
	@echo lint >> "$$COUNT"
check-sizes:
	@echo check-sizes >> "$$COUNT"; exit $${SIZES_CODE:-0}
test:
	@echo test >> "$$COUNT"; if [ -n "$$NESTED" ]; then $(MAKE) -s lint; fi
EOF
static_run() {
  : > "$tmp/count"
  : > "$tmp/log"
  out="$(cd "$w" && COUNT="$tmp/count" FAKE_LOG="$tmp/log" "$@" 2>&1)"
  code=$?
}
recipes() { paste -sd' ' - < "$tmp/count"; }
static_run env SIZES_CODE=1 scripts/run-checks.sh check
[[ $code -eq 1 ]] || fail "a red static gate: exit $code: $out"
grep -qx 'run-checks: a static gate is red' <<<"$out" || fail "a red static gate: no reason: $out"
[[ "$(recipes)" == 'lint check-sizes' ]] || fail "a red static gate: recipes [$(recipes)]"
[[ ! -s "$tmp/log" ]] || fail "a red static gate waited for the load: $(cat "$tmp/log")"
static_run scripts/run-checks.sh check
[[ $code -eq 0 && "$(recipes)" == 'lint check-sizes test' ]] || fail "green static gates: exit $code, recipes [$(recipes)]: $out"
static_run env SIZES_CODE=1 scripts/run-checks.sh check-fast
[[ $code -eq 1 ]] && grep -qx 'run-checks: a static gate is red' <<<"$out" || fail "a red static gate of check-fast: exit $code: $out"
static_run env NESTED=1 scripts/run-checks.sh check
[[ $code -eq 0 && "$(recipes)" == 'lint check-sizes test lint' ]] || fail "a nested make of a gate: exit $code, recipes [$(recipes)]: $out"
static_run env SIZES_CODE=1 scripts/run-checks.sh static test-filter
[[ $code -eq 1 ]] && grep -qx 'run-checks: a static gate is red' <<<"$out" || fail "a red static gate of static test-filter: exit $code: $out"
[[ "$(recipes)" == 'lint check-sizes' && ! -s "$tmp/log" ]] || fail "a red static gate of static test-filter: recipes [$(recipes)], calls [$(cat "$tmp/log")]"
static_run scripts/run-checks.sh static test-filter
[[ $code -eq 0 && "$(recipes)" == 'lint check-sizes test-filter' ]] || fail "green gates of static test-filter: exit $code, recipes [$(recipes)]: $out"
static_run env SIZES_CODE=1 scripts/run-checks.sh test-filter
[[ $code -eq 0 && "$(recipes)" == 'test-filter' ]] || fail "test-filter alone has a pre-pass: exit $code, recipes [$(recipes)]: $out"
static_run env SIZES_CODE=1 scripts/run-checks.sh test
[[ $code -eq 0 && "$(recipes)" == 'test' ]] || fail "a goal with no gate: exit $code, recipes [$(recipes)]: $out"
printf 'STATIC_GATES := lint check-sizes\n' > "$w/Makefile"

# --flakes prints the lines of the flakes file and runs no make; with no file, it prints nothing.
printf 'abc aFlake load 1.0\ndef bFlake load 2.0\n' > "$flakes"
: > "$tmp/log"
out="$(cd "$w" && MAKE="$tmp/no-make" FAKE_LOG="$tmp/log" scripts/run-checks.sh --flakes 2>&1)"
code=$?
[[ $code -eq 0 && "$out" == $'abc aFlake load 1.0\ndef bFlake load 2.0' ]] || fail "--flakes with two lines: exit $code: [$out]"
rm -f "$flakes"
out="$(cd "$w" && MAKE="$tmp/no-make" FAKE_LOG="$tmp/log" scripts/run-checks.sh --flakes 2>&1)"
code=$?
[[ $code -eq 0 && -z "$out" ]] || fail "--flakes with no file: exit $code: [$out]"
[[ ! -s "$tmp/log" ]] || fail "--flakes ran a check: $(cat "$tmp/log")"

# The push check marker: with BASE, make runs with DIRIGIBLE_PUSH_CHECK=1 (test-shards.sh then runs
# the full suite); with no BASE, the marker stays unset, so a bare run-checks.sh call is refused.
: > "$tmp/log.env"
BASE=origin/main run 1 0 'ok' check
[[ "$(cat "$tmp/log.env")" == 'push-check=1' ]] || fail "a run with BASE: marker [$(cat "$tmp/log.env")]"
: > "$tmp/log.env"
run 1 0 'ok' check
[[ "$(cat "$tmp/log.env")" == 'push-check=unset' ]] || fail "a run with no BASE: marker [$(cat "$tmp/log.env")]"

# The secret scan: with BASE, check-commits.sh --secrets <base> runs first, before the static gates
# and make; with no BASE it does not run; a red scan ends the run with its exit code and no make call.
BASE=origin/main run 1 0 'ok' check
[[ "$(head -n 1 "$tmp/log")" == 'check-commits --secrets origin/main' && "$(grep -c '^check-commits' "$tmp/log")" == 1 ]] ||
  fail "a run with BASE: no scan first: [$(cat "$tmp/log")]"
run 1 0 'ok' check
! grep -q '^check-commits' "$tmp/log" || fail "a run with no BASE scanned: [$(cat "$tmp/log")]"
FAKE_COMMITS_CODE=3 BASE=origin/main run 1 0 'ok' check
[[ $code -eq 3 && "$(cat "$tmp/log")" == 'check-commits --secrets origin/main' ]] || fail "a red scan: exit $code, calls [$(cat "$tmp/log")]"

# A stamped run (BASE set by make check-changed BASE=<ref> or by the land.sh delta) marks the tree
# while make runs: the pid of run-checks.sh and its start time. The mark is gone after a pass and
# after a fail. A run with no BASE does not mark the tree.
marks="$w/.git/dirigible-check-running"
: > "$tmp/log.marks"
BASE=origin/main run 1 0 'ok' check
grep -q '^live mark [0-9]' "$tmp/log.marks" || fail "a stamped run: no live mark while make ran"
[[ -z "$(ls "$marks" 2>/dev/null)" ]] || fail "a stamped run: the mark stays after a pass: $(ls "$marks")"
BASE=origin/main run 1 2 '2:make: *** [check] Error 2' check
[[ -z "$(ls "$marks" 2>/dev/null)" ]] || fail "a stamped run: the mark stays after a fail: $(ls "$marks")"
: > "$tmp/log.marks"
run 1 0 'ok' check
[[ ! -s "$tmp/log.marks" ]] || fail "a run with no BASE marked the tree"

# The partial stamp: with BASE, on a clean tree, a check whose only red targets after the reruns
# are test or test-slow-push appends '<HEAD> <base commit> failed fast:<names> slow:<names>' to the
# partial file of the git common dir. The fixture files are committed, so the tree is clean.
git -C "$w" add -A
git -C "$w" -c user.name=t -c user.email=t@t commit -q -m files
git -C "$w" tag base
head="$(git -C "$w" rev-parse HEAD)"
partial="$w/.git/dirigible-check-partial"
partial_run() { rm -f "$partial"; run "$@"; }
no_partial() { [[ ! -e "$partial" ]] || fail "$1: a partial line [$(cat "$partial")]"; }
BASE=base partial_run 9 2 "$red_test"
[[ $code -eq 1 ]] || fail "a test-only red check with BASE: exit $code: $out"
[[ "$(cat "$partial" 2>/dev/null)" == "$head $head failed fast:aFlake slow:" ]] ||
  fail "a test-only red check with BASE writes one partial line: [$(cat "$partial" 2>/dev/null)]"
BASE=base partial_run 9 2 $'✘ Test aFast() failed after 1.0 seconds with 1 issue.\n✘ Test bFast() failed after 1.0 seconds with 1 issue.\n2:make[1]: *** [test] Error 1\n✘ Test aSlow() failed after 9.0 seconds with 1 issue.\n2:make[1]: *** [test-slow-push] Error 1' check test-slow-push
[[ "$(cat "$partial" 2>/dev/null)" == "$head $head failed fast:aFast,bFast slow:aSlow" ]] ||
  fail "a red fast and a red slow name: [$(cat "$partial" 2>/dev/null)]"
BASE=base partial_run 1 0 'ok'
no_partial 'a green check'
BASE=base partial_run 1 2 $'2:make[1]: *** [check-docs] Error 1'
no_partial 'a red check-docs'
partial_run 9 2 "$red_test"
no_partial 'a red test with no BASE'
echo x > "$w/dirty.txt"
BASE=base partial_run 9 2 "$red_test"
no_partial 'a dirty tree'
rm "$w/dirty.txt"

# A RERUN=<P>:fast:<names>+slow:<names> word: run-checks.sh runs the other targets, then the fast
# names with no slow env and the slow names with DIRIGIBLE_SLOW_TESTS=1 and --no-parallel. The word
# never reaches make; with no other target, make does not run. Each name that passes gets one
# flake line, also a name that passed on the first try, and no name gets two lines in one check.
P=abc
run 1 0 'ok' "RERUN=$P:fast:aFast+slow:aSlow" FILTER=
[[ $code -eq 0 ]] || fail "a RERUN word alone: exit $code: $out"
[[ "$(cat "$tmp/log")" == $'check-changed --wait-load test\ntest-filter slow= --exact aFast\ntest-filter slow=1 --exact --no-parallel aSlow' ]] ||
  fail "a RERUN word alone: calls [$(cat "$tmp/log")]"
[[ "$(cut -d' ' -f1,2 "$flakes" 2>/dev/null | paste -sd' ' -)" == "$head aFast $head aSlow" ]] || fail "a RERUN pass: flakes [$(cat "$flakes" 2>/dev/null)]"
run 1 0 'ok' check-docs "RERUN=$P:fast:aFast+slow:" FILTER=
[[ $code -eq 0 ]] || fail "a RERUN word after check-docs: exit $code: $out"
[[ "$(cat "$tmp/log")" == $'check-changed --wait-load check-docs\nmake -k check-docs FILTER=\ncheck-changed --wait-load test\ntest-filter slow= --exact aFast' ]] ||
  fail "a RERUN word after check-docs: calls [$(cat "$tmp/log")]"
# A slow name passes only in the slow mode: a skip line is no pass line.
FAKE_SKIP=aSlow run 1 0 'ok' "RERUN=$P:fast:+slow:aSlow"
[[ $code -eq 0 ]] || fail "a slow name in the slow mode: exit $code: $out"
FAKE_SKIP=aSlow run 1 0 'ok' "RERUN=$P:fast:aSlow+slow:"
[[ $code -eq 1 ]] || fail "a skipped name passed: exit $code: $out"
# The ignore mode: check passes with the name, then the word runs it again: one flake line.
run 1 0 'ok' check "RERUN=$P:fast:aFlake+slow:"
[[ $code -eq 0 && "$(cut -d' ' -f2 "$flakes" 2>/dev/null)" == aFlake ]] || fail "ignore mode, a pass on the first try: exit $code, flakes [$(cat "$flakes" 2>/dev/null)]"
# A rerun of the check wrote the line of aFlake, so the word adds no second line.
run 2 2 "$red_test" check "RERUN=$P:fast:aFlake+slow:"
[[ $code -eq 0 && "$(wc -l < "$flakes" | tr -d ' ')" == 1 ]] || fail "one flake line for each name and check: exit $code, flakes [$(cat "$flakes" 2>/dev/null)]"
# A red RERUN writes a new partial line of HEAD; a red check keeps the names of the word too.
BASE=base partial_run 9 0 'ok' "RERUN=$P:fast:aFast+slow:"
[[ $code -eq 1 && "$(cat "$partial" 2>/dev/null)" == "$head $head failed fast:aFast slow:" ]] || fail "a red RERUN: exit $code, partial [$(cat "$partial" 2>/dev/null)]"
BASE=base partial_run 9 2 "$red_test" check "RERUN=$P:fast:aFast+slow:aSlow"
[[ "$(cat "$partial" 2>/dev/null)" == "$head $head failed fast:aFlake,aFast slow:aSlow" ]] || fail "a red check with a word: partial [$(cat "$partial" 2>/dev/null)]"

# The wiki pages of a failed test: the line wiki: <test>: <page> on the flake path and on the red path
# after the reruns. The fixture wiki is the folder that DIRIGIBLE_WIKI names, with pages in wiki/.
cp "$repo/scripts/wiki.py" "$w/scripts/wiki.py"
wk="$tmp/wk"
mkdir -p "$wk/wiki/items" "$wk/wiki/.obsidian"
printf 'The flake aFlake needs a triage.\n' > "$wk/wiki/items/0042.md"
printf 'Another page.\n' > "$wk/wiki/items/0043.md"
DIRIGIBLE_WIKI="$wk" run 2 2 "$red_test"
[[ $code -eq 0 ]] || fail "wiki, flake path: exit $code: $out"
[[ "$(grep '^wiki:' <<<"$out")" == 'wiki: aFlake: items/0042.md' ]] || fail "wiki, flake path: lines [$(grep '^wiki:' <<<"$out")]: $out"
DIRIGIBLE_WIKI="$wk" run 9 2 "$red_test"
[[ $code -eq 1 && "$(grep '^wiki:' <<<"$out")" == 'wiki: aFlake: items/0042.md' ]] || fail "wiki, red after reruns: exit $code, lines [$(grep '^wiki:' <<<"$out")]: $out"
# A page that holds a longer name (aFlakeMore) is no page of aFlake.
printf 'The test aFlakeMore is another case.\n' > "$wk/wiki/items/0044.md"
DIRIGIBLE_WIKI="$wk" run 2 2 "$red_test"
[[ "$(grep '^wiki:' <<<"$out")" == 'wiki: aFlake: items/0042.md' ]] || fail "wiki, a longer name: lines [$(grep '^wiki:' <<<"$out")]: $out"
# A check and a RERUN word that both name aFlake print its wiki line once.
DIRIGIBLE_WIKI="$wk" run 2 2 "$red_test" check "RERUN=$P:fast:aFlake+slow:"
[[ "$(grep -c '^wiki: aFlake:' <<<"$out")" == 1 ]] || fail "wiki, the same name in the check and the word: lines [$(grep '^wiki:' <<<"$out")]: $out"
# A wiki with no page for the test: no wiki line, no warning, and the flake pass keeps exit 0.
mkdir -p "$tmp/wk2/wiki/items"
printf 'No test name here.\n' > "$tmp/wk2/wiki/items/0001.md"
DIRIGIBLE_WIKI="$tmp/wk2" run 2 2 "$red_test"
[[ $code -eq 0 ]] && ! grep -q '^wiki:' <<<"$out" && ! grep -q 'no wiki' <<<"$out" || fail "wiki with no page: exit $code: $out"
# A page under wiki/.obsidian/ gives no line.
mkdir -p "$tmp/wk3/wiki/.obsidian"
printf 'aFlake\n' > "$tmp/wk3/wiki/.obsidian/workspace.json"
DIRIGIBLE_WIKI="$tmp/wk3" run 2 2 "$red_test"
[[ $code -eq 0 ]] && ! grep -q '^wiki:' <<<"$out" || fail "wiki page under .obsidian: exit $code: $out"
# No wiki (a folder that does not exist, or no scripts/wiki.py): one warning line, and the same exit status.
DIRIGIBLE_WIKI="$tmp/no-wiki" run 2 2 "$red_test"
[[ $code -eq 0 && "$(grep -c 'run-checks: no wiki' <<<"$out")" == 1 ]] && ! grep -q '^wiki:' <<<"$out" || fail "no wiki folder: exit $code: $out"
rm "$w/scripts/wiki.py"
DIRIGIBLE_WIKI="$wk" run 9 2 "$red_test"
[[ $code -eq 1 && "$(grep -c 'run-checks: no wiki' <<<"$out")" == 1 ]] && ! grep -q '^wiki:' <<<"$out" || fail "no wiki.py, red path: exit $code: $out"

[[ $failures -eq 0 ]] && echo "run-checks tests: all passed"
exit $((failures > 0))
