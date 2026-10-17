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
# A call that an agent starts directly stops after WITH_LOCK_MAX_WAIT seconds of wait (default 120):
# it prints the limit and "run the same command again", leaves the lock of the holder, and exits
# 75. The default is min(120, 600 - B) with B = 457 s, the worst build plus slice tests of one call
# (an Intel i5-8259U, 8 logical CPUs, 16 GiB, macOS 15), and 600 s the foreground limit of
# .claude/agents/run-agent.md. The wait sleeps the seconds that are left, so the call stops at the
# limit. These calls have no limit: WITH_LOCK_MAX_WAIT=0, a release call (below), a call with the
# DIRIGIBLE_LOCKED_SCRIPT marker (a script that runs itself under this one), and mutation-pass.sh.
# scripts/run-checks.sh and scripts/flake-monitor/loop.sh set the 0, so an exit 75 never reads as
# a red test. loop.sh runs itself under this script with the marker and sets WITH_LOCK_MAX_HOLD.
# Each wait line has the tree of the call as its fifth column (git rev-parse --show-toplevel). At
# its release, a call appends one line to dirigible-build-holds.log in the git common dir: the
# start time, the hold seconds, the command, and the tree. The take writes the tree into the lock
# folder (<lock>/tree), and a waiting call keeps the marker dirigible-build-waiting/<pid> with its
# tree until it takes the lock or ends. scripts/with-lock.sh --builders prints each tree with a wait
# or hold line that ended in the last WITH_LOCK_BUILDERS_MIN minutes (default 60), the tree of the
# live holder, and each live waiter, one per line. A marker of a dead pid is ignored and removed.
# A wait with 2 or more other trees in that list prints their count: the cap of long-runs.md.
# A hold limit stops a command that runs too long: after WITH_LOCK_MAX_HOLD seconds the process
# group of the command gets TERM, then KILL after WITH_LOCK_HOLD_GRACE seconds (default 10), the lock
# goes, the hold line gets the fifth column limit, and the call exits 124. The default is 1800 s. A
# call that has no wait limit (above) gets 2 times the newest push-check hold line (a make
# check-changed BASE= line with no limit column) in the hold log, at least 3600 s. 0 turns the
# limit off. The lock folder keeps the limit in <lock>/maxhold, and --builders ends with the line
# "holder: <tree> held <n> s of <limit> s" while a live call holds the lock.
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
waits="${lock%/*}/dirigible-build-waits.log" holds="${lock%/*}/dirigible-build-holds.log"
waiting="${lock%/*}/dirigible-build-waiting" marker="" min="${WITH_LOCK_BUILDERS_MIN:-60}"
# builders: the trees of the wait and hold lines that ended in the last $min minutes, of the live
# holder, and of each live waiter, one per line. awk reads the ISO times as UTC to add the seconds.
builders() {
    local cutoff m c
    cutoff="$(date -r $(($(date +%s) - min * 60)) +%FT%T)"
    {
        for m in "$waits:5" "$holds:4"; do
            awk -F'\t' -v cutoff="$cutoff" -v col="${m##*:}" '
                function ep(s, y, mo) {
                    y = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0
                    if (mo < 3) { y--; mo += 12 }
                    return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * mo - 457) / 5) + substr(s, 9, 2)) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
                }
                $col != "" && ep($1) + $2 >= ep(cutoff) { print $col }' "${m%:*}" 2>/dev/null
        done
        m="$(cat "$lock/pid" 2>/dev/null)" c="$(cat "$lock/child" 2>/dev/null)"
        if alive "$m" || alive "$c" || alive "-$c"; then cat "$lock/tree" 2>/dev/null; fi
        for m in "$waiting"/*; do
            [[ -f "$m" ]] || continue
            if alive "${m##*/}"; then cat "$m"; else rm -f "$m"; fi
        done
    } | awk 'NF && !seen[$0]++' | sort
}
# holder_line: the live holder, its seconds of hold, and its limit.
holder_line() {
    local m c
    m="$(cat "$lock/pid" 2>/dev/null)" c="$(cat "$lock/child" 2>/dev/null)"
    alive "$m" || alive "$c" || alive "-$c" || return 0
    printf 'holder: %s held %s s' "$(cat "$lock/tree" 2>/dev/null)" "$(($(date +%s) - $(stat -f %m "$lock/pid")))"
    [[ ! -f "$lock/maxhold" ]] || printf ' of %s s' "$(cat "$lock/maxhold")"
    echo
}
[[ "$1" != --builders ]] || { builders; holder_line; exit 0; }
[[ -z "${DIRIGIBLE_BUILD_LOCK:-}" || "$(cat "$lock/pid" 2>/dev/null)" != "$DIRIGIBLE_BUILD_LOCK" ]] || exec "$@"
tree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
max="${WITH_LOCK_MAX_WAIT:-120}"
[[ "$max" =~ ^[0-9]+$ ]] || { echo "with-lock: WITH_LOCK_MAX_WAIT is '$max'; give whole seconds, or 0 for no limit" >&2; exit 2; }
max=$((10#$max))
long=""
if release_call "$@" || [[ -n "${DIRIGIBLE_LOCKED_SCRIPT:-}" || "${1##*/}" == mutation-pass.sh ]]; then max=0; fi
[[ $max -ne 0 ]] || long=1
maxhold="${WITH_LOCK_MAX_HOLD:-}"
if [[ -z "$maxhold" && -z "$long" ]]; then
    maxhold=1800
elif [[ -z "$maxhold" ]]; then
    maxhold="$(awk -F'\t' '$3 ~ /check-changed/ && $3 ~ /BASE=/ && $5 != "limit" { s = $2 } END { s *= 2; print (s < 3600) ? 3600 : s }' "$holds" 2>/dev/null)"
    maxhold="${maxhold:-3600}"
fi
[[ "$maxhold" =~ ^[0-9]+$ ]] || { echo "with-lock: WITH_LOCK_MAX_HOLD is '$maxhold'; give whole seconds, or 0 for no limit" >&2; exit 2; }
maxhold=$((10#$maxhold))
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
        if mkdir -p "$waiting" 2>/dev/null && echo "$tree" > "$waiting/$$" 2>/dev/null; then marker="$waiting/$$"; fi
        trap 'rm -f ${marker:+"$marker"}; [[ -z "$ticket" ]] || rmdir "$ticket" 2>/dev/null' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        others="$(builders | grep -vxF -- "$tree")"
        n="$(printf '%s\n' "$others" | awk 'NF' | wc -l | tr -d ' ')"
        if [[ $n -ge 2 ]]; then
            echo "with-lock: builders in the last $min min: $n ($(printf '%s\n' "$others" | paste -sd, - | sed 's/,/, /g')); the cap is 2 (long-runs.md)" >&2
        fi
    fi
    nap="$retry"
    if [[ $max -gt 0 ]]; then
        left=$((max - ($(date +%s) - start)))
        [[ $left -gt 0 ]] || { echo "with-lock: still waiting after $max s (WITH_LOCK_MAX_WAIT); run the same command again" >&2; exit 75; }
        nap="$(awk -v r="$retry" -v l="$left" 'BEGIN { print (l < r) ? l : r }')"
    fi
    sleep "$nap"
done
[[ -z "$ticket" ]] || rmdir "$ticket" 2>/dev/null
rm -f ${marker:+"$marker"}
# A pid write can fail after the mkdir (a full disk): remove the lock, so no call waits on it.
{ echo $$ > "$lock/pid" && echo "$*" > "$lock/command" && echo "$tree" > "$lock/tree" && echo "$maxhold" > "$lock/maxhold"; } 2>/dev/null ||
    { rm -rf "$lock"; echo "with-lock: cannot write the pid into $lock; check the disk" >&2; exit 2; }
taken="$(date +%s)" cmdline="$*"
[[ -z "$told" ]] || printf '%s\t%s\t%s\t%s\t%s\n' "$(date -r "$start" +%FT%T)" "$((taken - start))" "$cmdline" "$held" "$tree" \
    >> "$waits" 2>/dev/null
child="" watcher=""
release() {
    [[ "$(cat "$lock/pid" 2>/dev/null)" != $$ ]] || {
        [[ -z "$watcher" ]] || kill "$watcher" 2>/dev/null
        printf '%s\t%s\t%s\t%s%s\n' "$(date -r "$taken" +%FT%T)" "$(($(date +%s) - taken))" "$cmdline" "$tree" "$([[ ! -e "$lock/limit" ]] || printf '\tlimit')" >> "$holds" 2>/dev/null
        rm -rf "$lock"
    }
}
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
# The hold limit: the watcher stops the process group of the command (TERM, then KILL after the
# grace time) and marks the lock folder; the call then exits 124. It calls /bin/sleep, so a test that
# puts a fake sleep on the PATH does not see its polls.
if [[ $maxhold -gt 0 ]]; then
    (
        end=$(($(date +%s) + maxhold))
        while kill -0 $$ 2>/dev/null && [[ $(date +%s) -lt $end ]]; do /bin/sleep 1; done
        kill -0 $$ 2>/dev/null || exit 0
        echo limit > "$lock/limit"
        kill -TERM -- "-$child"
        /bin/sleep "${WITH_LOCK_HOLD_GRACE:-10}"
        kill -KILL -- "-$child"
    ) > /dev/null 2>&1 &
    watcher=$!
fi
wait "$child"
status=$?
if [[ -e "$lock/limit" ]]; then
    echo "with-lock: the command ran past WITH_LOCK_MAX_HOLD ($maxhold s); its process group got TERM, then KILL" >&2
    status=124
fi
exit "$status"
