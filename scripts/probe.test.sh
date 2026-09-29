#!/bin/bash
# Check that probe.sh keeps the writes of a probe in its folder. Run by `make check`.
set -uo pipefail
probe="$(cd "$(dirname "$0")" && pwd -P)/probe.sh"
root="$(cd "$(dirname "$0")/.." && pwd -P)/.scratchpads/probe-test.$$"
failures=0
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/outside"

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A relative path lands in the probe folder.
"$probe" "$root/p" /bin/sh -c 'echo x > a.txt' || fail "a write in the folder was refused"
[[ -f "$root/p/a.txt" ]] || fail "a relative write did not land in the folder"

# A write, a delete, and a rename outside the folder are refused.
"$probe" "$root/p" /bin/sh -c "echo x > '$root/outside/b.txt'" 2>/dev/null
[[ -e "$root/outside/b.txt" ]] && fail "a write outside the folder was allowed"
echo keep > "$root/outside/c.txt"
"$probe" "$root/p" /bin/rm -f "$root/outside/c.txt" 2>/dev/null
[[ -f "$root/outside/c.txt" ]] || fail "a delete outside the folder was allowed"
"$probe" "$root/p" /bin/mv "$root/outside/c.txt" "$root/p/c.txt" 2>/dev/null
[[ -f "$root/outside/c.txt" ]] || fail "a rename out of a folder outside was allowed"

# A folder outside .scratchpads/ and /private/tmp is refused before the command runs.
"$probe" "$HOME" /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail "the home folder was accepted as a probe folder"
"$probe" "$root/.." /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail ".scratchpads/ itself was accepted as a probe folder"

# In a git worktree, a folder in .scratchpads/ of the main checkout is accepted; a folder outside
# both is still refused.
repo="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$root" "$repo"' EXIT
mkdir -p "$repo/main/scripts"
cp "$probe" "$repo/main/scripts/"
git -C "$repo/main" init -q
git -C "$repo/main" add scripts
git -C "$repo/main" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m t
git -C "$repo/main" worktree add -q --detach "$repo/wt" 2>/dev/null
"$repo/wt/scripts/probe.sh" "$repo/main/.scratchpads/run/p" /usr/bin/true \
    || fail "a worktree refused a folder in .scratchpads/ of the main checkout"
"$repo/wt/scripts/probe.sh" "$repo/main/build/p" /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail "a worktree accepted a folder of the main checkout outside .scratchpads/"

[[ $failures -eq 0 ]] && echo "probe: all cases pass" || exit 1
