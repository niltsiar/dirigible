#!/bin/bash
# Check that run-checks.sh runs make -k on its arguments, and reruns only the failed Swift tests
# of a red test or test-slow-push target. The fake make prints the lines of GNU Make 3.81
# (probe-make-k of run 2026-10-08-workflow-speed-3): the Error and not-remade lines on stderr, a
# backtick before the target name, and exit 2. Cases: a pass on rerun 2 (the flake line and one
# dirigible-flakes line), red on 3 reruns, parameterized names, a level-0 make prefix, each
# refusal with no rerun, CHECK_RISK=yes (1 rerun), the fast and slow split with the slow env, a
# later try with only the names that did not pass again, and a real make on a stub Makefile.
# Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKEFLAGS MFLAGS MAKELEVEL CHECK_RISK DIRIGIBLE_SLOW_TESTS
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A repo with a copy of run-checks.sh, a fake check-changed.sh that logs the load wait, and a
# fake test-filter.sh. The fake test-filter.sh logs its arguments and DIRIGIBLE_SLOW_TESTS. Its
# call number n counts in $tmp/tries; while n is under FAKE_PASS_AT, it prints a failed line for
# each name and exits 1 (FAKE_AGAIN limits the failed names to that one name). Each other name
# gets a pass line, except FAKE_SILENT, which gets no line (a test that did not run). While red,
# FAKE_BOTH also gets a pass line beside its failed line (the same name in a second suite).
w="$tmp/w"
mkdir -p "$w/scripts" "$tmp/bin"
git init -q "$w"
git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
cp "$repo/scripts/run-checks.sh" "$w/scripts/run-checks.sh"
printf '#!/bin/bash\necho "check-changed $*" >> "$FAKE_LOG"\n' > "$w/scripts/check-changed.sh"
cat > "$w/scripts/test-filter.sh" <<'EOF'
#!/bin/bash
echo "test-filter slow=${DIRIGIBLE_SLOW_TESTS:-} $*" >> "$FAKE_LOG"
n=$(($(cat "$FAKE_TRIES") + 1))
echo "$n" > "$FAKE_TRIES"
red=0
((n < FAKE_PASS_AT)) && red=1
for a in "$@"; do
  [[ $a == --* || $a == "${FAKE_SILENT:-}" ]] && continue
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
# The fake make logs its arguments and prints the lines of $tmp/lines in order: a line that
# starts with 2: goes to stderr, else to stdout. It exits with $tmp/code.
cat > "$tmp/bin/make" <<'EOF'
#!/bin/bash
echo "make $*" >> "$FAKE_LOG"
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
[[ "$(cat "$tmp/log")" == 'make -k check' ]] || fail "a pass: calls [$(cat "$tmp/log")]"

# A test failure that passes on rerun 2: the load wait before each rerun, a flake line, and one
# dirigible-flakes line with HEAD and the load.
run 2 2 "$red_test" check FILTER=
[[ $code -eq 0 ]] || fail "a pass on rerun 2: exit $code: $out"
want="make -k check FILTER=
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
rm "$w/Makefile"

[[ $failures -eq 0 ]] && echo "run-checks tests: all passed"
exit $((failures > 0))
