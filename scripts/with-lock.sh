#!/bin/bash
# Run a command while this call holds the shared build lock, so two worktrees never build, test,
# or bench at the same time.
# Usage: scripts/with-lock.sh <command> [<argument>...]
# The lock is the folder <git common dir>/dirigible-build.lock of the repo that holds this script,
# so each worktree sees the same lock. The call takes it with mkdir, writes its pid, runs the
# command as a child, and writes the pid of the child. While another process holds the lock, the
# call prints the holder once and tries again each 30 s (WITH_LOCK_RETRY sets other seconds).
# After a wait, the take appends one line to dirigible-build-waits.log in the git common dir: the
# start time, the wait seconds, the command, and the command of the holder, with tabs between.
# A release call (make check-changed BASE=<ref>, land.sh, make dmg) holds the ticket folder
# dirigible-build-first/<pid> of the git common dir while it waits, and its trap removes it. An
# ordinary call does not take the lock while a ticket of a live pid is there, so a release call
# that starts later still runs first. A ticket of a dead pid does not block.
# When the call, the child, and the process group of the child are all dead, one waiter at a time
# (the folder <lock>.reap) reads the pid again and takes the lock over. A lock with no pid file is
# held. A mkdir that fails with no lock folder (a sandbox, a full disk) three times in a row (a
# holder that removes the folder just after one failed mkdir gets a new try), a reap mkdir that fails
# in a git dir with no write (a dead holder seen from scripts/probe.sh), or a pid write that fails,
# exits 2 and leaves no lock. Only after its own take does the call set the trap that removes the
# lock, and the trap removes it only while the pid file holds this pid: a call that stops while it
# waits never removes the lock of another process. INT or TERM stops the process group of the
# command first. The call exits with the status of the command.
# The command gets DIRIGIBLE_BUILD_LOCK=<pid of this call>. A call that finds this value in the pid
# file (a nested call, for example swift-test.sh under make test) runs its command at once, and
# does not take, wait for, or remove the lock. A value that is not in the pid file waits as usual.
# The guardrail hook blocks each command that names the lock and is not a read.
# scripts/with-lock.test.sh tests it.
set -uo pipefail
[[ $# -ge 1 ]] || { echo "usage: scripts/with-lock.sh <command> [<argument>...]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
lock="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)/dirigible-build.lock" || exit 2
retry="${WITH_LOCK_RETRY:-30}"
told="" start="$(date +%s)" held=""
# alive <pid>: the process lives. A negative pid names the process group of the command.
alive() { [[ -n "$1" ]] && kill -0 -- "$1" 2>/dev/null; }
[[ -z "${DIRIGIBLE_BUILD_LOCK:-}" || "$(cat "$lock/pid" 2>/dev/null)" != "$DIRIGIBLE_BUILD_LOCK" ]] || exec "$@"
# release_call <command>: a push check (make check-changed BASE=<ref>), a land (land.sh), or a DMG
# build (make dmg).
release_call() {
    local w goal="" base=""
    [[ "${1##*/}" == land.sh ]] && return 0
    [[ "${1##*/}" == make ]] || return 1
    for w in "${@:2}"; do
        case "$w" in BASE=?*) base=1 ;; dmg) goal=dmg ;; check-changed) [[ $goal == dmg ]] || goal=check ;; esac
    done
    [[ $goal == dmg || ($goal == check && -n $base) ]]
}
# ahead: the ticket of a live release call other than this one. A ticket of a dead pid goes.
first="${lock%/*}/dirigible-build-first" ticket=""
ahead() {
    local t
    for t in "$first"/*; do
        [[ -d "$t" && "${t##*/}" != $$ ]] || continue
        alive "${t##*/}" && return 0
        rmdir "$t" 2>/dev/null
    done
    return 1
}
if release_call "$@" && mkdir -p "$first/$$" 2>/dev/null; then
    ticket="$first/$$"
    trap 'rmdir "$ticket" 2>/dev/null' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
while :; do
    if [[ -n "$ticket" ]] || ! ahead; then
        made="" busy=""
        # A holder can remove the folder after the mkdir of this call failed: try again.
        for _ in 1 2 3; do
            mkdir "$lock" 2>/dev/null && { made=1; break; }
            [[ ! -d "$lock" ]] || { busy=1; break; }
        done
        [[ -z "$made" ]] || break
        [[ -n "$busy" ]] || { echo "with-lock: cannot make $lock; run with-lock.sh outside scripts/probe.sh, and check the disk" >&2; exit 2; }
    fi
    pid="$(cat "$lock/pid" 2>/dev/null)" child="$(cat "$lock/child" 2>/dev/null)"
    if [[ -n "$pid" ]] && ! alive "$pid" && ! alive "$child" && ! alive "-$child"; then
        if mkdir "$lock.reap" 2>/dev/null; then
            if [[ "$(cat "$lock/pid" 2>/dev/null)" == "$pid" ]]; then
                rm -rf "$lock" || { rmdir "$lock.reap"; echo "with-lock: cannot remove the dead lock $lock" >&2; exit 2; }
                echo "with-lock: took over the lock of the dead pid $pid" >&2
            fi
            rmdir "$lock.reap"
            continue
        fi
        [[ -w "${lock%/*}" ]] || { echo "with-lock: cannot reap the lock of the dead pid $pid; run with-lock.sh outside scripts/probe.sh, and check the disk" >&2; exit 2; }
    fi
    if [[ -z "$told" ]]; then
        held="$(cat "$lock/command" 2>/dev/null)"
        if [[ -d "$lock" ]]; then
            echo "with-lock: $lock is held by pid ${pid:-unknown (no pid file)} ($held); retry each $retry s" >&2
        else
            echo "with-lock: a push check, a land, or a DMG build takes $lock first; retry each $retry s" >&2
        fi
        told=1
    fi
    sleep "$retry"
done
[[ -z "$ticket" ]] || rmdir "$ticket" 2>/dev/null
# A pid write can fail after the mkdir (a full disk): remove the lock, so no call waits on it.
{ echo $$ > "$lock/pid" && echo "$*" > "$lock/command"; } 2>/dev/null ||
    { rm -rf "$lock"; echo "with-lock: cannot write the pid into $lock; check the disk" >&2; exit 2; }
[[ -z "$told" ]] || printf '%s\t%s\t%s\t%s\n' "$(date -r "$start" +%FT%T)" "$(($(date +%s) - start))" "$*" "$held" \
    >> "${lock%/*}/dirigible-build-waits.log" 2>/dev/null
child=""
release() { [[ "$(cat "$lock/pid" 2>/dev/null)" != $$ ]] || rm -rf "$lock"; }
# The TERM goes to the process group of the command: make sends it only to its recipe shell.
stop() { [[ -z "$child" ]] || { kill -TERM -- "-$child" 2>/dev/null; wait "$child"; }; exit "$1"; }
trap release EXIT
trap 'stop 130' INT
trap 'stop 143' TERM
export DIRIGIBLE_BUILD_LOCK=$$
# A child in the background, so a signal reaches the trap while the command runs. Job control
# (set -m) gives it its own process group, which a TERM and the takeover check can name.
set -m
"$@" <&0 &
child=$!
set +m
echo "$child" > "$lock/child"
wait "$child"
