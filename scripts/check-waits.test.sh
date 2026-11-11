#!/bin/bash
# Check that check-waits.sh passes a tree with no raw `.wait(timeout:` in Tests/, and fails each
# tree with a raw wait and no allow entry, or with an allow entry that is not true. Check the count
# gate (a Swift file with more wall-clock lines than at the reference and over its cap in
# scripts/check-waits.counts; mode warn or fail) and the refusal of a rise of the isIntermittent, `"quarantine:`, or `.disabled(` lines in the
# Tests/ total, each in a git repo with a commit; the reference is HEAD, or the merge base with BASE. Run by `make test-hooks`.
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE BASE
check="$(cd "$(dirname "$0")" && pwd)/check-waits.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A new tree in $tmp with Tests/B, Sources/A, and an empty allow file.
tree() {
  rm -rf "$tmp"/* "$tmp/.git" && mkdir -p "$tmp/Sources/A" "$tmp/Tests/B" "$tmp/scripts" && : > "$tmp/scripts/check-waits.allow"
}
raw() { echo '        _ = hold.wait(timeout: .now() + 30)' > "$tmp/$1"; }
allow() { printf '%b' "$1" > "$tmp/scripts/check-waits.allow"; }

# expect pass <name> [<message>], or expect fail <name> <message>. A failure counts only with its
# message. A pass with a message prints it (a warning line); a pass with none prints nothing. $base is
# the BASE of the call. The exit status of the call is in $code. $feed is the standard input of the call.
expect() {
  local want="$1" name="$2" message="${3:-}" got output
  output="$(env BASE="${base:-}" "$check" "$tmp" 2>&1 >/dev/null <<<"${feed:-}")"
  code=$?
  [[ $code -eq 0 ]] && got=pass || got=fail
  if [[ "$got" == fail && "$want" == fail ]] && ! grep -qF "check-waits: $message" <<<"$output"; then
    got="fail without '$message'"
  elif [[ "$got" == pass && "$want" == pass && -z "$message" && -n "$output" ]]; then
    got="pass with output [$output]"
  elif [[ "$got" == pass && "$want" == pass && -n "$message" ]] && ! grep -qF "check-waits: $message" <<<"$output"; then
    got="pass without '$message' in [$output]"
  fi
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

tree; echo 'let gate = Gate(limit: .seconds(5))' > "$tmp/Tests/B/b.swift"; expect pass 'a test with no raw wait'
tree; raw Tests/B/b.swift; expect fail 'a raw wait with no allow entry' 'Tests/B/b.swift:1: a raw .wait(timeout:'
tree; raw Sources/A/a.swift; expect pass 'a raw wait outside Tests/'
tree; raw Tests/B/b.txt; expect pass 'a file that is not Swift'
tree; raw Tests/B/b.swift; allow '# a comment\nTests/B/b.swift\tthe wait of the test\n'
expect pass 'a raw wait with an allow entry and a reason'
tree; raw Tests/B/b.swift; allow 'Tests/B/b.swift\t \n'
expect fail 'an allow entry with no reason' 'Tests/B/b.swift: an allow entry with no reason'
tree; raw Tests/B/b.swift; allow 'Tests/B/b.swift\n'
expect fail 'an allow entry with no tab' 'Tests/B/b.swift: an allow entry with no reason'
tree; echo 'let x = 1' > "$tmp/Tests/B/b.swift"; allow 'Tests/B/b.swift\tthe wait of the test\n'
expect fail 'an allow entry for a file with no raw wait' 'Tests/B/b.swift: an allow entry for a file with no raw wait'
tree; allow 'Tests/B/gone.swift\tthe wait of the test\n'
expect fail 'an allow entry for a missing file' 'Tests/B/gone.swift: an allow entry for a file with no raw wait'

quarantine() { printf '    withKnownIssue(%s, isIntermittent: true) {\n' "$1" > "$tmp/$2"; }
tree; quarantine '"quarantine: the stop misses"' Tests/B/b.swift
expect fail 'a quarantine marker with no FLAKE word' 'Tests/B/b.swift:1: a "quarantine: marker with no FLAKE word'
tree; quarantine '"quarantine: the stop misses, see backlog FLAKE LINE 40"' Tests/B/b.swift
expect pass 'a quarantine marker with a FLAKE word'
tree; quarantine '"quarantine: the stop misses"' Sources/A/a.swift; expect pass 'a quarantine marker outside Tests/'
tree; quarantine '"quarantine: the stop misses"' Tests/B/b.txt; expect pass 'a quarantine marker in a file that is not Swift'
tree; quarantine '"quarantine: the stop misses, FLAKEY"' Tests/B/b.swift
expect fail 'a word that only starts with FLAKE' 'Tests/B/b.swift:1: a "quarantine: marker with no FLAKE word'
tree; quarantine 'flake' Tests/B/b.swift
expect fail 'isIntermittent with no quarantine marker' 'Tests/B/b.swift: an isIntermittent: true with no "quarantine: marker that has a FLAKE word'
tree; quarantine 'flake' Tests/B/b.swift; echo '    "quarantine: the stop misses, see backlog FLAKE LINE 40"' >> "$tmp/Tests/B/b.swift"
expect pass 'isIntermittent with a quarantine marker on another line'
tree; quarantine 'flake' Sources/A/a.swift; expect pass 'isIntermittent outside Tests/'

# The count gate and the isIntermittent gate need git: repo [<counts file text>] makes a repo in $tmp
# with one commit: the folders of tree(), a counts file (default mode fail), Tests/B/b.swift with one
# wall-clock line, and Tests/B/i.swift with one isIntermittent line that has its FLAKE marker.
# g runs git there, with no config write.
sleepline='        try await Task.sleep(for: .seconds(1))'
flakeline() { printf '    withKnownIssue("quarantine: %s, FLAKE a", isIntermittent: true) {\n' "$1"; }
g() { git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
repo() {
  tree
  printf '%s\n' "${1:-mode fail}" > "$tmp/scripts/check-waits.counts"
  echo "$sleepline" > "$tmp/Tests/B/b.swift"
  flakeline x > "$tmp/Tests/B/i.swift"
  g init -q -b main && g add -A && g commit -q -m base
}
more() { echo "$sleepline" >> "$tmp/Tests/B/b.swift"; }
rise='wall-clock lines, 1 at HEAD; add Tests/B/b.swift<TAB>2<TAB><reason> to scripts/check-waits.counts'
repo; expect pass 'a repo with no change'
repo; more; expect fail 'a new wall-clock line in a committed test file' "Tests/B/b.swift: 2 $rise"
repo; more; printf 'Tests/B/b.swift\t2\ta reason\n' >> "$tmp/scripts/check-waits.counts"
expect pass 'a rise with a cap line of the new count'
repo; more; printf 'Tests/B/b.swift\t1\ta reason\n' >> "$tmp/scripts/check-waits.counts"
expect fail 'a rise with a cap line one under the new count' "Tests/B/b.swift: 2 $rise"
repo; echo "$sleepline" > "$tmp/Tests/B/new.swift"
expect fail 'a new test file with a wall-clock line' 'Tests/B/new.swift: 1 wall-clock lines, 0 at HEAD; add Tests/B/new.swift<TAB>1<TAB><reason>'
repo; : > "$tmp/Tests/B/b.swift"; expect pass 'a removed wall-clock line'
repo; echo "$sleepline" > "$tmp/Sources/A/a.swift"
expect fail 'a new wall-clock line under Sources/' 'Sources/A/a.swift: 1 wall-clock lines, 0 at HEAD'
repo; echo "$sleepline" > "$tmp/Tests/B/b.txt"; expect pass 'a new line in a file that is not Swift'
repo; echo '// Task.sleep is slow' >> "$tmp/Tests/B/b.swift"; expect fail 'a comment line with Task.sleep' "Tests/B/b.swift: 2 $rise"
repo; echo 'let known = 1; let x = Task.slept' >> "$tmp/Tests/B/b.swift"; expect pass 'a line with known and Task.slept'
for term in 'Task.sleep' 'Thread.sleep' 'usleep(1)' 'ContinuousClock.now' 'DispatchTime.now' 'asyncAfter' 'makeTimerSource' 'Timer.scheduled' 'pace: .realTime'; do
  repo; echo "x $term" >> "$tmp/Tests/B/b.swift"; expect fail "the term $term" "Tests/B/b.swift: 2 $rise"
done
# The reference: HEAD with no BASE, else the merge base of BASE and HEAD.
repo; first="$(g rev-parse HEAD)"; more; g commit -q -am rise
base="$first"; expect fail 'BASE the first commit, the rise committed' "Tests/B/b.swift: 2 wall-clock lines, 1 at merge-base $first;"
base=; expect pass 'no BASE, HEAD holds the rise'
repo; g checkout -q -b side; : > "$tmp/Tests/B/b.swift"; g commit -q -am 'side drops the line'; side="$(g rev-parse HEAD)"; g checkout -q main
base="$side"; expect pass 'the tip of BASE drops a wall-clock line that the branch keeps'
repo; g checkout -q -b side; : > "$tmp/Tests/B/i.swift"; g commit -q -am 'side drops the line'; side="$(g rev-parse HEAD)"; g checkout -q main
base="$side"; expect pass 'the tip of BASE drops an isIntermittent line that the branch keeps'
repo; other="$(g commit-tree "$(g hash-object -t tree /dev/null)" -m other)"
base="$other"; expect fail 'BASE with no merge base' "no merge base of $other and HEAD"
[[ $code -eq 2 ]] || { echo "FAIL: no merge base: exit $code, want 2"; failures=$((failures + 1)); }
base=
tree; git -C "$tmp" init -q; echo "$sleepline" > "$tmp/Tests/B/b.swift"
expect fail 'no HEAD: the reference is the empty tree' 'Tests/B/b.swift: 1 wall-clock lines, 0 at the empty tree'
# The cap lines.
repo $'mode fail\nTests/B/b.swift\t1'; expect fail 'a cap line with no reason' 'Tests/B/b.swift: a cap line with no reason'
repo $'mode fail\nTests/B/b.swift\tmany\ta reason'; expect fail 'a cap that is no whole number' 'Tests/B/b.swift: the cap many is not a whole number'
stale='Tests/B/b.swift: the cap 3 is over its count 1; lower the cap to 1 or remove the line'
repo $'mode fail\nTests/B/b.swift\t3\ta reason'; expect fail 'a cap over the count of its file' "$stale"
repo $'mode warn\nTests/B/b.swift\t3\ta reason'; expect pass 'a stale cap in mode warn' "warning: $stale"
repo $'mode fail\nTests/B/b.swift\t1\ta reason'; expect pass 'a cap equal to the count of its file'
# The mode.
repo 'mode warn'; more; expect pass 'a rise in mode warn' "warning: Tests/B/b.swift: 2 $rise"
repo $'# the format\n\nmode warn'; more; expect pass 'a comment and a blank line before the mode' "warning: Tests/B/b.swift: 2 $rise"
repo; rm "$tmp/scripts/check-waits.counts"; more; expect fail 'no counts file is mode fail' "Tests/B/b.swift: 2 $rise"
repo '# only a comment'; more; expect fail 'no mode line is mode fail' "Tests/B/b.swift: 2 $rise"
repo $'Tests/B/b.swift\t2\ta reason'; more; expect fail 'a cap line before any mode line is no cap' "Tests/B/b.swift: 2 $rise"
repo 'mode loud'; expect fail 'another mode word' 'scripts/check-waits.counts: the mode is warn or fail'
# A rise of the isIntermittent lines in the Tests/ total fails in each mode, with no cap. A move of a
# line (a rename, a split) keeps the total, so it passes.
intermittent='Tests/: 2 isIntermittent lines, 1 at HEAD; a flaky test moves to the real-time tier (flake-triage.md, Time box)'
repo; flakeline y >> "$tmp/Tests/B/i.swift"; expect fail 'a second isIntermittent line in mode fail' "$intermittent"
repo 'mode warn'; flakeline y >> "$tmp/Tests/B/i.swift"; expect fail 'a second isIntermittent line in mode warn' "$intermittent"
repo $'mode warn\nTests/B/i.swift\t9\ta reason'; flakeline y >> "$tmp/Tests/B/i.swift"; expect fail 'a second isIntermittent line with a cap' "$intermittent"
repo; flakeline z > "$tmp/Tests/B/j.swift"
expect fail 'a new file with an isIntermittent line' "$intermittent"
repo; : > "$tmp/Tests/B/i.swift"; expect pass 'a removed isIntermittent line'
repo; mv "$tmp/Tests/B/i.swift" "$tmp/Tests/B/k.swift"; expect pass 'a renamed file with an isIntermittent line'
repo; flakeline y >> "$tmp/Tests/B/i.swift"; g commit -q -am two
flakeline y > "$tmp/Tests/B/j.swift"; flakeline x > "$tmp/Tests/B/i.swift"; expect pass 'a file with 2 isIntermittent lines split in two files'
flakeline z >> "$tmp/Tests/B/j.swift"; expect fail 'a split that adds a line' 'Tests/: 3 isIntermittent lines, 2 at HEAD;'
repo; flakeline y > "$tmp/Tests/B/j.swift"; : > "$tmp/Tests/B/i.swift"; expect pass 'a line added in one file and removed in another'

# The other quarantine forms are refused the same way, each marker by its own Tests/ total: a
# `"quarantine:` line with a FLAKE word and no isIntermittent, and a `.disabled(` line.
quarantined() { printf '    withKnownIssue("quarantine: %s, FLAKE a") {\n' "$1"; }
disabled() { printf '    @Test(.disabled("%s"))\n' "$1"; }
quarantine='Tests/: 2 "quarantine: lines, 1 at HEAD; a flaky test moves to the real-time tier (flake-triage.md, Time box)'
repo; quarantined y > "$tmp/Tests/B/j.swift"; expect fail 'a new "quarantine: line with a FLAKE word in mode fail' "$quarantine"
repo 'mode warn'; quarantined y > "$tmp/Tests/B/j.swift"; expect fail 'a new "quarantine: line with a FLAKE word in mode warn' "$quarantine"
repo; quarantined y >> "$tmp/Tests/B/i.swift"; expect fail 'a second "quarantine: line in the same file' "$quarantine"
disabledrise='Tests/: 1 .disabled( lines, 0 at HEAD; a new disabled test; move a flaky test to the real-time tier (flake-triage.md), or gate a test with .enabled(if:)'
repo; disabled slow > "$tmp/Tests/B/j.swift"; expect fail 'a new .disabled( line in mode fail' "$disabledrise"
repo 'mode warn'; disabled slow > "$tmp/Tests/B/j.swift"; expect fail 'a new .disabled( line in mode warn' "$disabledrise"
repo; disabled slow > "$tmp/Tests/B/j.swift"; printf '.disabled(' > "$tmp/Tests/B/j.txt"; expect fail 'a .disabled( line beside a file that is not Swift' "$disabledrise"
repo; disabled slow > "$tmp/Sources/A/a.swift"; expect pass 'a .disabled( line outside Tests/'
repo; disabled slow > "$tmp/Tests/B/j.txt"; expect pass 'a .disabled( line in a file that is not Swift'
repo; quarantined y > "$tmp/Tests/B/j.txt"; expect pass 'a "quarantine: line in a file that is not Swift'
repo; disabled slow > "$tmp/Tests/B/d.swift"; g add -A; g commit -q -m disabled
mv "$tmp/Tests/B/d.swift" "$tmp/Tests/B/e.swift"; expect pass 'a renamed file with a .disabled( line'
disabled other >> "$tmp/Tests/B/e.swift"; expect fail 'a second .disabled( line after the rename' 'Tests/: 2 .disabled( lines, 1 at HEAD;'
repo; quarantined y >> "$tmp/Tests/B/i.swift"; g commit -q -am two
quarantined y > "$tmp/Tests/B/j.swift"; flakeline x > "$tmp/Tests/B/i.swift"; expect pass 'a file with 2 "quarantine: lines split in two files'
repo; : > "$tmp/Tests/B/i.swift"; expect pass 'a removed "quarantine: line'
repo; disabled slow > "$tmp/Tests/B/d.swift"; g add -A; g commit -q -m disabled; : > "$tmp/Tests/B/d.swift"; expect pass 'a removed .disabled( line'
repo; g checkout -q -b side; disabled slow > "$tmp/Tests/B/d.swift"; g add -A; g commit -q -m 'side adds a .disabled( line'; side="$(g rev-parse HEAD)"; g checkout -q main
base="$side"; expect pass 'a BASE tip that adds a .disabled( line the branch lacks'
base="$(g rev-parse main)"; disabled slow > "$tmp/Tests/B/d.swift"; expect fail 'BASE the first commit, a .disabled( line in the work tree' "Tests/: 1 .disabled( lines, 0 at merge-base $base;"
base=

# The debug-only member gate: a Tests/ line that names `.<member>` outside `#if DEBUG` fails when
# Sources/ declares the member only in a debug branch. The debug-only member of a tree is `stats`.
stats='    var stats: Int { 1 }'
dbgsrc() { printf 'struct A {\n%s\n%s\n%s\n}\n' "$1" "$stats" "${2:-#endif}" > "$tmp/Sources/A/a.swift"; }
usage() { printf '%b' "$1" > "$tmp/Tests/B/b.swift"; }
use='let n = a.stats\n'
hit() { echo "Tests/B/b.swift:$1: .stats is declared only under #if DEBUG; put the test in #if DEBUG (tdd skill, Guardrails)"; }
tree; dbgsrc '#if DEBUG'; usage "$use"; expect fail 'a test that reads a debug-only member' "$(hit 1)"
tree; dbgsrc '#if DEBUG'; usage "#if DEBUG\n#else\n$use#endif\n"; expect fail 'a use in the #else branch of #if DEBUG' "$(hit 3)"
tree; printf 'struct A {\n#if !DEBUG\n    var other: Int { 0 }\n#else\n%s\n#endif\n}\n' "$stats" > "$tmp/Sources/A/a.swift"
usage "$use"; expect fail 'a member in the #else branch of #if !DEBUG' "$(hit 1)"
tree; dbgsrc '#if DEBUG && os(macOS)'; usage "$use"; expect fail 'a member in #if DEBUG && os(macOS)' "$(hit 1)"
tree; dbgsrc '#if DEBUG'; usage "#if DEBUG\n$use#endif\n"; expect pass 'a use inside #if DEBUG'
tree; dbgsrc '#if DEBUG'; usage "#if os(macOS)\n#if DEBUG\n$use#endif\n#endif\n"; expect pass 'a use inside #if DEBUG nested in another #if'
tree; dbgsrc '#if DEBUG'; usage "#if DEBUG\n#if os(macOS)\n$use#endif\n#endif\n"; expect pass 'a use inside another #if nested in #if DEBUG'
tree; dbgsrc '#if DEBUG'; usage "$use"; printf 'struct C {\n    var stats: Int = 0\n}\n' > "$tmp/Sources/A/c.swift"
expect pass 'a debug-only name that a release declaration also has'
tree; printf 'struct A {\n#if DEBUG\n    private var stats: Int { 1 }\n#endif\n}\n' > "$tmp/Sources/A/a.swift"; usage "$use"
expect pass 'a private debug member'
tree; printf 'struct A {\n#if DEBUG\n    func make() {\n        let stats = 1\n        _ = stats\n    }\n#endif\n}\n' > "$tmp/Sources/A/a.swift"; usage "$use"
expect pass 'a local let in a function body under #if DEBUG'
tree; dbgsrc '#if DEBUG'; usage '// a.stats is debug only\n'; expect pass 'a // line that names the member'
tree; dbgsrc '#if DEBUG'; usage 'let n = 1 // a.stats is debug only\n'; expect pass 'a trailing comment that names the member'
tree; dbgsrc '#if DEBUG'; usage 'let n = "a.stats"; let m = a.statsCount\n'; expect pass 'a string and a longer name'
tree; dbgsrc '#if DEBUG || TESTING'; usage "$use"; expect pass 'a member under #if DEBUG || TESTING'
# The scans read a file list only: with no file in a list they must not read standard input.
tree; echo 'let n = 1' > "$tmp/Sources/A/a.swift"; usage "$use"; feed=$'#if DEBUG\n    var stats: Int { 1 }\n#endif'
expect pass 'a tree with no #if DEBUG in Sources'
tree; dbgsrc '#if DEBUG'; usage 'let n = 1\n'; feed='let n = a.stats'; expect pass 'a test that names no debug-only member'
feed=
# The brace-kind pass: a class func is no type scope, and a regex literal holds no brace.
tree; printf 'struct A {\n#if DEBUG\n    class func make() {\n        let stats = 1\n        _ = stats\n    }\n#endif\n}\n' > "$tmp/Sources/A/a.swift"; usage "$use"
expect pass 'a local let in a class func body under #if DEBUG'
tree; dbgsrc '#if DEBUG'; usage "$use"
printf 'struct C {\n    func parse() {\n        let re = /\\{(\\d+)/\n        _ = re\n    }\n    var stats: Int = 0\n}\n' > "$tmp/Sources/A/c.swift"
expect pass 'a regex literal with an unbalanced brace before a release member'
# In a git work tree the gate runs only when a Swift file under Sources/ or Tests/ differs from the reference.
repo; dbgsrc '#if DEBUG'; usage "$use"; g add -A; g commit -q -m fault
mkdir -p "$tmp/docs"; echo note > "$tmp/docs/a.md"; expect pass 'a docs-only change on a tree that holds the fault'
echo 'let m = 1' >> "$tmp/Tests/B/b.swift"; expect fail 'a changed Tests file on a tree that holds the fault' "$(hit 1)"

[[ $failures -eq 0 ]] && echo "check-waits tests: all passed"
exit $((failures > 0))
