#!/bin/bash
# Check that bench.sh clears the PCH files and the module caches of its copy when the copy was
# built under another root (a .build cloned from another checkout), and keeps them when the root
# is the same. A fake swift and a stub check-changed.sh stand in for the build and the load wait.
# Run by scripts/bench-pairs.test.sh, which make test-hooks runs.
set -uo pipefail
bench="$(cd "$(dirname "$0")" && pwd)/bench.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

root="$tmp/root" cache="$tmp/root/.build/bench/.build"
mkdir -p "$root/scripts" "$root/Sources/App" "$root/Tests/T" "$tmp/bin"
cp "$bench" "$root/scripts/bench.sh"
printf '#!/bin/bash\nexit 0\n' > "$root/scripts/check-changed.sh"
printf '#!/bin/bash\necho "Test run with 1 test passed"\n' > "$tmp/bin/swift"
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

[[ $failures -eq 0 ]] && echo "bench tests: all passed"
exit $((failures > 0))
