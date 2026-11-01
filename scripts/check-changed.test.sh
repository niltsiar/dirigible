#!/bin/bash
# Check that check-changed.sh prints the right three lines for each kind of change, fails closed
# on a bad or empty base, still sees a moved floor file, that each risk floor path exists, and that each split
# file of a floor file is on the floor.
# Check that `make check-changed` of the real Makefile exits nonzero when the script does, and
# runs no target (not the default goal `setup`) for an empty target list. Check that FILTER
# gives test-filter in place of test (and check-fast test-filter test-app, or static test-filter test-app when
# no hook test is needed, in place of check), that
# a local git run with a Swift test target and no FILTER exits 1 with the reason, and that FILTER
# reaches the swift calls through make. Check that a
# passing make check-changed with BASE writes the stamp, and a red one does not. Check that the push
# adds test-slow-push only for risk, a slow test, a Makefile change, or no passed slow run today,
# and PUSH_RUN=<names> for a changed PUSH_SKIP file. Check that test-slow-push has no test of a
# PUSH_SKIP file outside PUSH_RUN, that a passing make test-slow or test-slow-push writes the
# date, and that check-slow-gates fails on a PUSH_SKIP name with no file or with no Benchmark.
# Check that the recipe waits for a load under the core count before Swift tests, stops the wait
# at CHECK_LOAD_WAIT, and reads no load for docs targets. Check the delta after a pass stamp, and
# the partial stamp: its selection, the RERUN word and its drops, the risk refusal, and the
# ignore mode. Check the word DIRIGIBLE_HOOKS_ALL=1 of a local check-fast with no HOOK_TESTS word (a tooling
# or build path that no hook test names), and the target static, in place of check-fast, when the paths need no hook test.
# Check the mode --overlap: the shared Sources/ and Tests/ files of the base, the other worktrees, and
# the open PRs (a fake gh), the notes for a failed or silent gh, and the usage exit. Check that
# .sourcekit-lsp/config.json (or the file that LSP_CONFIG names) sets backgroundIndexing to false.
# Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/scripts/check-changed.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A git or make value of an outer run must not reach the temporary repos of this test.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKEFLAGS MFLAGS MAKELEVEL BASE FILTER SINCE

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
# The word of a local check-fast with no HOOK_TESTS word: test-hooks.sh runs the whole list for it.
all_hooks=' DIRIGIBLE_HOOKS_ALL=1'

# The hook tests of Makefile HOOK_TESTS, and a second way to find the tests of plain script paths.
hook_list="$(awk '/^HOOK_TESTS *=/ { on = 1 } on { print; if (!/\\$/) exit }' "$repo/Makefile" | sed 's/^HOOK_TESTS *=//; s/\\$//' | tr -s ' \t' '\n' | grep .)"
# hw <path>...: " HOOK_TESTS=<tests>" for plain script paths, from the test files on disk (a second
# way to find the tests, for the cases whose paths the test file names itself); empty when a path
# has no test.
hw() {
  local p b t found all="" word=""
  for p in "$@"; do
    found="" b="${p##*/}"
    for t in $hook_list; do
      if [[ $t == "$p" || $t == "${p%.*}.test.sh" ]] || grep -qF -- "$b" "$repo/$t" 2> /dev/null; then found+=" $t"; fi
    done
    [[ -n $found ]] || return 0
    all+="$found"
  done
  for t in $hook_list; do [[ " $all " == *" $t "* ]] && word+=",$t"; done
  [[ -z $word ]] || echo " HOOK_TESTS=${word#,}"
}

expect 'docs only' "$(out docs check-docs no)" <<<'.claude/skills/tdd/SKILL.md'
expect 'a probe script' "$(out tooling "check-fast$(hw scripts/probe.sh)" no)" <<<'scripts/probe.sh'
expect 'a skill doc and a skill script' "$(out 'docs tooling' "check-fast$(hw .claude/skills/deliver/scripts/new-run.sh)" no)" \
  <<<$'.claude/skills/deliver/SKILL.md\n.claude/skills/deliver/scripts/new-run.sh'
expect 'Makefile local' "$(out bundle check no)" <<<'Makefile'
expect 'Makefile before the push' "$(out bundle 'check test-slow-push test-dmg' no)" --push <<<'Makefile'
expect 'Package.swift local' "$(out build check no)" <<<'Package.swift'
expect 'Package.swift before the push' "$(out build check no)" --push <<<'Package.swift'
# The sourcekit-lsp config changes no Swift build, so it is tooling and runs no Swift target.
got="$(cd "$e" && "$script" --paths <<<'.sourcekit-lsp/config.json')"
[[ "$(sed -n 1p <<<"$got")" == 'classes: tooling' && "$(sed -n 2p <<<"$got")" == 'targets: check-fast'* ]] ||
  fail "the sourcekit-lsp config: got [$got], want classes: tooling and a check-fast target"
# AGT-145: background indexing stays off, so a test run builds nothing outside the lock. LSP_CONFIG
# names another file for the check.
lsp_off() { python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("backgroundIndexing") is False else 1)' "$1" 2> /dev/null; }
lsp_off "${LSP_CONFIG:-$repo/.sourcekit-lsp/config.json}" || fail 'the sourcekit-lsp config does not set backgroundIndexing to false'
printf '{"backgroundIndexing": true}\n' > "$tmp/lsp-on.json"
lsp_off "$tmp/lsp-on.json" && fail 'the backgroundIndexing check passes a config with true'
lsp_off "$tmp/lsp-missing.json" && fail 'the backgroundIndexing check passes a missing config'
expect 'Tests only' "$(out tests test no)" <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'Tests only before the push' "$(out tests check no)" --push <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'app sources local' "$(out sources test no)" <<<'Sources/DirigibleApp/AppDelegate.swift'
expect 'app sources before the push' "$(out sources check no)" --push <<<'Sources/DirigibleApp/AppDelegate.swift'
expect 'capture sources' "$(out sources-risk 'check test-slow-push' yes)" --push \
  <<<'Sources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'capture sources local' "$(out sources-risk test yes)" <<<'Sources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'session writer' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/SessionWriter.swift'
expect 'session encoder' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/SessionXML.swift'
expect 'transcript store' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/TranscriptStore.swift'
expect 'unused files' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/UnusedFiles.swift'
expect 'backups' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/Backup.swift'
expect 'origin files in use' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/Session+Origin.swift'
expect 'unused files transcripts' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/UnusedFiles+Transcripts.swift'
expect 'package edit core' "$(out sources-risk test yes)" <<<'Sources/DirigibleMCP/PackageEditCore.swift'
expect 'prune work' "$(out sources-risk test yes)" <<<'Sources/DirigibleMCP/PruneWork.swift'
expect 'Makefile and capture sources' "$(out 'sources-risk bundle' 'check test-slow-push test-dmg' yes)" --push \
  <<<$'Makefile\nSources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'Support' "$(out bundle 'check test-dmg' no)" --push <<<'Support/Info.plist'
expect 'bundle script before the push' "$(out bundle 'check test-dmg' no)" --push <<<'scripts/bundle.sh'
expect 'bundle script' "$(out bundle check no)" <<<'scripts/bundle.sh'
expect 'app bundle test' "$(out bundle check no)" <<<'Tests/DirigibleTests/AppBundleTests.swift'
expect 'guide converter' "$(out bundle check no)" <<<'scripts/guide-html.swift'
expect 'unknown top-level file' "$(out build check no)" <<<'unknown.txt'
expect 'coding standards' "$(out docs check-docs no)" --push <<<'CODING_STANDARDS.md'
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
FILTER=ClipTests expect 'bundle with FILTER' "$(out bundle "check-fast test-filter test-app$(hw Makefile)" no)" <<<'Makefile'
FILTER=ClipTests expect 'build with FILTER' "$(out build "check-fast test-filter test-app$(hw Package.swift)" no)" <<<'Package.swift'
FILTER=ClipTests expect 'bundle and sources with FILTER' "$(out 'sources bundle' "check-fast test-filter test-app$(hw Makefile)" no)" \
  <<<$'Makefile\nSources/DirigibleApp/AppDelegate.swift'
# A FILTER check whose paths need no hook test runs the static gates only. The names are built from
# parts, so this file does not name them.
strings_file="Support/Resources/en.lproj/Localizable.str""ings" unnamed_build=".swift-ver""sion-x"
FILTER=ClipTests expect 'the paths of a sources-risk slice with FILTER' "$(out 'docs tests sources sources-risk bundle' 'static test-filter test-app' yes)" \
  <<<$'Sources/DirigibleCore/SessionWriter.swift\nSources/DirigibleApp/AppDelegate.swift\nTests/DirigibleCoreTests/SessionTests.swift\n'"$strings_file"$'\ndocs/guide.md\nREADME.md'
FILTER=ClipTests expect 'a bundle path that no hook test names, with FILTER' "$(out bundle 'static test-filter test-app' no)" <<<"$strings_file"
FILTER=ClipTests expect 'a build path that no hook test names, with FILTER' "$(out build "check-fast test-filter test-app$all_hooks" no)" <<<"$unnamed_build"
FILTER=ClipTests expect 'a build path that no hook test names, with a sources path' "$(out 'sources build' "check-fast test-filter test-app$all_hooks" no)" \
  <<<"$unnamed_build"$'\nSources/DirigibleApp/AppDelegate.swift'
FILTER=ClipTests expect 'a bundle path and a mapped Makefile, with FILTER' "$(out bundle "check-fast test-filter test-app$(hw Makefile)" no)" <<<"$strings_file"$'\nMakefile'
# The push targets do not change.
expect 'the paths of a sources-risk slice before the push' "$(out 'docs tests sources sources-risk bundle' 'check test-slow-push test-dmg' yes)" --push \
  <<<$'Sources/DirigibleCore/SessionWriter.swift\nSources/DirigibleApp/AppDelegate.swift\nTests/DirigibleCoreTests/SessionTests.swift\n'"$strings_file"$'\ndocs/guide.md\nREADME.md'
# With no FILTER, the stdin mode keeps the targets: the refusal is for the local git run.
expect 'bundle with no FILTER, stdin' "$(out bundle check no)" <<<'Makefile'
FILTER='ClipTests TrackTests' expect 'tooling and sources with FILTER' "$(out 'tooling sources' "check-fast test-filter$(hw scripts/probe.sh)" no)" \
  <<<$'scripts/probe.sh\nSources/DirigibleApp/AppDelegate.swift'
# FILTER before the push: exit nonzero with the reason, because the push runs the full targets.
got="$(FILTER=ClipTests "$script" --paths --push 2>&1 <<<'Tests/A.swift')" && fail 'FILTER with --push exits 0'
[[ "$got" == *"FILTER is for the tdd loop of a slice"* ]] || fail "FILTER with --push: no reason: $got"

# The HOOK_TESTS word. A local run with check-fast names the hook tests that the changed paths
# need, so make runs those and not the whole list: the entry itself, the <name>.test.sh of a
# <name>.sh or <name>.py, the guardrails test for a hook, settings, or .githooks path, and each
# entry whose text names the basename of a changed tooling path. A changed path of class tooling
# or build with no test gives the word DIRIGIBLE_HOOKS_ALL=1: test-hooks.sh refuses the whole
# list with no word. A path of class comments, or of class bundle with no test, needs none. The HOOK_TESTS word never comes before the push.
# word_of [--push]: the HOOK_TESTS word of the paths on stdin, or nothing.
word_of() { (cd "$e" && "$script" --paths "$@") | sed -n 's/^targets: .*HOOK_TESTS=\([^ ]*\).*/\1/p'; }
# has_test <path> <test>: the word for the path holds the test.
has_test() {
  local w
  w="$(word_of <<<"$1")"
  [[ ",$w," == *",$2,"* ]] || fail "$1: the word [$w] lacks $2"
}
# A path that the test file names whole would make this file a consumer of it, so two names are built from parts.
seen_sh=".claude/skills/reflect/scripts/se""en.sh"
unnamed="scripts/no-such""-script.sh"
expect 'a script with a test' "$(out tooling 'check-fast HOOK_TESTS=.claude/skills/reflect/scripts/seen.test.sh' no)" <<<"$seen_sh"
expect 'a script with a test, before the push' "$(out tooling check-fast no)" --push <<<"$seen_sh"
has_test scripts/run-checks.sh scripts/check-changed.test.sh
has_test .claude/hooks/agent-guard.sh .claude/hooks/git-guardrails.test.sh
has_test .claude/settings.json .claude/hooks/git-guardrails.test.sh
has_test .githooks/pre-commit .claude/hooks/git-guardrails.test.sh
has_test .githooks/pre-push scripts/land.test.sh
plan_test="scripts/check-pl""an.test.sh"
expect 'a hook test maps to itself' "$(out tooling "check-fast HOOK_TESTS=$plan_test" no)" <<<"$plan_test"
# Two paths give both tests in the order of the list, joined with commas, whatever the order of the paths.
hid_test="scripts/hi""d.test.sh" ax_test="scripts/a""x.test.sh"
expect 'two hook tests' "$(out tooling "check-fast HOOK_TESTS=$hid_test,$ax_test" no)" <<<"$ax_test"$'\n'"$hid_test"
# Old value of 'scripts/with-lock.sh': no word. New value: each test of the list that names it.
w="$(word_of <<<'scripts/with-lock.sh')"
want=""
for t in $hook_list; do grep -qF -- 'with-lock.sh' "$repo/$t" && want+=",$t"; done
[[ -n "$w" && "$w" == "${want#,}" && ",$w," == *",scripts/check-changed.test.sh,"* ]] || fail "scripts/with-lock.sh: the word [$w], want [${want#,}]"
# A path that no test names gives the switch word and exit 0 (a search with no match is no failure of the script).
expect 'a script that no test names' "$(out tooling "check-fast$all_hooks" no)" <<<"$unnamed"
expect 'a new script that no test names' "$(out tooling "check-fast$all_hooks" no)" <<<"scripts/new-f""oo.sh"
# One path with a test and one with no test: the full list runs, so the switch word and no HOOK_TESTS word.
expect 'a mapped path and an unnamed path' "$(out tooling "check-fast$all_hooks" no)" <<<"$seen_sh"$'\n'"$unnamed"
# Before the push the word never comes: the push check runs the full list with its own switch.
expect 'a script that no test names, before the push' "$(out tooling check-fast no)" --push <<<"$unnamed"
# A path set that maps to every hook test gives the switch word, not the whole list as one word, which
# test-hooks.sh would refuse.
expect 'every hook test as a path' "$(out tooling "check-fast$all_hooks" no)" <<<"$hook_list"
# A path with a test keeps its HOOK_TESTS word and gets no switch word.
[[ "$(cd "$e" && "$script" --paths <<<"$seen_sh")" != *DIRIGIBLE_HOOKS_ALL* ]] || fail 'a script with a test: the switch word'
# A path of class docs needs no test; a change of Swift sources adds the test target, not a hook test.
expect 'a mapped path and a docs path' "$(out 'docs tooling' 'check-fast HOOK_TESTS=.claude/skills/reflect/scripts/seen.test.sh' no)" <<<"$seen_sh"$'\ndocs/guide.md'

# --paths reads the paths from stdin only. A path argument exits 2 with the usage on stderr and
# nothing on stdout, so a caller that passes paths does not get a silent `risk: no`.
for args in 'scripts/a.sh' '--push scripts/a.sh'; do
  got="$(cd "$e" && "$script" --paths $args 2> "$tmp/paths.err" </dev/null)"
  code=$?
  [[ $code -eq 2 && -z "$got" ]] || fail "--paths $args: exit $code, stdout [$got]"
  grep -q 'usage:' "$tmp/paths.err" || fail "--paths $args: no usage line: $(cat "$tmp/paths.err")"
done

# Floor case: each risk floor path exists, so a rename cannot drop a file out of the floor.
floor="$("$script" --floor)" || fail "--floor exits $?"
[[ -n "$floor" ]] || fail '--floor prints no path'
for p in $floor; do
  [[ -e "$repo/$p" ]] || fail "floor path $p does not exist; change the floor in check-changed.sh"
done

# Floor split files: a file <floor stem>+*.swift of a floor file is on the floor, so a split cannot leave it.
# The list comes from git, not the work tree: make test-hooks checks out only the floor paths of Sources/.
for p in $floor; do
  [[ $p == */ ]] && continue
  stem="${p##*/}"
  stem="${stem%.swift}"
  while IFS= read -r rel; do
    [[ "${rel##*/}" == "$stem"+*.swift ]] || continue
    [[ "$(cd "$e" && "$script" --paths <<<"$rel")" == *'classes: sources-risk'* ]] \
      || fail "floor split files: $rel splits the floor file $p and is not on the floor; add it in check-changed.sh"
  done < <(git -C "$repo" ls-files -- Sources/)
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
got="$(run_in 2> "$tmp/refuse.err")"
code=$?
[[ $code -eq 1 ]] || fail "no base, a Swift test, no FILTER: expected exit 1, got $code"
[[ "$got" == "$(out 'tooling tests' "check-fast test$(hw scripts/b.sh)" no)" ]] || fail "no base: got [$got]"
for word in FILTER 'push check' 'make test' 'BASE=origin/main'; do
  grep -qF "$word" "$tmp/refuse.err" || fail "no base, no FILTER: no '$word' in the reason: $(cat "$tmp/refuse.err")"
done
got="$(FILTER=ClipTests run_in 2>&1)" || fail "no base with FILTER: exit $?"
[[ "$got" == "$(out 'tooling tests' "check-fast test-filter$(hw scripts/b.sh)" no)" ]] || fail "no base with FILTER: got [$got]"
# Sources and Support, no FILTER: the three lines, then exit 1 with the reason. A docs path exits 0.
for path in Sources/DirigibleApp/X.swift Support/Info.plist; do
  new_repo
  mkdir -p "$tmp/r/$(dirname "$path")"
  printf 'x\n' > "$tmp/r/$path"
  got="$(run_in 2> "$tmp/refuse.err")"
  code=$?
  [[ $code -eq 1 && "$got" == classes:*$'\n'targets:*$'\n'risk:* ]] || fail "$path, no FILTER: exit $code, got [$got]"
  grep -qF 'FILTER' "$tmp/refuse.err" || fail "$path, no FILTER: no reason: $(cat "$tmp/refuse.err")"
  got="$(FILTER=ClipTests run_in)" || fail "$path with FILTER: exit $?"
done
new_repo
printf 'a2\n' >> "$tmp/r/docs/a.md"
got="$(run_in)" || fail "a docs path, no FILTER: exit $?"
[[ "$got" == "$(out docs check-docs no)" ]] || fail "a docs path, no FILTER: got [$got]"
# FILTER on a clean tree: the named tests run (test-filter), with one stderr note. FILTER with a
# change that picks no test (a docs change): exit 1 with the reason. A FILTER run with only check-docs
# would pass with no test run. The mode --paths keeps exit 0.
new_repo
got="$(FILTER=ClipTests run_in 2> "$tmp/refuse.err")"
code=$?
[[ $code -eq 0 && "$got" == "$(out none test-filter no)" ]] || fail "a clean tree with FILTER: expected exit 0 and test-filter, got exit $code and [$got]"
grep -qF 'FILTER runs only the named tests' "$tmp/refuse.err" || fail "a clean tree with FILTER: no note: $(cat "$tmp/refuse.err")"
printf 'a3\n' >> "$tmp/r/docs/a.md"
got="$(FILTER=ClipTests run_in 2> "$tmp/refuse.err")"
code=$?
[[ $code -eq 1 && "$got" == "$(out docs check-docs no)" ]] || fail "a docs path with FILTER: exit $code, got [$got]"
grep -qF 'make test-filter FILTER=' "$tmp/refuse.err" || fail "a docs path with FILTER: no reason: $(cat "$tmp/refuse.err")"
got="$(run_in)" || fail "a docs path, no FILTER, after the FILTER cases: exit $?"

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

# The content of the change (the git modes only). content_case <name> <file> <old> <new> <want>
# [main]: commit <old> on main, then write <new> to the working tree. With main, commit <new> on a
# branch with a slow run today, and run against main.
# local_exit [base]: with no base, a want with the target test or check exits 1 (no FILTER).
local_exit() {
  [[ $# -eq 0 && " $(sed -n 's/^targets: //p' <<<"$want") " =~ \ (test|check)\  ]] && echo 1 || echo 0
}
content_case() {
  local name="$1" file="$2" old="$3" new="$4" want="$5"
  shift 5
  new_repo
  mkdir -p "$(dirname "$tmp/r/$file")"
  printf '%s' "$old" > "$tmp/r/$file"
  g add -A
  g commit -q -m old
  printf '%s' "$new" > "$tmp/r/$file"
  if [[ $# -gt 0 ]]; then
    g switch -q -c feat/c
    g commit -q -am new
    echo "$today" > "$tmp/r/.git/dirigible-slow-date"
  fi
  got="$(run_in "$@" 2>/dev/null)"
  code=$?
  [[ $code -eq $(local_exit "$@") ]] || { fail "$name: exit $code"; return; }
  [[ "$got" == "$want" ]] || fail "$name: got [$got], want [$want]"
}
sw=Sources/DirigibleCore/SessionWriter.swift app=Sources/DirigibleApp/A.swift
# A Swift change of only // lines and blank lines is class comments, also in a risk floor file.
content_case 'a comment in a floor file' $sw $'let a = 1\n' $'let a = 1\n// note\n' "$(out comments static no)"
content_case 'code in a floor file' $sw $'let a = 1\n' $'let a = 1\nlet y = 1\n' "$(out sources-risk test yes)"
content_case 'a comment and a blank line' $app $'let a = 1\n' $'let a = 1\n\n  // note\n' "$(out comments static no)"
content_case 'a comment and a code line' $app $'let a = 1\n' $'let a = 1\n// note\nlet x = 1\n' "$(out sources test no)"
content_case 'a doc-comment edit of a Sources Swift file prints no DIRIGIBLE_HOOKS_ALL and no hook test' Sources/DirigibleCore/Clip.swift $'/// Old.\nstruct Clip {}\n' $'/// New.\nstruct Clip {}\n' "$(out comments static no)"
[[ "$got" != *DIRIGIBLE_HOOKS_ALL* && "$got" != *HOOK_TESTS* ]] || fail "a doc-comment edit: a hook word in [$got]"
content_case 'a doc comment' $app $'/// Old.\nfunc f() {}\n' $'/// New.\nfunc f() {}\n' "$(out comments static no)"
content_case 'a doc comment and a name' $app $'/// Old.\nfunc f() {}\n' $'/// New.\nfunc g() {}\n' "$(out sources test no)"
# A code line with a comment, a // in a string, #if, and a block comment stay code.
content_case 'a code line with a comment' $app $'let x = 1 // a\n' $'let x = 2 // a\n' "$(out sources test no)"
content_case 'a // in a string' $app $'let u = "http://a"\n' $'let u = "http://b"\n' "$(out sources test no)"
content_case 'a // line in a multi-line string' $app $'let s = """\n// a\n"""\n' $'let s = """\n// b\n"""\n' "$(out sources test no)"
content_case '#if' $app $'let a = 1\n' $'#if DEBUG\nlet a = 1\n#endif\n' "$(out sources test no)"
content_case 'a block comment' $app $'let a = 1\n' $'let a = 1\n/* x */\n' "$(out sources test no)"
content_case 'a // line that ends a block comment' $app $'/*\n// a\n*/\n' $'/*\n// b */ let a = 1\n*/\n' "$(out sources test no)"
# Package.swift keeps its path class: its swift-tools-version comment is semantic.
content_case 'a Package.swift comment' Package.swift $'// swift-tools-version:6.0\n' $'// swift-tools-version:6.2\n' "$(out build check no)"
# A comment in a slow test or a PUSH_SKIP bench adds no test-slow-push before the push.
slow=$'guard ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1" else { return }\nfunc a() {}\n'
content_case 'a comment in a slow test' Tests/DirigibleCoreTests/LongTests.swift "$slow" "$slow// note"$'\n' "$(out comments check-fast no)" main
content_case 'code in a slow test' Tests/DirigibleCoreTests/LongTests.swift "$slow" "$slow"$'func b() {}\n' "$(out tests 'check test-slow-push' no)" main
content_case 'a comment in a PUSH_SKIP bench' Tests/DirigibleAudioTests/LoudnessBenchmark.swift "$slow" "$slow// note"$'\n' "$(out comments check-fast no)" main
# A new or deleted file keeps its path class: it has no old or no new side.
new_repo
mkdir -p "$tmp/r/Tests"
printf '// t\n' > "$tmp/r/Tests/T.swift"
got="$(run_in 2>/dev/null)" && fail "an untracked comment file: exit 0 with no FILTER"
[[ "$got" == "$(out tests test no)" ]] || fail "an untracked comment file: got [$got]"
rm "$tmp/r/Tests/T.swift"
printf '// only\n' > "$tmp/r/$sw"
g commit -q -am comment
g rm -q "$sw"
got="$(run_in 2>/dev/null)" && fail "a deleted comment file: exit 0 with no FILTER"
[[ "$got" == "$(out sources-risk test yes)" ]] || fail "a deleted comment file: got [$got]"
# A Makefile change of only column-0 # lines is class docs and adds no push target. A # line that
# make reads stays code: a recipe line, a $ reference, a \ continuation, or a define body.
mk=$'X = a \\\n  b\nall:\n\t@true\n'
content_case 'a Makefile comment before the push' Makefile "$mk" "# note"$'\n'"$mk" "$(out docs check-docs no)" main
content_case 'a Makefile recipe line before the push' Makefile "$mk" "$mk"$'\t@true\n' "$(out bundle 'check test-slow-push test-dmg' no)" main
content_case 'a Makefile comment' Makefile "$mk" "$mk"$'  # note\n' "$(out docs check-docs no)"
content_case 'a Makefile comment paragraph' Makefile "$mk" $'# a\n\n# b\n'"$mk" "$(out docs check-docs no)"
content_case 'a blank line after a continued line' Makefile "$mk" $'X = a \\\n\n  b\nall:\n\t@true\n' "$(out bundle check no)"
content_case 'a recipe # line' Makefile "$mk" "$mk"$'\t# c\n' "$(out bundle check no)"
content_case 'a # line with a $ reference' Makefile "$mk" '# $(X)'$'\n'"$mk" "$(out bundle check no)"
content_case 'a # line that continues' Makefile "$mk" $'# a \\\n'"$mk" "$(out bundle check no)"
content_case 'a # line after a continued line' Makefile "$mk" $'X = a \\\n# c\n  b\nall:\n\t@true\n' "$(out bundle check no)"
content_case 'a # line in a Makefile with define' Makefile $'define X\n# a\nendef\n' $'# note\ndefine X\n# a\nendef\n' "$(out bundle check no)"
# The branch shape of the user complaint: a doc, a comment in a floor file, and a Makefile comment.
content_case 'a doc and two comments' Makefile "$mk" "# note"$'\n'"$mk" "$(out docs check-docs no)" main
printf 'a2\n' >> "$tmp/r/docs/a.md"
printf '// note\n' >> "$tmp/r/$sw"
got="$(run_in main)" || fail "a doc and two comments: exit $?"
[[ "$got" == "$(out 'docs comments' check-fast no)" ]] || fail "a doc and two comments: got [$got]"
printf 'let y = 1\n' >> "$tmp/r/$sw"
got="$(run_in main)" || fail "a doc, a comment, and code in a floor file: exit $?"
[[ "$got" == "$(out 'docs sources-risk' 'check test-slow-push' yes)" ]] || fail "a doc, a comment, and code in a floor file: got [$got]"

# The delta after a pass stamp: the targets of the paths since the stamp commit S only, and the
# classes and risk of the whole base diff. stamp_case <path before S> <path after S|-> [stamp base]:
# on a branch with a slow run today, a commit of the first path, a stamp of it (base main, or the
# stamp base), then a commit of the second path. stamp_is <name> <classes> <targets> <risk>.
stamp_line() { echo "$1 $(g rev-parse "$2") check" >> "$tmp/r/.git/dirigible-check-stamp"; }
put() { mkdir -p "$(dirname "$tmp/r/$1")" && printf '%s\n' "$2" >> "$tmp/r/$1" && g add -A && g commit -q -m "$1"; }
stamp_case() {
  new_repo
  g switch -q -c feat/d
  echo "$today" > "$tmp/r/.git/dirigible-slow-date"
  put "$1" one
  stamped="$(g rev-parse HEAD)"
  stamp_line "$stamped" "${3:-main}"
  [[ "$2" == - ]] || put "$2" two
}
stamp_is() {
  local want
  want="$(printf 'stamp: delta %s\n%s' "$stamped" "$(out "$2" "$3" "$4")")"
  got="$(run_in main)" || { fail "$1: exit $?"; return; }
  [[ "$got" == "$want" ]] || fail "$1: got [$got], want [$want]"
}
stamp_case Tests/T.swift docs/b.md
stamp_is 'a docs-only change after a pass stamp gives check-docs' 'docs tests' check-docs no
stamp_case Sources/DirigibleAudio/A.swift docs/b.md
stamp_is 'a docs change after a stamp of a risk change keeps the risk' 'docs sources-risk' check-docs yes
stamp_case docs/b.md Tests/T.swift
stamp_is 'a Tests path after a stamp gives check' 'docs tests' check no
stamp_case docs/b.md Sources/DirigibleAudio/A.swift
stamp_is 'a risk path after a stamp gives the slow tests' 'docs sources-risk' 'check test-slow-push' yes
stamp_case Tests/T.swift -
stamp_is 'a stamp of HEAD with a clean tree' tests none no
printf 'x\n' >> "$tmp/r/docs/a.md"
stamp_is 'a stamp of HEAD and a changed doc in the working tree' 'docs tests' check-docs no
# The delta reads the content against S: a comment after a stamp of code in a floor file.
stamp_case $sw -
printf '// note\n' >> "$tmp/r/$sw"
g commit -q -am comment
stamp_is 'a comment after a stamp of floor code' sources-risk check-fast yes
# No delta: a stamp of another base, and a stamp of a commit that is not an ancestor of HEAD.
stamp_case Tests/T.swift docs/b.md HEAD
got="$(run_in main)" || fail "a stamp of another base: exit $?"
[[ "$got" == "$(out 'docs tests' check no)" ]] || fail "a stamp of another base: got [$got]"
stamp_case Tests/T.swift docs/b.md HEAD
g switch -q -c feat/other main
put docs/c.md other
stamp_line "$(g rev-parse HEAD)" main
g switch -q feat/d
got="$(run_in main)" || fail "a stamp that is not an ancestor: exit $?"
[[ "$got" == "$(out 'docs tests' check no)" ]] || fail "a stamp that is not an ancestor: got [$got]"
# A stamp of an older commit of main (main moved after the check) still gives the delta.
main_moves() { g switch -q main && g commit -q --allow-empty -m moved && g switch -q "$1"; }
stamp_case Tests/T.swift docs/b.md
main_moves feat/d
stamp_is 'a stamp of an older main base' 'docs tests' check-docs no

# The partial stamp: a check whose only red targets were tests appended '<P> <base commit> failed
# fast:<names> slow:<names>'. check-changed.sh <base> selects the newest line of this base whose P
# is HEAD or an ancestor and is newer than the newest pass stamp, prints `stamp: partial <P>`, the
# targets of the paths since P, and the word RERUN=<P>:fast:<names>+slow:<names>. partial_case
# [path before P]: on a branch with a slow run today, a commit of the tests aFast, bFast, and
# aSlow (and of the path), then P is HEAD. partial_line <commit> <base> <fast> <slow>.
partial_line() { echo "$1 $(g rev-parse "$2") failed fast:$3 slow:$4" >> "$tmp/r/.git/dirigible-check-partial"; }
tests_file=Tests/DirigibleCoreTests/A.swift bench_file=Tests/DirigibleAudioTests/LoudnessBenchmark.swift
partial_case() {
  new_repo
  g switch -q -c feat/p
  echo "$today" > "$tmp/r/.git/dirigible-slow-date"
  mkdir -p "$tmp/r/Tests/DirigibleCoreTests"
  printf 'func aFast() {}\nfunc bFast() {}\nfunc aSlow() {}\n' > "$tmp/r/$tests_file"
  g add -A
  g commit -q -m tests
  [[ -z "${1:-}" ]] || put "$1" one
  P="$(g rev-parse HEAD)"
}
# partial_is <name> <header> <classes> <targets> <risk> [env]: the whole output, exit 0.
partial_is() {
  local name="$1" want
  want="$(printf '%s\n%s' "$2" "$(out "$3" "$4" "$5")")"
  [[ -n "$2" ]] || want="$(out "$3" "$4" "$5")"
  got="$(cd "$tmp/r" && env ${6:-} "$script" main)" || { fail "$name: exit $?"; return; }
  [[ "$got" == "$want" ]] || fail "$name: got [$got], want [$want]"
}
partial_case
partial_line "$P" main aFast aSlow
partial_is 'a partial line and no path since P' "stamp: partial $P" tests "RERUN=$P:fast:aFast+slow:aSlow" no
put docs/b.md two
partial_is 'a partial line and a docs path since P' "stamp: partial $P" 'docs tests' "check-docs RERUN=$P:fast:aFast+slow:aSlow" no
# A Tests path since P gives check, which runs each fast test: the fast part drops, the slow part stays.
put Tests/DirigibleCoreTests/B.swift two
partial_is 'a Tests path since P drops the fast part' "stamp: partial $P" 'docs tests' "check RERUN=$P:fast:+slow:aSlow" no
# A name with no func <name>( under Tests/ drops; with no name left, there is no word.
partial_case
partial_line "$P" main aFast,gone ''
put docs/b.md two
partial_is 'a deleted name drops' "stamp: partial $P" 'docs tests' "check-docs RERUN=$P:fast:aFast+slow:" no
partial_case
partial_line "$P" main gone ''
put docs/b.md two
partial_is 'no name left: no word' "stamp: partial $P" 'docs tests' check-docs no
# Of two lines of ancestors of this base, the last in the file wins.
partial_case
partial_line "$P" main aFast ''
put docs/b.md two
P2="$(g rev-parse HEAD)"
partial_line "$P2" main bFast ''
partial_is 'the newest of two lines wins' "stamp: partial $P2" 'docs tests' "RERUN=$P2:fast:bFast+slow:" no
# No word: a pass stamp at P or after it, a line of another base, a line of a commit on another branch.
partial_case
partial_line "$P" main aFast ''
stamp_line "$P" main
stamped="$P"
partial_is 'a pass stamp at P' "stamp: delta $P" tests none no
put docs/b.md two
stamp_line "$(g rev-parse HEAD)" main
partial_is 'a pass stamp after P' "stamp: delta $(g rev-parse HEAD)" 'docs tests' none no
partial_case
partial_line "$P" "$P" aFast ''
partial_is 'a line of another base' '' tests check no
partial_case
g switch -q -c feat/other main
put docs/c.md other
partial_line "$(g rev-parse HEAD)" main aFast ''
g switch -q feat/p
partial_is 'a line of a commit on another branch' '' tests check no
# A partial line still needs the exact commit of the base: a pass stamp S and a newer partial line
# P of an older main commit give the delta after S, no partial line, and no RERUN word.
partial_case
stamped="$P"
stamp_line "$P" main
put docs/b.md two
partial_line "$(g rev-parse HEAD)" main aFast ''
main_moves feat/p
partial_is 'a partial line of an older main base' "stamp: delta $stamped" 'docs tests' check-docs no
# A red slow test of a PUSH_SKIP bench file, then a risk path after P: test-slow-push with no
# PUSH_RUN skips the bench file, so the slow part stays in the word.
partial_case
mkdir -p "$tmp/r/Tests/DirigibleAudioTests"
printf 'func aBench() {}\n' > "$tmp/r/$bench_file"
g add -A
g commit -q -m bench
P="$(g rev-parse HEAD)"
partial_line "$P" main '' aBench
put Sources/DirigibleAudio/A.swift two
partial_is 'a bench name and a risk path since P' "stamp: partial $P" 'tests sources-risk' "check test-slow-push RERUN=$P:fast:+slow:aBench" yes
# risk: yes and no Sources/ or Tests/ path since P (the working tree too): exit 1, no targets
# line, and a message that names the fix of the test, also in ignore mode.
for mode in '' CHECK_PARTIAL=ignore; do
  partial_case Sources/DirigibleAudio/A.swift
  partial_line "$P" main aFast ''
  put docs/b.md two
  got="$(cd "$tmp/r" && env $mode "$script" main 2> "$tmp/refuse.err")" && fail "risk and no change since P ($mode): exit 0"
  [[ "$got" != *targets:* ]] || fail "risk and no change since P ($mode): a targets line: $got"
  grep -q 'flake-triage.md' "$tmp/refuse.err" || fail "risk and no change since P ($mode): no flake-triage.md: $(cat "$tmp/refuse.err")"
  ! grep -q CHECK_PARTIAL "$tmp/refuse.err" || fail "risk and no change since P ($mode): the message offers CHECK_PARTIAL"
done
printf 'func cFast() {}\n' >> "$tmp/r/$tests_file"
partial_is 'risk and a Tests path since P in the working tree' "stamp: partial $P" 'docs tests sources-risk' check yes
# Ignore mode: the targets of a check with no partial line, and the word with each name of the line.
partial_case
partial_line "$P" main aFast,gone aSlow
put Tests/DirigibleCoreTests/B.swift two
partial_is 'ignore mode keeps each name' '' tests "check RERUN=$P:fast:aFast,gone+slow:aSlow" no CHECK_PARTIAL=ignore

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
  cp "$repo/scripts/check-stamp.sh" "$repo/scripts/test-filter.sh" "$repo/scripts/swift-test.sh" "$repo/scripts/with-lock.sh" "$repo/scripts/run-checks.sh" "$repo/scripts/check-waits.sh" "$tmp/r/scripts/"
  # run-checks.sh runs check-commits.sh when BASE is set; land.test.sh has the cases of the real one.
  printf '#!/bin/bash\nexit 0\n' > "$tmp/r/scripts/check-commits.sh"
  chmod +x "$tmp/r/scripts/check-commits.sh"
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
grep -Eq -- "\$2" <<< "\$line" || exit 1
echo "\$line"
EOF
# A fake lsof prints the cwd of the PID after -p, from the lines "<pid> <cwd>" of $tmp/cwds; a fake
# ps prints the parent of the PID after -p, from the lines "<pid> <ppid>" of $tmp/ppids.
cat > "$tmp/bin/lsof" <<EOF
#!/bin/bash
echo "\$*" >> "$tmp/lsof.log"
while [[ \$# -gt 0 ]]; do [[ "\$1" == -p ]] && pid="\$2"; shift; done
cwd="\$(awk -v p="\$pid" '\$1 == p { print \$2 }' "$tmp/cwds")"
[[ -n "\$cwd" ]] || exit 1
printf 'p%s\nfcwd\nn%s\n' "\$pid" "\$cwd"
EOF
cat > "$tmp/bin/ps" <<EOF
#!/bin/bash
[[ "\$1 \$2" == "-o ppid=" ]] || exec /bin/ps "\$@"
awk -v p="\$4" '\$1 == p { print \$2 }' "$tmp/ppids"
EOF
: > "$tmp/procs"; : > "$tmp/cwds"; : > "$tmp/ppids"
chmod +x "$tmp/bin/sysctl" "$tmp/bin/sleep" "$tmp/bin/pgrep" "$tmp/bin/lsof" "$tmp/bin/ps"
echo 1.00 > "$tmp/load"
PATH="$tmp/bin:$PATH" make_case 'make check-changed with FILTER' '' "FILTER=ATests BTests"
[[ "$output" == *"targets: test-filter"* ]] || fail "make check-changed with FILTER: no test-filter target: $output"
[[ "$(cat "$tmp/swift.log")" == "swift test --skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests --filter ATests --filter BTests" ]] ||
  fail "make check-changed with FILTER: swift calls: $(cat "$tmp/swift.log")"

# No FILTER: a local run with a Swift test exits 1 before any target, so no swift call runs.
: > "$tmp/swift.log"
PATH="$tmp/bin:$PATH" make_case 'make check-changed with no FILTER' 'push check'
[[ "$output" == *"FILTER"* && "$output" != *"check-changed: commit"* && ! -s "$tmp/swift.log" ]] ||
  fail "make check-changed with no FILTER: ran a target or named no FILTER: $output [$(cat "$tmp/swift.log")]"

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
# The target static runs no Swift test either.
: > "$tmp/sysctl.log"
got="$(PATH="$tmp/bin:$PATH" "$script" --wait-load static 2>&1)" || fail "--wait-load static exits $?"
[[ -z "$got" && ! -s "$tmp/sysctl.log" ]] || fail "--wait-load static read the load: [$got] [$(cat "$tmp/sysctl.log")]"
# A NAME=value word of the targets is no target: the HOOK_TESTS word of a check-fast run reads no load.
: > "$tmp/sysctl.log"
got="$(PATH="$tmp/bin:$PATH" "$script" --wait-load check-fast HOOK_TESTS=a,b 2>&1)" || fail "--wait-load with a HOOK_TESTS word exits $?"
[[ -z "$got" && ! -s "$tmp/sysctl.log" ]] || fail "--wait-load with a HOOK_TESTS word read the load: [$got] [$(cat "$tmp/sysctl.log")]"

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

# A bench (--wait-load bench) and a push check (BASE in the environment) also wait for a toolchain
# swift-build or swift-test, and for a test-hooks.sh, whose tree is not this one. The tree of a cwd
# is its git top level, or the cwd itself when it is no git tree. A test-hooks.sh runs in a clone of
# its own, so the tree is the cwd of its parent (make). A slice check (no BASE) keeps the helper
# rule only: its lock wait, load wait, and tests must fit in one 600 s call.
toolchain=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
mkdir -p "$tmp/o" "$tmp/plain" "$tmp/r-other" "$tmp/r/.build/bench" "$tmp/r/Sources"
git init -q "$tmp/o"
git init -q "$tmp/r-other"
git -C "$tmp/r" worktree add -q "$tmp/r/.claude/worktrees/x" 2>/dev/null
top() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || echo "$1"; }
# tree_case <name> <wait|none> <tree> <wait-load argument>...: the fake process of procs and cwds
# is there; CHECK_LOAD_WAIT=10 gives one wait of 10 s. A wait line names the pid and the tree.
tree_case() {
  local name="$1" want="$2" tree="$3" lines
  shift 3
  : > "$tmp/sleep.log"; echo 1.00 > "$tmp/load"
  got="$(cd "$tmp/r" && CHECK_LOAD_WAIT=10 PATH="$tmp/bin:$PATH" "$script" --wait-load "$@" 2> "$tmp/wait.err")" || fail "$name: exit $?"
  lines="$(grep -c 'wait 10 s' "$tmp/wait.err")"
  if [[ $want == wait ]]; then
    [[ "$lines" == 1 ]] && grep -q "pid 4242" "$tmp/wait.err" && grep -qF "$tree" "$tmp/wait.err" && [[ "$(tail -n 1 "$tmp/wait.err")" == *"run the tests" ]] ||
      fail "$name: no wait line with pid 4242 and $tree, then run the tests: $(cat "$tmp/wait.err")"
  else
    [[ "$lines" == 0 && ! -s "$tmp/sleep.log" ]] || fail "$name: it waited: $(cat "$tmp/wait.err")"
  fi
}
# one_proc <command line> <cwd>: the one process 4242, with no parent line.
one_proc() { printf '4242 %s\n' "$1" > "$tmp/procs"; printf '4242 %s\n' "$2" > "$tmp/cwds"; : > "$tmp/ppids"; }
one_proc "$toolchain/swift-build --package-path $tmp/o" "$tmp/o"
tree_case 'bench: a swift-build of another tree' wait "$(top "$tmp/o")" bench
BASE=origin/main tree_case 'push check: a swift-build of another tree' wait "$(top "$tmp/o")" test
tree_case 'slice check: a swift-build of another tree' none "" test
one_proc "$toolchain/swift-test --skip X" "$tmp/o"
tree_case 'bench: a swift-test of another tree' wait "$(top "$tmp/o")" bench
one_proc "$toolchain/swift-test --skip X" "$tmp/plain"
tree_case 'bench: a swift-test in a folder with no git tree' wait "$tmp/plain" bench
one_proc "$toolchain/swift-build" "$tmp/r-other"
tree_case 'bench: a swift-build of a folder next to the root' wait "$(top "$tmp/r-other")" bench
one_proc "$toolchain/swift-build" "$tmp/r/.claude/worktrees/x"
tree_case 'bench: a swift-build of a worktree under the root' wait "$(top "$tmp/r/.claude/worktrees/x")" bench
for cwd in "$tmp/r" "$tmp/r/.build/bench" "$tmp/r/Sources"; do
  one_proc "$toolchain/swift-build" "$cwd"
  tree_case "bench: a swift-build of this tree ($cwd)" none "" bench
done
one_proc "/usr/bin/less $tmp/o/swift-build.log" "$tmp/o"
tree_case 'bench: a command that only names swift-build' none "" bench
# A test-hooks.sh runs in a clone of its own: the cwd of its parent names its tree.
mkdir -p "$tmp/hooks-tree"
printf '4242 /bin/bash scripts/test-hooks.sh a,b\n' > "$tmp/procs"
printf '4242 %s\n4243 %s\n' "$tmp/hooks-tree" "$tmp/o" > "$tmp/cwds"
printf '4242 4243\n' > "$tmp/ppids"
tree_case 'bench: a test-hooks.sh whose parent is in another tree' wait "$(top "$tmp/o")" bench
BASE=origin/main tree_case 'push check: a test-hooks.sh whose parent is in another tree' wait "$(top "$tmp/o")" test
tree_case 'slice check: a test-hooks.sh whose parent is in another tree' none "" test
printf '4242 %s\n4243 %s\n' "$tmp/hooks-tree" "$tmp/r" > "$tmp/cwds"
tree_case 'bench: a test-hooks.sh whose parent is in this tree' none "" bench
: > "$tmp/procs"; : > "$tmp/cwds"; : > "$tmp/ppids"

# make test-slow and make test-slow-push write the date of today after a pass, and nothing after
# a red run. The temporary repo has no bench file, so PUSH_SKIP is empty on the command line.
for target in test-slow test-slow-push; do
  make_repo
  printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/swift"
  PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" $target PUSH_SKIP= > /dev/null 2>&1 && fail "make $target with a red swift exits 0"
  [[ ! -e "$tmp/r/.git/dirigible-slow-date" ]] || fail "a red make $target wrote the date"
  printf '#!/bin/bash\necho "Test run with 0 tests passed after 0.1 seconds." >&2\nexit 0\n' > "$tmp/bin/swift"
  PATH="$tmp/bin:$PATH" make -s -C "$tmp/r" $target PUSH_SKIP= > /dev/null 2>&1 || fail "make $target with a green swift exits nonzero"
  [[ "$(cat "$tmp/r/.git/dirigible-slow-date" 2>/dev/null)" == "$today" ]] || fail "a passing make $target did not write the date"
done

# test-slow-push passes no func of a PUSH_SKIP file to swift; test-slow passes each slow func.
make_repo
mkdir -p "$tmp/r/Tests/DirigibleAudioTests"
gate='guard ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1" else { return }'
printf '%s\nfunc aSkippedBench() {}\n' "$gate" > "$tmp/r/Tests/DirigibleAudioTests/LoudnessBenchmark.swift"
printf '%s\nfunc aKeptSlowTest() {}\n' "$gate" > "$tmp/r/Tests/DirigibleAudioTests/KeptTests.swift"
printf '#!/bin/bash\necho "swift $*" >> "%s"\necho "Test run with 1 test passed after 0.1 seconds."\n' "$tmp/swift.log" > "$tmp/bin/swift"
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

# The HOOK_TESTS word through make check-changed, the real check-changed.sh, and the real test-hooks.sh: two
# changed hook tests both run. The control is a script that prints the two tests joined with a space: make
# takes the second as a goal, runs the first only, and exits 0. The Makefile copy has no static gates, and
# the key tree needs a floor file that exists.
hook_repo() {
  make_repo
  sed -i '' 's/^STATIC_GATES := .*/STATIC_GATES :=/' "$tmp/r/Makefile"
  cp "$repo/scripts/test-hooks.sh" "$tmp/r/scripts/"
  g add -A
  g commit -q -m hooks
  : > "$tmp/hooks.log"
  for t in hid ax; do
    printf '#!/bin/bash\necho %s >> "%s"\n' "$t" "$tmp/hooks.log" > "$tmp/r/scripts/$t.test.sh"
    chmod +x "$tmp/r/scripts/$t.test.sh"
  done
}
hook_repo
PATH="$tmp/bin:$PATH" make_case 'make check-changed with two changed hook tests' ''
[[ "$output" == *"targets: check-fast HOOK_TESTS=$hid_test,$ax_test"* ]] || fail "two changed hook tests: no word: $output"
[[ "$(sort "$tmp/hooks.log" | tr '\n' ' ')" == 'ax hid ' ]] || fail "two changed hook tests: the log [$(tr '\n' ' ' < "$tmp/hooks.log")] holds not both tests: $output"
hook_repo
printf '#!/bin/bash\ncase "$1" in\n  --floor) echo Sources/DirigibleCore/SessionWriter.swift ;;\n  --wait-load) exit 0 ;;\n  *) printf "classes: tooling\\ntargets: check-fast HOOK_TESTS=%%s %%s\\nrisk: no\\n" "'$hid_test'" "'$ax_test'" ;;\nesac\n' > "$tmp/r/scripts/check-changed.sh"
PATH="$tmp/bin:$PATH" make_case 'make check-changed with a space-joined word' ''
[[ "$(wc -l < "$tmp/hooks.log" | tr -d ' ')" == 1 ]] || fail "a space-joined word: the control did not show one test: [$(tr '\n' ' ' < "$tmp/hooks.log")]"

# A tooling path that no test names gives the switch word, so the real test-hooks.sh runs the whole
# list of the fixture Makefile (two fake tests) and does not refuse it. The control is a script that
# prints no switch word: test-hooks.sh refuses, and no fake test runs.
two_fake_hook_repo() {
  hook_repo
  awk -v list="HOOK_TESTS = $hid_test $ax_test" '/^HOOK_TESTS *=/ { print list; skip = 1 } skip { if (!/\\$/) skip = 0; next } { print }' \
    "$tmp/r/Makefile" > "$tmp/Makefile.new" && mv "$tmp/Makefile.new" "$tmp/r/Makefile"
  g add -A
  g commit -q -m 'two fake hook tests'
  : > "$tmp/hooks.log"
  printf '#!/bin/bash\n:\n' > "$tmp/r/$unnamed"
}
two_fake_hook_repo
PATH="$tmp/bin:$PATH" make_case 'make check-changed with a path that no test names' ''
[[ "$output" == *"targets: check-fast$all_hooks"* ]] || fail "a path that no test names: no switch word: $output"
[[ "$output" != *'runs only in the push check'* ]] || fail "a path that no test names: the whole list was refused: $output"
[[ "$(sort "$tmp/hooks.log" | tr '\n' ' ')" == 'ax hid ' ]] || fail "a path that no test names: the log [$(tr '\n' ' ' < "$tmp/hooks.log")] holds not both fake tests: $output"
two_fake_hook_repo
printf '#!/bin/bash\ncase "$1" in\n  --floor) echo Sources/DirigibleCore/SessionWriter.swift ;;\n  --wait-load) exit 0 ;;\n  *) printf "classes: tooling\\ntargets: check-fast\\nrisk: no\\n" ;;\nesac\n' > "$tmp/r/scripts/check-changed.sh"
PATH="$tmp/bin:$PATH" make_case 'make check-changed with no switch word' 'the whole HOOK_TESTS list runs only in the push check'
[[ ! -s "$tmp/hooks.log" ]] || fail "no switch word: a fake test ran: [$(tr '\n' ' ' < "$tmp/hooks.log")]"

# A Makefile change of only comment lines is class docs and needs no hook test: the tooling path decides
# the word, and the switch word does not come.
make_repo
printf '# a comment\n' >> "$tmp/r/Makefile"
printf 'x\n' > "$tmp/r/$hid_test"
got="$(run_in 2>&1)" || fail "a Makefile comment and a hook test: exit $?"
[[ "$got" == "$(out 'docs tooling' "check-fast HOOK_TESTS=$hid_test" no)" ]] || fail "a Makefile comment and a hook test: got [$got]"

# SINCE=<ref> is the local mode of a group end: the commits since <ref> and the working tree pick
# the targets, the HOOK_TESTS word of a local run applies, and no stamp is read or written.
since_repo() { new_repo; sref="$(g rev-parse HEAD)"; }
since_repo
put "$hid_test" x
put "$ax_test" x
got="$(SINCE=$sref run_in 2>&1)" || fail "SINCE with a tooling commit: exit $?"
[[ "$got" == "$(out tooling "check-fast HOOK_TESTS=$hid_test,$ax_test" no)" ]] || fail "SINCE with a tooling commit: got [$got]"
# Control: the push form of the same commits keeps the full hook list (no word).
got="$(run_in "$sref" 2>&1)" || fail "the push form after SINCE cases: exit $?"
[[ "$got" == "$(out tooling check-fast no)" ]] || fail "the push form: got [$got]"
since_repo
put "$unnamed" x
got="$(SINCE=$sref run_in 2>&1)" || fail "SINCE with a path that has no test: exit $?"
[[ "$got" == "$(out tooling "check-fast$all_hooks" no)" ]] || fail "SINCE with a path that has no test: got [$got]"
# --paths reads no SINCE.
SINCE=no-such-ref expect 'SINCE with --paths' "$(out docs check-docs no)" <<<'docs/guide.md'
# SINCE with a base exits 2 and names both. A ref that does not exist prints nothing on stdout.
got="$(SINCE=$sref run_in some-base 2> "$tmp/since.err")"
code=$?
[[ $code -eq 2 && -z "$got" ]] || fail "SINCE with a base: exit $code, stdout [$got]"
grep -q 'SINCE' "$tmp/since.err" && grep -q 'some-base' "$tmp/since.err" || fail "SINCE with a base: the message does not name both: $(cat "$tmp/since.err")"
got="$(SINCE=no-such-ref run_in 2> /dev/null)" && fail 'SINCE with a ref that does not exist exits 0'
[[ -z "$got" ]] || fail "SINCE with a ref that does not exist prints [$got]"
# A ref with no changed path since it: exit 1 with the ref in the message.
new_repo
got="$(SINCE=HEAD run_in 2> "$tmp/since.err")"
code=$?
[[ $code -eq 1 && -z "$got" ]] || fail "SINCE with no changed path: exit $code, stdout [$got]"
grep -qF 'no changed paths since HEAD' "$tmp/since.err" || fail "SINCE with no changed path: no ref in the message: $(cat "$tmp/since.err")"
# Swift sources after the ref: the three lines, exit 1, and a reason that names the local form with
# FILTER, says that the full suite runs only in the push check, and holds no BASE. FILTER gives test-filter.
since_repo
put Sources/DirigibleApp/X.swift x
got="$(SINCE=$sref run_in 2> "$tmp/since.err")"
code=$?
[[ $code -eq 1 && "$got" == "$(out sources test no)" ]] || fail "SINCE with Sources, no FILTER: exit $code, got [$got]"
grep -qF "make check-changed SINCE=$sref FILTER='" "$tmp/since.err" || fail "SINCE with Sources, no FILTER: no local form in the reason: $(cat "$tmp/since.err")"
grep -qF 'full suite runs only in the push check' "$tmp/since.err" || fail "SINCE with Sources, no FILTER: no push check in the reason: $(cat "$tmp/since.err")"
! grep -qF 'BASE' "$tmp/since.err" || fail "SINCE with Sources, no FILTER: the reason names BASE: $(cat "$tmp/since.err")"
got="$(SINCE=$sref FILTER=ClipTests run_in 2>&1)" || fail "SINCE with Sources and FILTER: exit $?"
[[ "$got" == "$(out sources test-filter no)" ]] || fail "SINCE with Sources and FILTER: got [$got]"
# FILTER with a changed path that gives no test: exit 1, and the reason keeps SINCE with no FILTER.
# A bare make check-changed drops SINCE, finds no path, and reports targets: none with exit 0 (a repo
# with no origin/main; with commits past origin/main it refuses, see the cases after the SINCE cases).
since_repo
put "$unnamed" x
got="$(SINCE=$sref FILTER=ClipTests run_in 2> "$tmp/since.err")"
code=$?
[[ $code -eq 1 && "$got" == "$(out tooling "check-fast$all_hooks" no)" ]] || fail "SINCE and FILTER with no test: exit $code, got [$got]"
grep -qF "make check-changed SINCE=$sref with no FILTER" "$tmp/since.err" || fail "SINCE and FILTER with no test: no SINCE form in the reason: $(cat "$tmp/since.err")"
# Through the real Makefile, script, and test-hooks.sh: the targets of SINCE run, no stamp is read or
# written, and the hook test sees no SINCE (make puts it in the environment and in MAKEFLAGS).
hook_repo
sref="$(g rev-parse HEAD)"
: > "$tmp/since.log"
for t in hid ax; do
  printf '#!/bin/bash\necho "${SINCE-unset}" >> "%s"\n' "$tmp/since.log" > "$tmp/r/scripts/$t.test.sh"
  chmod +x "$tmp/r/scripts/$t.test.sh"
done
g add -A
g commit -q -m faketests
PATH="$tmp/bin:$PATH" make_case 'make check-changed with SINCE' '' SINCE="$sref"
[[ "$output" == "check-changed: commit $(g rev-parse HEAD) tree clean base none targets check-fast HOOK_TESTS=$hid_test,$ax_test"$'\n'* ]] ||
  fail "make check-changed with SINCE: first line: $output"
[[ "$(cat "$tmp/since.log")" == $'unset\nunset' ]] || fail "make check-changed with SINCE: the hook tests saw [$(tr '\n' ' ' < "$tmp/since.log")]: $output"
[[ "$(cd "$tmp/r" && scripts/check-stamp.sh read "$sref")" == 'no stamp' ]] || fail 'make check-changed with SINCE: a stamp exists'
# A bare run on a clean tree whose HEAD has commits past the merge base with origin/main exits 3
# with one stderr line (the count, the merge base, and the SINCE or BASE form) and prints nothing on
# stdout: the commits would otherwise report targets: none. A clean tree at or behind origin/main,
# with no origin/main, or with an origin/main that shares no commit with HEAD keeps the three lines
# and exit 0. SINCE, a base, a changed file, and the modes --paths, --floor, and --wait-load keep
# their result. FILTER gives test-filter and exit 0, with one stderr note.
ahead_repo() {
  local i
  new_repo
  g update-ref refs/remotes/origin/main HEAD
  for ((i = 1; i <= $1; i++)); do put "docs/c$i.md" x; done
  mb="$(g merge-base origin/main HEAD)"
}
refusal_line() { echo "check-changed: no changed path, and HEAD has commits past the merge base $mb of origin/main (count: $1): give SINCE=$mb or BASE=<ref>"; }
# refused <name> <count>: a bare run in the repo of ahead_repo.
refused() {
  got="$(run_in 2> "$tmp/bare.err")"
  code=$?
  [[ $code -eq 3 && -z "$got" ]] || fail "$1: exit $code, stdout [$got]"
  [[ "$(cat "$tmp/bare.err")" == "$(refusal_line "$2")" ]] || fail "$1: stderr [$(cat "$tmp/bare.err")], want [$(refusal_line "$2")]"
}
# kept <name>: the three lines of no change, exit 0, and no stderr.
kept() {
  got="$(run_in 2>&1)" || fail "$1: exit $?"
  [[ "$got" == "$(out none none no)" ]] || fail "$1: got [$got]"
}
ahead_repo 1
refused 'a clean tree 1 commit past origin/main' 1
ahead_repo 3
refused 'a clean tree 3 commits past origin/main' 3
make_repo
g update-ref refs/remotes/origin/main HEAD
put docs/c1.md x
mb="$(g merge-base origin/main HEAD)"
make_case 'make check-changed on a clean tree past origin/main' "$(refusal_line 1)"
ahead_repo 0
kept 'a clean tree at origin/main'
ahead_repo 1
g update-ref refs/remotes/origin/main HEAD
g reset -q --hard HEAD~1
kept 'a clean tree behind origin/main'
new_repo
kept 'a clean tree with no origin/main'
new_repo
g update-ref refs/remotes/origin/main "$(g commit-tree -m unrelated "$(g rev-parse 'HEAD^{tree}')")"
put docs/c1.md x
kept 'a clean tree past an origin/main with no common commit'
ahead_repo 1
got="$(SINCE=$mb run_in 2>&1)" || fail "past origin/main with SINCE: exit $?"
[[ "$got" == "$(out docs check-docs no)" ]] || fail "past origin/main with SINCE: got [$got]"
got="$(run_in main 2> "$tmp/bare.err")"
code=$?
[[ $code -eq 1 && "$(cat "$tmp/bare.err")" == 'check-changed: no changed paths against main' ]] || fail "past origin/main with a base: exit $code, stderr [$(cat "$tmp/bare.err")]"
got="$(FILTER=X run_in 2> "$tmp/bare.err")"
code=$?
[[ $code -eq 0 && "$got" == "$(out none test-filter no)" && "$(cat "$tmp/bare.err")" == *'FILTER runs only the named tests'* && "$(cat "$tmp/bare.err")" != *'give SINCE'* ]] ||
  fail "past origin/main with FILTER: exit $code, got [$got], stderr [$(cat "$tmp/bare.err")]"
# A changed path keeps the targets and exit 0, and the commits that the run does not check get one
# stderr note. SINCE, FILTER, and a run at origin/main get none.
printf 'x\n' > "$tmp/r/docs/d.md"
got="$(run_in 2> "$tmp/bare.err")" || fail "a dirty doc plus commits past origin/main: exit $?"
[[ "$got" == "$(out docs check-docs no)" ]] || fail "a dirty doc plus commits past origin/main: got [$got]"
[[ "$(cat "$tmp/bare.err")" == "check-changed: 1 commits past origin/main are not checked: give SINCE=$mb" ]] ||
  fail "a dirty doc plus commits past origin/main: stderr [$(cat "$tmp/bare.err")]"
got="$(SINCE=$mb run_in 2>&1)" || fail "a dirty doc, commits past origin/main, SINCE: exit $?"
[[ "$got" == "$(out docs check-docs no)" ]] || fail "a dirty doc, commits past origin/main, SINCE: got [$got]"
got="$(FILTER=X run_in 2> "$tmp/bare.err")"
[[ "$(cat "$tmp/bare.err")" != *'are not checked'* ]] || fail "a dirty doc, commits past origin/main, FILTER: a note [$(cat "$tmp/bare.err")]"
rm "$tmp/r/docs/d.md"
ahead_repo 0
printf 'x\n' > "$tmp/r/docs/d.md"
got="$(run_in 2>&1)" || fail "a dirty doc at origin/main: exit $?"
[[ "$got" == "$(out docs check-docs no)" ]] || fail "a dirty doc at origin/main: got [$got]"
ahead_repo 1
got="$(run_in --paths 2>&1 < /dev/null)" || fail "past origin/main with --paths: exit $?"
[[ "$got" == "$(out none none no)" ]] || fail "past origin/main with --paths: got [$got]"
got="$(run_in --floor 2>&1)" || fail "past origin/main with --floor: exit $?"
[[ "$got" == "$("$script" --floor)" && "$got" == *SessionWriter.swift* ]] || fail "past origin/main with --floor: got [$got]"
got="$(run_in --wait-load none 2>&1)" || fail "past origin/main with --wait-load: exit $?"
[[ -z "$got" ]] || fail "past origin/main with --wait-load: got [$got]"

# The mode --overlap <base> names other work that changes a Sources/ or Tests/ file of this branch:
# the commits of <base> since the merge base, each other worktree (commits, working tree, and
# untracked files), and each open PR of gh. It is information: exit 0 in each case but the usage
# line (exit 2). Every case runs with a stub gh that prints nothing first on PATH and with GH_REPO and
# GH_HOST unset, so no case calls the real gh; a case that needs another gh puts its folder in OV_GH.
mkdir -p "$tmp/ovbin"
printf '#!/bin/bash\nexit 0\n' > "$tmp/ovbin/gh"
chmod +x "$tmp/ovbin/gh"
ov() { (unset GH_REPO GH_HOST; PATH="${OV_GH:-$tmp/ovbin}:$PATH"; run_in --overlap "$@"); }
# ov_is <name> <want> [base]: the whole stdout is <want> and the exit is 0.
ov_is() {
  local name="$1" want="$2"
  shift 2
  got="$(ov "${@:-main}" 2> "$tmp/ov.err")"
  code=$?
  [[ $code -eq 0 && "$got" == "$want" ]] || fail "overlap: $name: exit $code, got [$got], want [$want], stderr [$(cat "$tmp/ov.err")]"
}
# fake_gh <folder> <script body>
fake_gh() { mkdir -p "$1" && printf '#!/bin/bash\n%s\n' "$2" > "$1/gh" && chmod +x "$1/gh"; }
gw() { git -C "$tmp/w1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
# ov_repo: main has Sources/.../X.swift and Tests/T.swift; the branch feat/o forks from it.
ov_repo() {
  new_repo
  put Sources/DirigibleCore/X.swift base
  put Tests/T.swift base
  g switch -q -c feat/o
  rm -rf "$tmp/w1"
  g worktree prune
}
ov_repo
g switch -q main
put Sources/DirigibleCore/X.swift main
g switch -q feat/o
put Sources/DirigibleCore/X.swift branch
ov_is 'base moved on a shared Sources file' 'overlap: main: Sources/DirigibleCore/X.swift'
ov_repo
g switch -q main
put docs/a.md main
g switch -q feat/o
put docs/a.md branch
ov_is 'a shared docs file only' 'overlap: none'
ov_repo
put Tests/T.swift branch
ov_is 'the own worktree gives no line' 'overlap: none'
# Another worktree: a committed change, then an uncommitted change with a held index.lock.
ov_repo
g worktree add -q "$tmp/w1" -b feat/w1
put Tests/T.swift branch
put Sources/DirigibleCore/X.swift branch
printf 'w\n' >> "$tmp/w1/Tests/T.swift"
gw commit -q -am wt
ov_is 'a committed change of another worktree' 'overlap: worktree feat/w1: Tests/T.swift'
gw reset -q --hard HEAD~1
printf 'w\n' >> "$tmp/w1/Tests/T.swift"
printf 'u\n' > "$tmp/w1/Tests/U.swift"
printf 'u\n' > "$tmp/r/Tests/U.swift"
: > "$tmp/r/.git/worktrees/w1/index.lock"
ov_is 'an uncommitted change of another worktree' 'overlap: worktree feat/w1: Tests/T.swift, Tests/U.swift'
[[ -e "$tmp/r/.git/worktrees/w1/index.lock" ]] || fail 'overlap: the index.lock of the other worktree is gone'
rm -f "$tmp/r/.git/worktrees/w1/index.lock"
# From the linked worktree, the main worktree gives the line and the linked one gives none.
got="$(cd "$tmp/w1" && unset GH_REPO GH_HOST && PATH="$tmp/ovbin:$PATH" "$script" --overlap main 2>&1)" || fail "overlap: from a linked worktree: exit $?"
[[ "$got" == 'overlap: worktree feat/o: Tests/T.swift, Tests/U.swift' ]] || fail "overlap: from a linked worktree: got [$got]"
rm -rf "$tmp/w1"
g worktree prune
# A worktree made from this branch names only the files of the commits that this branch lacks.
ov_repo
put Tests/T.swift branch
put Sources/DirigibleCore/X.swift branch
g worktree add -q "$tmp/w1" -b feat/w1
printf 'w\n' >> "$tmp/w1/Sources/DirigibleCore/X.swift"
gw commit -q -am wt
ov_is 'a worktree made from this branch with one more commit' 'overlap: worktree feat/w1: Sources/DirigibleCore/X.swift'
rm -rf "$tmp/w1"
g worktree prune
# A detached worktree is named by its short HEAD.
ov_repo
put Tests/T.swift branch
g worktree add -q --detach "$tmp/w1"
printf 'd\n' >> "$tmp/w1/Tests/T.swift"
ov_is 'a detached worktree' "overlap: worktree $(gw rev-parse --short HEAD): Tests/T.swift"
rm -rf "$tmp/w1"
g worktree prune
# Open PRs: the PR of the current branch gives no line.
ov_repo
put Sources/DirigibleCore/X.swift branch
# The fake gh prints what gh prints with the --jq filter of the script: one line for each PR with
# its number, branch, and file paths, with tabs between.
tsv=$'7\tfeat/o\tSources/DirigibleCore/X.swift\n9\tfeat/other\tSources/DirigibleCore/X.swift\tdocs/z.md\n10\tfeat/docs\tdocs/z.md'
fake_gh "$tmp/ovgh" "printf '%s\\n' '$tsv'; echo \"\$*\" > '$tmp/gh.args'"
OV_GH="$tmp/ovgh" ov_is 'two open PRs' 'overlap: PR #9 (feat/other): Sources/DirigibleCore/X.swift'
grep -qF -- '--limit 200' "$tmp/gh.args" || fail "overlap: gh got [$(cat "$tmp/gh.args")], want --limit 200"
grep -qF -- '--jq' "$tmp/gh.args" || fail "overlap: gh got [$(cat "$tmp/gh.args")], want --jq"
fake_gh "$tmp/ovgh" "sleep 0.3; printf '%s\\n' '$tsv'"
OVERLAP_GH_TIMEOUT=08 OV_GH="$tmp/ovgh" ov_is 'a timeout with a leading zero' 'overlap: PR #9 (feat/other): Sources/DirigibleCore/X.swift'
fake_gh "$tmp/ovgh" 'echo "gh: not logged in" >&2; echo "second line" >&2; exit 1'
OV_GH="$tmp/ovgh" ov_is 'gh fails' $'overlap: none\noverlap: open PRs not read (gh: not logged in)'
# A gh that does not answer: the mode stops it after OVERLAP_GH_TIMEOUT seconds and goes on.
fake_gh "$tmp/ovgh" "echo \$\$ > '$tmp/gh.pid'; exec sleep 30"
SECONDS=0
OVERLAP_GH_TIMEOUT=1 OV_GH="$tmp/ovgh" ov_is 'gh gives no answer' $'overlap: none\noverlap: gh: no answer'
((SECONDS < 5)) || fail "overlap: gh gives no answer: took $SECONDS s"
! kill -0 "$(cat "$tmp/gh.pid")" 2> /dev/null || fail 'overlap: the fake gh is still running'
# A base that git cannot read, and no base.
ov_is 'a base that git cannot read' 'overlap: base nope not read' nope
got="$(ov 2> "$tmp/ov.err")"
code=$?
[[ $code -eq 2 && -z "$got" ]] && grep -q 'usage:' "$tmp/ov.err" || fail "overlap: no base: exit $code, stdout [$got], stderr [$(cat "$tmp/ov.err")]"
ov_repo

# No context variable of this script reaches a test that it runs: each test file that names this
# script and unsets BASE, FILTER, or MAKEFLAGS also unsets SINCE.
for f in $(grep -rl --include='*.test.sh' 'check-changed.sh' "$repo/scripts" "$repo/.claude"); do
  lines="$(grep -E '^unset .*(BASE|FILTER|MAKEFLAGS)' "$f")" || continue
  ! grep -qv 'SINCE' <<<"$lines" || fail "${f#"$repo"/}: an unset line of BASE, FILTER, or MAKEFLAGS has no SINCE"
done

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

# The rerun of run-checks.sh through the recipe. A fake test-shards.sh fails with a failed test
# line, so the real test recipe is red; a fake test-filter.sh passes or fails by FAKE_FILTER.
# A red test that passes on a rerun writes the stamp; a red rerun writes none.
rerun_repo() {
  stamp_repo test
  printf '#!/bin/bash\necho "✘ Test aFlake() failed after 1.0 seconds with 1 issue."\nexit 1\n' > "$tmp/r/scripts/test-shards.sh"
  printf '#!/bin/bash\nif [[ "$FAKE_FILTER" == pass ]]; then echo "✔ Test aFlake() passed after 1.0 seconds."; exit 0; fi\necho "✘ Test aFlake() failed after 1.0 seconds with 1 issue."\nexit 1\n' > "$tmp/r/scripts/test-filter.sh"
  chmod +x "$tmp/r/scripts/test-shards.sh"
  g add -A
  g commit -q -m fake-tests
}
rerun_repo
FAKE_FILTER=pass PATH="$tmp/bin:$PATH" make_case 'a red test that passes on a rerun' '' BASE=main
[[ "$(stamp_read)" == "$(g rev-parse HEAD) test" ]] || fail "a red test that passes on a rerun: stamp [$(stamp_read)]: $output"
[[ "$output" == *"run-checks: flake: aFlake passed on rerun 1 of 3"* ]] || fail "a red test that passes on a rerun: no flake line: $output"
rerun_repo
FAKE_FILTER=red PATH="$tmp/bin:$PATH" make_case 'a red rerun' 'red after 3 reruns' BASE=main
[[ "$(stamp_read)" == 'no stamp' ]] || fail "a red rerun: stamp [$(stamp_read)]"
# A partial stamp through the real recipe and script: the RERUN word alone runs the failed test,
# and its pass writes the pass stamp of HEAD.
rerun_repo
cp "$script" "$tmp/r/scripts/check-changed.sh"
g commit -q -am real-script
g switch -q -c feat/r
put Tests/DirigibleCoreTests/F.swift 'func aFlake() {}'
partial_line "$(g rev-parse HEAD)" main aFlake ''
echo 1.00 > "$tmp/load"
: > "$tmp/procs"
FAKE_FILTER=pass PATH="$tmp/bin:$PATH" make_case 'a partial stamp through make check-changed' '' BASE=main
word="RERUN=$(g rev-parse HEAD):fast:aFlake+slow:"
[[ "$output" == *"targets: $word"* ]] || fail "a partial stamp through make check-changed: no word: $output"
[[ "$(stamp_read)" == "$(g rev-parse HEAD) $word" ]] || fail "a partial stamp through make check-changed: stamp [$(stamp_read)]: $output"

[[ $failures -eq 0 ]] && echo "check-changed tests: all passed"
exit $((failures > 0))
