#!/bin/bash
# Check that check-changed.sh prints the right three lines for each kind of change, fails closed
# on a bad or empty base, still sees a moved floor file, and that each risk floor path exists.
# Check that `make check-changed` of the real Makefile exits nonzero when the script does, and
# runs no target (not the default goal `setup`) for an empty target list. Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/scripts/check-changed.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A git or make value of an outer run must not reach the temporary repos of this test.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE MAKEFLAGS MFLAGS MAKELEVEL BASE

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# expect <name> <want> [--push]: the paths come from stdin, and the whole output must be <want>.
expect() {
  local name="$1" want="$2" got
  shift 2
  got="$("$script" --paths "$@")" || { fail "$name: exit $?"; return; }
  [[ "$got" == "$want" ]] || fail "$name: got [$got], want [$want]"
}
out() { printf 'classes: %s\ntargets: %s\nrisk: %s' "$1" "$2" "$3"; }

expect 'docs only' "$(out docs check-docs no)" <<<'.claude/skills/tdd/SKILL.md'
expect 'a probe script' "$(out tooling check-fast no)" <<<'scripts/probe.sh'
expect 'a skill doc and a skill script' "$(out 'docs tooling' check-fast no)" \
  <<<$'.claude/skills/deliver/SKILL.md\n.claude/skills/deliver/scripts/new-run.sh'
expect 'Makefile per commit' "$(out bundle check no)" <<<'Makefile'
expect 'Makefile before the push' "$(out bundle 'check test-dmg' no)" --push <<<'Makefile'
expect 'Package.swift per commit' "$(out build check no)" <<<'Package.swift'
expect 'Package.swift before the push' "$(out build 'check test-slow' no)" --push <<<'Package.swift'
expect 'Tests only' "$(out tests test no)" <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'Tests only before the push' "$(out tests check no)" --push <<<'Tests/DirigibleCoreTests/SessionTests.swift'
expect 'app sources per commit' "$(out sources test no)" <<<'Sources/DirigibleApp/AppDelegate.swift'
expect 'app sources before the push' "$(out sources 'check test-slow' no)" --push <<<'Sources/DirigibleApp/AppDelegate.swift'
expect 'capture sources' "$(out sources-risk 'check test-slow' yes)" --push \
  <<<'Sources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'capture sources per commit' "$(out sources-risk test yes)" <<<'Sources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'session writer' "$(out sources-risk test yes)" <<<'Sources/DirigibleCore/SessionWriter.swift'
expect 'Makefile and capture sources' "$(out 'sources-risk bundle' 'check test-slow test-dmg' yes)" --push \
  <<<$'Makefile\nSources/DirigibleAudio/Capture/DeviceWriter.swift'
expect 'Support' "$(out bundle 'check test-dmg' no)" --push <<<'Support/Info.plist'
expect 'bundle script' "$(out bundle check no)" <<<'scripts/bundle.sh'
expect 'app bundle test' "$(out bundle check no)" <<<'Tests/DirigibleTests/AppBundleTests.swift'
expect 'unknown top-level file' "$(out build check no)" <<<'unknown.txt'
expect 'docs and sources' "$(out 'docs sources' 'check-docs test' no)" \
  <<<$'docs/guide.md\nSources/DirigibleApp/AppDelegate.swift'
expect 'docs, tooling, and the Makefile before the push' "$(out 'docs tooling bundle' 'check test-dmg' no)" --push \
  <<<$'AGENTS.md\nscripts/check-changed.sh\nMakefile'
expect 'empty list, no base' "$(out none none no)" </dev/null

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
[[ "$got" == "$(out sources 'check test-slow' no)" ]] || fail "a Sources branch: got [$got]"

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
  local name="$1" reason="$2" output code
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
  g add -A
  g commit -q -m make
}
make_repo; make_case 'make check-changed with a bad base' 'does-not-exist' BASE=does-not-exist
make_repo; make_case 'make check-changed with a base with no diff' 'no changed paths against main' BASE=main
make_repo; make_case 'make check-changed with no changed path' ''
# A script output with no targets line fails, so an empty list never passes.
make_repo
printf '#!/bin/bash\necho "classes: none"\n' > "$tmp/r/scripts/check-changed.sh"
g commit -q -am stub
make_case 'make check-changed with no targets line' 'no targets line'

[[ $failures -eq 0 ]] && echo "check-changed tests: all passed"
exit $((failures > 0))
