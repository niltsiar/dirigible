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

# A "." segment in the missing part of the folder does not block a write in the folder.
"$probe" "$root/dot/./p" /bin/sh -c 'echo x > a.txt' 2>/dev/null || fail "a write in a folder with a . segment was refused"
[[ -f "$root/dot/p/a.txt" ]] || fail "a write in a folder with a . segment did not land in the folder"

# A write, a delete, and a rename outside the folder are refused.
"$probe" "$root/p" /bin/sh -c "echo x > '$root/outside/b.txt'" 2>/dev/null
[[ -e "$root/outside/b.txt" ]] && fail "a write outside the folder was allowed"
echo keep > "$root/outside/c.txt"
"$probe" "$root/p" /bin/rm -f "$root/outside/c.txt" 2>/dev/null
[[ -f "$root/outside/c.txt" ]] || fail "a delete outside the folder was allowed"
"$probe" "$root/p" /bin/mv "$root/outside/c.txt" "$root/p/c.txt" 2>/dev/null
[[ -f "$root/outside/c.txt" ]] || fail "a rename out of a folder outside was allowed"

# The header names the refusal of a write in /private/tmp outside the folder, and the open
# /private/var/folders (the TMPDIR of the user). A new file in each shows both.
outside_tmp="/private/tmp/probe-test-outside.$$"
err="$("$probe" "$root/p" /bin/sh -c "echo x > '$outside_tmp'" 2>&1)"
[[ ! -e "$outside_tmp" && "$err" == *"Operation not permitted"* ]] || fail "a new file in /private/tmp outside the folder: [$err]"
rm -f "$outside_tmp"
user_tmp="$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)/probe-test-inside.$$"
"$probe" "$root/p" /bin/sh -c "echo x > '$user_tmp'" || fail "a write under /private/var/folders was refused"
[[ -f "$user_tmp" ]] || fail "a write under /private/var/folders did not land"
rm -f "$user_tmp"

# A folder outside .scratchpads/ and /private/tmp is refused before the command runs.
"$probe" "$HOME" /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail "the home folder was accepted as a probe folder"
"$probe" "$root/.." /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail ".scratchpads/ itself was accepted as a probe folder"

# A refused folder that does not exist is not made. A ".." in the missing part cannot leave the
# allowed roots. The mktemp folder is in /private/var/folders, outside the allowed roots.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$root" "$tmp" "/private/tmp/probe-test-missing.$$"' EXIT
"$probe" "$tmp/refused/sub" /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail "a missing folder outside the allowed roots was accepted"
[[ -e "$tmp/refused" ]] && fail "a refused folder was made"
"$probe" "/private/tmp/probe-test-missing.$$/../..${tmp#/private}/escape" /usr/bin/true 2>/dev/null
[[ $? -eq 2 ]] || fail "a .. in a missing folder was accepted"
[[ -e "$tmp/escape" ]] && fail "a .. in a missing folder made a folder outside the allowed roots"

# In a git worktree, a folder in .scratchpads/ of the main checkout is accepted; a folder outside
# both is still refused.
repo="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$root" "$tmp" "/private/tmp/probe-test-missing.$$" "$repo"' EXIT
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

# noAudioHidesTheDevices: with --no-audio, the audio server is out of reach, so no device shows.
# system_profiler reads the devices through the audio server; the hook tests have no dirigible build.
# It prints "no run" when the call did not run system_profiler, so a refused option is no pass.
devices() {
    local out
    out="$("$probe" "$@" /usr/sbin/system_profiler SPAudioDataType 2>/dev/null)" && [[ "$out" == Audio:* ]] \
        || { echo "no run"; return; }
    grep -c 'Manufacturer:' <<<"$out" || true
}
if [[ "$(devices "$root/p")" == 0 ]]; then
    echo "probe: skip noAudioHidesTheDevices: no audio device"
else
    got="$(devices --no-audio "$root/p")"
    [[ "$got" == 0 ]] || fail "noAudioHidesTheDevices: --no-audio gave [$got] audio devices, want 0"
fi
"$probe" --no-audio "$root/p" /bin/sh -c 'echo x > n.txt' || fail "--no-audio refused a write in the folder"
[[ -f "$root/p/n.txt" ]] || fail "--no-audio: a write in the folder did not land"
"$probe" --no-audio "$root/p" /bin/sh -c "echo x > '$root/outside/n.txt'" 2>/dev/null
[[ -e "$root/outside/n.txt" ]] && fail "--no-audio allowed a write outside the folder"

[[ $failures -eq 0 ]] && echo "probe: all cases pass" || exit 1
