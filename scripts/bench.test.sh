#!/bin/bash
# Check that bench.sh clears the PCH files and the module caches of its copy when the copy was
# built under another root (a .build cloned from another checkout), and keeps them when the root
# is the same. Check that the names join into one filter, that a run with no test exits 1, that a
# bare bench.sh takes the build lock of its repo, and that the benches of one bench-pairs.sh run
# share one hold. A fake swift and a stub check-changed.sh stand in for the build and the load wait.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root" cache="$tmp/root/.build/bench/.build"
mkdir -p "$root/scripts" "$root/Sources/App" "$root/Tests/T" "$tmp/bin"
cp "$here/bench.sh" "$here/bench-pairs.sh" "$here/with-lock.sh" "$root/scripts/"
printf '#!/bin/bash\nexit 0\n' > "$root/scripts/check-changed.sh"
# The fake swift logs its arguments in args.log, and the hold value that it gets and the pid file of
# the lock of the repo in lock.log. With FAKE_NONE=1, its test run prints the two no-test strings
# of test-filter.sh.
export FAKE_PID_FILE="$root/.git/dirigible-build.lock/pid" FAKE_DIR="$tmp" FAKE_NONE=""
cat > "$tmp/bin/swift" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/args.log"
echo "${DIRIGIBLE_BUILD_LOCK:-none} $(cat "$FAKE_PID_FILE" 2>/dev/null || echo free)" >> "$FAKE_DIR/lock.log"
if [[ "$1" == test && -n "$FAKE_NONE" ]]; then
    echo 'No matching test cases were run'
    echo 'Test run with 0 tests passed after 0.001 seconds.' >&2
else
    echo "Test run with 1 test passed"
fi
EOF
chmod +x "$root/scripts/check-changed.sh" "$tmp/bin/swift"
printf '.executableTarget(name: "App")\n' > "$root/Package.swift"
printf '{}\n' > "$root/Package.resolved"
printf '@main\nstruct App {}\n' > "$root/Sources/App/main.swift"
printf 'x\n' > "$root/Tests/T/t.swift"
git -C "$root" init -q && git -C "$root" add -A &&
    git -C "$root" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base

# seed: a PCH file and a module cache in the copy, as a build leaves them.
seed() { mkdir -p "$cache/x/release/ModuleCache" && touch "$cache/x/release/a.pch" "$cache/x/release/ModuleCache/m"; }
run() { PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" X > "$tmp/out" 2>&1 || fail "$1: bench.sh failed: $(cat "$tmp/out")"; }

seed
run "no stamp"
[[ ! -e "$cache/x/release/a.pch" && ! -e "$cache/x/release/ModuleCache" ]] || fail "no stamp: the cache stays"
[[ "$(cat "$cache/dirigible-bench-root" 2>/dev/null)" == "$root/.build/bench" ]] || fail "no stamp: the stamp is not the copy path"

seed
run "the same root"
[[ -e "$cache/x/release/a.pch" && -e "$cache/x/release/ModuleCache/m" ]] || fail "the same root: the cache is gone"

echo /other/root/.build/bench > "$cache/dirigible-bench-root"
run "another root"
[[ ! -e "$cache/x/release/a.pch" && ! -e "$cache/x/release/ModuleCache" ]] || fail "another root: the cache stays"

# Names in one argument (make bench FILTER='A B') or in several join into one filter.
for names in "A B" "A  B"; do
    : > "$tmp/args.log"
    PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" $names > "$tmp/out" 2>&1 || fail "names '$names': bench.sh failed: $(cat "$tmp/out")"
    grep -q -- '--filter A|B$' "$tmp/args.log" || fail "names '$names': no joined filter: $(cat "$tmp/args.log")"
done
: > "$tmp/args.log"
PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" "A B" > "$tmp/out" 2>&1 || fail "one argument: bench.sh failed: $(cat "$tmp/out")"
grep -q -- '--filter A|B$' "$tmp/args.log" || fail "one argument 'A B': no joined filter: $(cat "$tmp/args.log")"

# A test run with both no-test strings ran no test: exit 1, with a line that names the filter.
FAKE_NONE=1 PATH="$tmp/bin:$PATH" "$root/scripts/bench.sh" NoSuchBench > "$tmp/out" 2>&1
code=$?
[[ $code -eq 1 && "$(cat "$tmp/out")" == *'bench: no test matched the filter NoSuchBench'* ]] ||
    fail "no test: exit $code: $(cat "$tmp/out")"

# A bare bench.sh takes the lock of its repo: each swift call gets the value in the pid file.
: > "$tmp/lock.log"
run "lock"
[[ "$(grep -cE '^([0-9]+) \1$' "$tmp/lock.log")" -eq 2 ]] || fail "lock: swift ran with no hold of the lock: $(cat "$tmp/lock.log")"

# One bench-pairs.sh run (an A/A pair and one main/branch pair) holds the lock once: its four
# benches get one value, and it is in the pid file.
: > "$tmp/lock.log"
PATH="$tmp/bin:$PATH" "$root/scripts/bench-pairs.sh" "$root" X 1 "$tmp/pairs" > "$tmp/out" 2>&1 ||
    fail "pairs: bench-pairs.sh failed: $(cat "$tmp/out")"
grep -vqE '^([0-9]+) \1$' "$tmp/lock.log" && fail "pairs: a bench ran with no hold of the lock: $(cat "$tmp/lock.log")"
[[ "$(sort -u "$tmp/lock.log" | wc -l | tr -d ' ')" -eq 1 && "$(wc -l < "$tmp/lock.log" | tr -d ' ')" -eq 8 ]] ||
    fail "pairs: the benches did not share one hold: $(cat "$tmp/lock.log")"

[[ $failures -eq 0 ]] && echo "bench tests: all passed"
exit $((failures > 0))
