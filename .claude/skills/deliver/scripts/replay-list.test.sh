#!/bin/bash
# Check that replay-list.sh lists a killed control log when the diff has its mutated file, its
# `# in` file, or a test file that its `# test:` line names: a func name, a suite name in single
# quotes, a regex with bars and a slash, or a `scripts/bench.sh <name>` argument, or another file
# of the suite of such a test. Check that it
# lists a log whose test line resolves to no file with `unresolved`, and that it does not list a
# log for an unrelated change, a survived log, a .orig copy, or a log under replay/. With no
# diff it prints nothing and exits 0. Each case uses a temporary repo. Run by `make test-hooks`.
set -uo pipefail
list="$(cd "$(dirname "$0")" && pwd)/replay-list.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

repo="$tmp/repo" ctl="$tmp/controls"
mkdir -p "$repo/Sources" "$repo/Tests/X" "$ctl/replay"
git -C "$repo" init -q -b main
for f in A B C Z; do echo "let $f = 1" > "$repo/Sources/$f.swift"; done
printf '@Suite struct FooTests {\n  func helper() {}\n}\n' > "$repo/Tests/X/FooTests.swift"
printf 'extension FooTests {\n  @Test func aliveTickCounts() {}\n}\n' > "$repo/Tests/X/FooTests+Counts.swift"
printf 'struct BarTests {\n  @Test func x() {}\n}\n' > "$repo/Tests/X/BarTests.swift"
printf 'struct QuxTests {\n  @Test func cTwo() {}\n}\nstruct OtherTests {}\n' > "$repo/Tests/X/QuxTests.swift"
printf 'extension QuxTests {\n  @Test func dOne() {}\n}\n' > "$repo/Tests/X/DTests.swift"
printf 'struct BenchTests {\n  @Test func aTakeTickFits() {}\n}\n' > "$repo/Tests/X/BenchTests.swift"
echo readme > "$repo/README.md"
git -C "$repo" add -A
git -C "$repo" commit -q -m base

# control <log path> <result> <test line> <mutated file> [<in file>]
control() {
  {
    echo "# mutation of $4"
    echo "# - 'let'"
    echo "# + 'var'"
    [[ -n "${5:-}" ]] && printf '# in %s\n# - %s\n# + %s\n' "$5" "'a'" "'b'"
    echo '# build: swift build --build-tests 2>&1 | tail -30'
    echo "# test: $3 2>&1"
    echo "# expect: 'x'"
    echo 'output'
    echo "# result: $2"
  } > "$1"
}
control "$ctl/k-mut.log" killed 'swift test --skip-build --filter OtherTests' Sources/A.swift
control "$ctl/k-in.log" killed 'swift test --skip-build --filter OtherTests' Sources/C.swift Sources/B.swift
control "$ctl/k-func.log" killed 'swift test --skip-build --filter aliveTickCounts' Sources/C.swift
control "$ctl/k-suite.log" killed "swift test --skip-build --filter 'BarTests'" Sources/C.swift
control "$ctl/k-regex.log" killed "swift test --skip-build --filter 'OtherTests|QuxTests/(cTwo|dOne)'" Sources/C.swift
control "$ctl/k-bench.log" 'killed (hang)' 'scripts/bench.sh aTakeTickFits' Sources/C.swift
control "$ctl/k-unres.log" killed 'swift test --skip-build --filter NoSuchThing' Sources/C.swift
control "$ctl/k-unrelated.log" killed 'swift test --skip-build --filter OtherTests' Sources/Z.swift
control "$ctl/k-surv.log" survived 'swift test --skip-build --filter OtherTests' Sources/A.swift
control "$ctl/k-copy.log.orig" killed 'swift test --skip-build --filter OtherTests' Sources/A.swift
control "$ctl/replay/k-mut.log" killed 'swift test --skip-build --filter OtherTests' Sources/A.swift

# change <file>: commit one change of the file, and run the script with the commit before it.
change() {
  echo "// changed" >> "$repo/$1"
  git -C "$repo" commit -q -am "change $1"
  out="$(cd "$repo" && "$list" "$ctl" HEAD~1 2>&1)"
  code=$?
  [[ $code -eq 0 ]] || fail "$1: exit $code: $out"
}
# listed <case> <line>: the output has the line. not_listed <case> <log name>: no line names the log.
listed() { grep -qxF -- "$2" <<<"$out" || fail "$1: no line '$2' in: $out"; }
not_listed() { ! grep -qF -- "/$2 " <<<"$out" || fail "$1: $2 is listed: $out"; }

change Sources/A.swift
listed 'the mutated file changed' "$ctl/k-mut.log Sources/A.swift"
listed 'a test line that resolves to no file' "$ctl/k-unres.log unresolved"
not_listed 'a survived log' k-surv.log
not_listed 'a .orig copy' k-copy.log.orig
not_listed 'a log under replay/' replay/k-mut.log
grep -q 'replay/' <<<"$out" && fail "a log under replay/ is listed: $out"
not_listed 'the mutated file of another control' k-unrelated.log

change Sources/B.swift
listed 'the # in file changed' "$ctl/k-in.log Sources/B.swift"

change 'Tests/X/FooTests+Counts.swift'
listed 'the file of a filter func changed' "$ctl/k-func.log Tests/X/FooTests+Counts.swift"

change Tests/X/FooTests.swift
listed 'another file of the suite of a filter func changed' "$ctl/k-func.log Tests/X/FooTests.swift"

change Tests/X/BarTests.swift
listed 'the file of a quoted suite name changed' "$ctl/k-suite.log Tests/X/BarTests.swift"

change Tests/X/DTests.swift
listed 'the func d file of a regex A|B/(c|d) changed' "$ctl/k-regex.log Tests/X/DTests.swift"
not_listed 'a regex part in another file' k-suite.log

change Tests/X/BenchTests.swift
listed 'the func file of a bench.sh name changed' "$ctl/k-bench.log Tests/X/BenchTests.swift"

change README.md
for name in k-mut k-in k-func k-suite k-regex k-bench k-unrelated k-surv; do
  not_listed 'only an unrelated file changed' "$name.log"
done
[[ "$out" == "$ctl/k-unres.log unresolved" ]] || fail "only an unrelated file changed: not only the unresolved line: $out"

out="$(cd "$repo" && "$list" "$ctl" HEAD 2>&1)"
code=$?
[[ $code -eq 0 && -z "$out" ]] || fail "no diff: exit $code, output: $out"

out="$(cd "$repo" && "$list" "$ctl" 2>&1)"
code=$?
[[ $code -eq 2 && "$out" == usage:* ]] || fail "one argument: exit $code, output: $out"

[[ $failures -eq 0 ]] && echo "replay-list tests: all passed"
exit $((failures > 0))
