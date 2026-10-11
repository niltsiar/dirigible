#!/bin/bash
# Run a command while this call holds the shared build lock, so two worktrees never build, test,
# or bench at the same time.
# Usage: scripts/with-lock.sh <command> [<argument>...]
# The lock is the folder <git common dir>/dirigible-build.lock of the repo that holds this script,
# so each worktree sees the same lock. The call takes it with mkdir, writes its pid, runs the
# command as a child, and writes the pid of the child. While another process holds the lock, the
# call prints the holder once and tries again each 30 s (WITH_LOCK_RETRY sets other seconds).
# When the call, the child, and the process group of the child are all dead, one waiter at a time
# (the folder <lock>.reap) reads the pid again and takes the lock over. A lock with no pid file is
# held. A mkdir that fails with no lock folder (a sandbox, a full disk), or a pid write that fails,
# exits 2 and leaves no lock. Only after its own take does the call set the trap that removes the
# lock, and the trap removes it only while the pid file holds this pid: a call that stops while it
# waits never removes the lock of another process. INT or TERM stops the process group of the
# command first. The call exits with the status of the command.
# The guardrail hook blocks each command that names the lock and is not a read.
# scripts/with-lock.test.sh tests it.
set -uo pipefail
[[ $# -ge 1 ]] || { echo "usage: scripts/with-lock.sh <command> [<argument>...]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
lock="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)/dirigible-build.lock" || exit 2
retry="${WITH_LOCK_RETRY:-30}"
told=""
# alive <pid>: the process lives. A negative pid names the process group of the command.
alive() { [[ -n "$1" ]] && kill -0 -- "$1" 2>/dev/null; }
until mkdir "$lock" 2>/dev/null; do
    [[ -d "$lock" ]] || { echo "with-lock: cannot make $lock; run with-lock.sh outside scripts/probe.sh, and check the disk" >&2; exit 2; }
    pid="$(cat "$lock/pid" 2>/dev/null)" child="$(cat "$lock/child" 2>/dev/null)"
    if [[ -n "$pid" ]] && ! alive "$pid" && ! alive "$child" && ! alive "-$child" && mkdir "$lock.reap" 2>/dev/null; then
        if [[ "$(cat "$lock/pid" 2>/dev/null)" == "$pid" ]]; then
            rm -rf "$lock" || { rmdir "$lock.reap"; echo "with-lock: cannot remove the dead lock $lock" >&2; exit 2; }
            echo "with-lock: took over the lock of the dead pid $pid" >&2
        fi
        rmdir "$lock.reap"
        continue
    fi
    if [[ -z "$told" ]]; then
        echo "with-lock: $lock is held by pid ${pid:-unknown (no pid file)} ($(cat "$lock/command" 2>/dev/null)); retry each $retry s" >&2
        told=1
    fi
    sleep "$retry"
done
# A pid write can fail after the mkdir (a full disk): remove the lock, so no call waits on it.
{ echo $$ > "$lock/pid" && echo "$*" > "$lock/command"; } 2>/dev/null ||
    { rm -rf "$lock"; echo "with-lock: cannot write the pid into $lock; check the disk" >&2; exit 2; }
child=""
release() { [[ "$(cat "$lock/pid" 2>/dev/null)" != $$ ]] || rm -rf "$lock"; }
# The TERM goes to the process group of the command: make sends it only to its recipe shell.
stop() { [[ -z "$child" ]] || { kill -TERM -- "-$child" 2>/dev/null; wait "$child"; }; exit "$1"; }
trap release EXIT
trap 'stop 130' INT
trap 'stop 143' TERM
# A child in the background, so a signal reaches the trap while the command runs. Job control
# (set -m) gives it its own process group, which a TERM and the takeover check can name.
set -m
"$@" <&0 &
child=$!
set +m
echo "$child" > "$lock/child"
wait "$child"
