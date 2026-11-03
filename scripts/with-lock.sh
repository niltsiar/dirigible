#!/bin/bash
# Run a command while this call holds the shared build lock, so two worktrees never build, test,
# or bench at the same time (a lock-free call, below, takes no lock).
# Usage: scripts/with-lock.sh <command> [<argument>...]
# The lock is the folder <git common dir>/dirigible-build.lock of the repo that holds this script,
# so each worktree sees the same lock. The call takes it with mkdir, writes its pid, runs the
# command as a child, and writes the pid of the child. While another process holds the lock, the
# call prints the holder once and tries again each 30 s (WITH_LOCK_RETRY sets other seconds).
# After a wait, the take appends one line to dirigible-build-waits.log in the git common dir: the
# start time, the wait seconds, the command, and the command of the holder, with tabs between.
# A call that an agent starts directly stops after WITH_LOCK_MAX_WAIT seconds of wait (default 120):
# it prints the limit and "run the same command again", leaves the lock of the holder, and exits
# 75. The default is min(120, 600 - B) = 120 s: B = 457 s, the warm build plus the slice tests of
# one agent call (an Intel i5-8259U, 8 logical CPUs, 16 GiB, macOS 15), and 600 s is the foreground
# limit of .claude/agents/run-agent.md. A cold build with the CWhisper target (612 s build plus 53 s
# slice tests, one run) does not fit the 600 s limit, so a run agent returns it to the lead, which
# runs it in the background (AGENTS.md, Commands). The wait sleeps the seconds that are left, so the
# call stops at the limit. These calls have no limit: WITH_LOCK_MAX_WAIT=0, a release call (below),
# a call with the DIRIGIBLE_LOCKED_SCRIPT marker (a script that runs itself under this one), and
# mutation-pass.sh.
# scripts/flake-monitor/loop.sh sets the 0, and scripts/run-checks.sh sets it for a push check (BASE
# set), so an exit 75 never reads as a red test. A run-checks.sh call with no BASE keeps the limit,
# and ends in exit 75 at it; a lock-free make check-changed call (below) then exits 75 as well.
# loop.sh runs itself under this script with the marker and sets WITH_LOCK_MAX_HOLD.
# Each wait line has the tree of the call as its fifth column (git rev-parse --show-toplevel; for
# mutation-pass.sh, the toplevel of its first argument, the tree that it builds). At
# its release, a call appends one line to dirigible-build-holds.log in the git common dir: the
# start time, the hold seconds, the command, and the tree. The take writes the tree into the lock
# folder (<lock>/tree), and a waiting call keeps the marker dirigible-build-waiting/<pid> with its
# tree until it takes the lock or ends. scripts/with-lock.sh --builders prints each existing tree
# whose hold lines that ended in the last WITH_LOCK_BUILDERS_MIN minutes (default 20: the p90 gap
# between two holds of one tree is 811 s) add up to WITH_LOCK_BUILDERS_FLOOR seconds or more
# (default 10: a hold of a few seconds is a probe, not a build). A wait line, also a lock-free one,
# below, is no sign of a building tree. The list also has the tree of the live holder and each live
# waiter, one per line. A marker of a dead pid is ignored and removed.
# A wait with 2 or more other trees in that list prints their count.
# scripts/with-lock.sh --release-holder takes no lock and runs no command, also inside a locked
# process tree. It prints "holder: <command>" and exits 0 while a release call (below) holds the
# lock with a live pid, child, or child group, or "ticket: <pid>" and exits 0 for a live release
# ticket; else it prints nothing, exits 1, and removes the ticket of a dead pid. A bench, a mutation
# pass, a flake loop, and an ordinary call give exit 1. .claude/hooks/agent-guard.sh calls it.
# The cap: an ordinary call does not take a free lock while 2 or more other trees build. It
# counts the tree of the live holder and the trees of the hold lines in the same window (not a
# waiter, its own tree, a line or a holder of a call with WITH_LOCK_NO_CAP=1, a path that is not a
# folder, or a tree under the floor of the list above). It waits as for a held lock, with the same
# retry, wait limit, and exit 75, and prints once "the cap is 2 building trees" with the trees and
# the minutes until the first of those trees ages out of the list: a tree leaves when its hold
# seconds in the window fall under the floor. A release call, a nested call, and a
# DIRIGIBLE_LOCKED_SCRIPT call skip the cap, and so does WITH_LOCK_NO_CAP=1 (a read-only scan,
# long-runs.md): it waits for the lock as any call, takes no slot, and ends its wait and hold lines
# with the column nocap (the hold line has an empty fifth column unless it has limit). A release
# call also ends its lines with nocap, so a make dmg, a land, or the hooks pass never fills a slot
# of the cap. cost.sh counts those minutes.
# A hold limit stops a command that runs too long: after WITH_LOCK_MAX_HOLD seconds the process
# group of the command gets TERM, then KILL after WITH_LOCK_HOLD_GRACE seconds (default 10), the lock
# goes, the hold line gets the fifth column limit, and the call exits 124. The default is 1800 s. A
# call that has no wait limit (above) gets 2 times the newest push-check hold line (a make
# check-changed BASE= line with no limit column) in the hold log, at least 3600 s. 0 turns the
# limit off. The lock folder keeps the limit in <lock>/maxhold, and --builders ends with the line
# "holder: <tree> held <n> s of <limit> s" while a live call holds the lock.
# A release call (make check-changed with BASE=<ref> as a word, in the environment, or in MAKEFLAGS;
# make test-hooks with DIRIGIBLE_HOOKS_ALL=1 in the same three places; land.sh; make dmg) marks the lock folder with <lock>/release, and holds the ticket folder
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
# A lock-free call takes no lock and writes no hold line, and prints one stderr line
# "with-lock: lock-free targets (<targets>): no lock; it waits while a release call (a push
# check, the hooks pass, a land, or make dmg), a bench, a mutation pass, or a flake loop holds
# the lock". It is make check-changed with no BASE= word and no BASE in the environment or in
# MAKEFLAGS (both make a push check, and so a release call), when scripts/check-changed.sh (with the NAME=value words of the call in its
# environment) gives only check-docs, check-fast, static, lint, format, none, test, test-app,
# test-filter, or a word with =; and make test-hooks with a HOOK_TESTS= word. test, test-filter, and
# test-app take the lock themselves through scripts/swift-test.sh (test-shards.sh holds it once for
# its build and shards) and scripts/bundle.sh, so the outer call holds nothing while the hook tests
# run. A check-changed.sh failure and every other target keep the lock. Exit 3 of check-changed.sh
# (its refusal of a bare run with no changed path and commits past origin/main) runs no command:
# the call prints the output of check-changed.sh and exits 3 at once, with no lock, wait, ticket, or
# log line, also behind a long holder. With no long holder, a lock-free call also writes no wait line and runs at once: it
# does not wait for another build or test. While a release call, a bench, a mutation pass, or a
# flake loop holds the lock (long-runs.md), and, after it waited, while a release call has a live
# ticket in dirigible-build-first/, it waits without taking the lock, under the wait limit above,
# and then runs. That wait keeps no marker and no ticket, and appends one wait line that ends with
# lockfree. cost.sh counts its minutes. A lock-free call runs its command as a child. TERM or INT
# stops the process group of the command. make exits 2 for a recipe that exits 75, so the call exits
# 75 when the command fails and its stderr has the make line "Error 75" of the check-changed target:
# the recipe passes the 75 of scripts/run-checks.sh (a lock wait of a swift-test.sh call over its limit).
# WITH_LOCK_RUN_ONLY=1 makes a call lock-free (targets run-only) for a step that only runs a built
# binary and times nothing: it takes no lock and waits only for a long holder, as above. The call
# skips the leading words env and time (each only when the next word does not start with -), each
# NAME=value word, and probe.sh [--no-audio] <folder>, comparing words by basename. The command
# left must be a built binary (a path under .build/ or build/Dirigible.app/, with no .. part),
# bash <file>, or sh <file>. After a probe.sh word, a built binary must be an absolute path (for
# example "$PWD/.build/debug/dirigible"), because probe.sh changes to its folder first. Any other
# form exits 2 and runs nothing, because the call cannot see inside a wrapper that it does not
# know. It also cannot see the command inside bash <file>, and the command does not inherit the
# variable, so a with-lock.sh call inside it takes the lock as usual.
# The command gets DIRIGIBLE_BUILD_LOCK=<pid of this call>. A call that finds this value in the pid
# file (a nested call, for example swift-test.sh under make test) runs its command at once, and
# does not take, wait for, or remove the lock. A value that is not in the pid file waits as usual.
# cost.sh and wiki.py build nothing: the call exits 2 at once with a message, before any wait, so a
# transcript scan never queues behind a push check (DLV-157).
# scripts/lock-words.sh holds the word rules of the lock-free make call (lock_make_words), push_env,
# hooks_env, and release_call; the guardrail hook reads the same file.
# The guardrail hook blocks each command that names the lock and is not a read.
# scripts/with-lock.test.sh tests it.
set -uo pipefail
[[ $# -ge 1 ]] || { echo "usage: scripts/with-lock.sh <command> [<argument>...]" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$here/lock-words.sh" ]] || { echo "with-lock: $here/lock-words.sh is missing; scripts/with-lock.sh needs scripts/lock-words.sh beside it" >&2; exit 2; }
. "$here/lock-words.sh"
lock="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)/dirigible-build.lock" || exit 2
retry="${WITH_LOCK_RETRY:-30}"
told="" start="$(date +%s)" held=""
# alive <pid>: the process lives. A negative pid names the process group of the command.
alive() { [[ -n "$1" ]] && kill -0 -- "$1" 2>/dev/null; }
waits="${lock%/*}/dirigible-build-waits.log" holds="${lock%/*}/dirigible-build-holds.log"
waiting="${lock%/*}/dirigible-build-waiting" marker="" min="${WITH_LOCK_BUILDERS_MIN:-20}" floor="${WITH_LOCK_BUILDERS_FLOOR:-10}"
# The awk function ep reads a local ISO time as UTC, to add the seconds of a log line.
ep_awk='
    function ep(s, y, mo) {
        y = substr(s, 1, 4) + 0; mo = substr(s, 6, 2) + 0
        if (mo < 3) { y--; mo += 12 }
        return (365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * mo - 457) / 5) + substr(s, 9, 2)) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60 + substr(s, 18, 2)
    }'
# builders: the existing trees whose hold lines that ended in the last $min minutes add up to $floor
# seconds or more, the live holder, and each live waiter, one per line.
builders() {
    local cutoff m c
    cutoff="$(date -r $(($(date +%s) - min * 60)) +%FT%T)"
    {
        awk -F'\t' -v cutoff="$cutoff" -v floor="$floor" "$ep_awk"'
            $4 != "" && ep($1) + $2 >= ep(cutoff) { sum[$4] += $2 }
            END { for (t in sum) if (sum[t] >= floor) print t }' "$holds" 2>/dev/null |
            while IFS= read -r m; do if [[ -d "$m" ]]; then echo "$m"; fi; done
        m="$(cat "$lock/pid" 2>/dev/null)" c="$(cat "$lock/child" 2>/dev/null)"
        if alive "$m" || alive "$c" || alive "-$c"; then cat "$lock/tree" 2>/dev/null; fi
        for m in "$waiting"/*; do
            [[ -f "$m" ]] || continue
            if alive "${m##*/}"; then cat "$m"; else rm -f "$m"; fi
        done
    } | awk 'NF && !seen[$0]++' | sort
}
# capped: succeeds when 2 or more other trees build (the cap), and sets cap_line. The live holder
# comes first, then the trees of the hold lines in the order in which they age out. A tree ages out
# at the first line end after which its later hold seconds in the window are under the floor, or at
# the end of its last line (at floor 0 no sum is under the floor).
capped() {
    local cutoff m c t secs trees="" soon="" aged="" live="" n=0 input
    cutoff="$(date -r $(($(date +%s) - min * 60)) +%FT%T)"
    m="$(cat "$lock/pid" 2>/dev/null)" c="$(cat "$lock/child" 2>/dev/null)" t="$(cat "$lock/tree" 2>/dev/null)"
    if [[ -n "$t" && ! -e "$lock/nocap" ]] && { alive "$m" || alive "$c" || alive "-$c"; }; then live="$t"; fi
    input="$(
        [[ -z "$live" ]] || printf '0\t%s\n' "$live"
        awk -F'\t' -v cutoff="$cutoff" -v floor="$floor" "$ep_awk"'
            $4 != "" && $6 != "nocap" && ep($1) + $2 >= ep(cutoff) { t = $4; k = ++n[t]; e[t, k] = ep($1) + $2; s[t, k] = $2; sum[t] += $2 }
            END {
                for (t in n) {
                    if (sum[t] < floor) continue
                    for (i = 2; i <= n[t]; i++) {
                        ee = e[t, i]; ss = s[t, i]
                        for (j = i - 1; j >= 1 && e[t, j] > ee; j--) { e[t, j + 1] = e[t, j]; s[t, j + 1] = s[t, j] }
                        e[t, j + 1] = ee; s[t, j + 1] = ss
                    }
                    rest = sum[t]
                    for (i = 1; i <= n[t]; i++) { rest -= s[t, i]; if (rest < floor) break }
                    print e[t, (i > n[t]) ? n[t] : i] - ep(cutoff) "\t" t
                }
            }' "$holds" 2>/dev/null | sort -n
    )"
    while IFS=$'\t' read -r secs t; do
        [[ -n "$t" && "$t" != "$tree" && -d "$t" ]] || continue
        ! grep -qxF -- "$t" <<<"$trees" || continue
        trees+="${trees:+$'\n'}$t" n=$((n + 1))
        [[ -n "$aged" || "$t" == "$live" ]] || { aged="$t" soon="$secs"; }
    done <<<"$input"
    [[ $n -ge 2 ]] || return 1
    secs=$(((soon + 59) / 60))
    cap_line="with-lock: the cap is 2 building trees: $(paste -sd, - <<<"$trees" | sed 's/,/, /g'); $((secs > 0 ? secs : 1)) min until $aged ages out"
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
first="${lock%/*}/dirigible-build-first"
# release_holder: the --release-holder query (header).
release_holder() {
    local m c t
    m="$(cat "$lock/pid" 2>/dev/null)" c="$(cat "$lock/child" 2>/dev/null)"
    if [[ -e "$lock/release" ]] && { alive "$m" || alive "$c" || alive "-$c"; }; then
        echo "holder: $(cat "$lock/command" 2>/dev/null)"
        return 0
    fi
    for t in "$first"/*; do
        [[ -d "$t" ]] || continue
        if alive "${t##*/}"; then echo "ticket: ${t##*/}"; return 0; fi
        rmdir "$t" 2>/dev/null
    done
    return 1
}
[[ "$1" != --release-holder ]] || { release_holder; exit; }
case "${1##*/}" in
    cost.sh | wiki.py)
        echo "with-lock: $1 builds nothing and needs no lock; run it without scripts/with-lock.sh (DLV-157: work that builds nothing may run beside a push check)" >&2
        exit 2 ;;
esac
[[ -z "${DIRIGIBLE_BUILD_LOCK:-}" || "$(cat "$lock/pid" 2>/dev/null)" != "$DIRIGIBLE_BUILD_LOCK" ]] || exec "$@"
tree="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# A mutation pass builds the tree of its first argument, whatever the working directory is.
if [[ "${1##*/}" == mutation-pass.sh && $# -ge 2 ]]; then tree="$(git -C "$2" rev-parse --show-toplevel 2>/dev/null || echo "$tree")"; fi
# ahead: the ticket of a live release call other than this one. A ticket of a dead pid goes.
ticket=""
ahead() {
    local t
    for t in "$first"/*; do
        [[ -d "$t" && "${t##*/}" != $$ ]] || continue
        alive "${t##*/}" && return 0
        rmdir "$t" 2>/dev/null
    done
    return 1
}
# run_only <command>: the mode WITH_LOCK_RUN_ONLY=1 (header). It skips the leading words env and time
# (each only when the next word does not start with -), NAME=value, and probe.sh [--no-audio]
# <folder>, compared by basename. The command left must be a built binary (a path under .build/
# or build/Dirigible.app/), bash <file>, or sh <file>; after a probe.sh word, a built binary must
# be an absolute path, because probe.sh changes to its folder first. Any other form exits 2 and
# runs nothing, because the call cannot see inside a wrapper that it does not know.
run_only() {
    local c probed="" built=""
    while [[ $# -gt 0 ]]; do
        case "${1##*/}" in
            env | time) [[ $# -ge 2 && "$2" != -* ]] || break ;;
            probe.sh) shift; probed=1; [[ "${1:-}" != --no-audio ]] || shift; [[ $# -ge 1 ]] || break ;;
            *) [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break ;;
        esac
        shift
    done
    c="${1:-}"
    case "/$c/" in */../*) c="" ;; esac
    if [[ -n "$probed" ]]; then
        case "$c" in /*/.build/?* | /*/build/Dirigible.app/?*) built=1 ;; esac
    else
        case "$c" in .build/?* | build/Dirigible.app/?* | */.build/?* | */build/Dirigible.app/?*) built=1 ;; esac
    fi
    [[ -n "$built" ]] || case "${c##*/}" in
        bash | sh) [[ $# -ge 2 && "$2" != -* ]] || c="" ;;
        *) c="" ;;
    esac
    [[ -n "$c" ]] || {
        echo "with-lock: WITH_LOCK_RUN_ONLY=1 runs a built binary (a path under .build/ or build/Dirigible.app/), bash <file>, or sh <file>, after the words env, time, NAME=value, and probe.sh [--no-audio] <folder>; after probe.sh, a built binary needs an absolute path; it runs nothing else" >&2
        exit 2
    }
    free_targets=run-only
    unset WITH_LOCK_RUN_ONLY
}
# lock_free <command>: succeeds, and sets free_targets, for a call that builds no Swift, or whose
# Swift calls take the lock themselves (the header lists them). Any other command, goal, or
# check-changed.sh failure is not lock-free (fail closed), except status 3 of check-changed.sh: it
# prints the output and exits 3 at once.
lock_free() {
    local w out="" status=0
    if [[ "${WITH_LOCK_RUN_ONLY:-}" == 1 ]]; then run_only "$@"; return; fi
    lock_make_words "$@" || return 1
    case "$lock_goal" in
        test-hooks) free_targets=test-hooks ;;
        check-changed)
            out="$(env ${lock_assign[@]+"${lock_assign[@]}"} "$here/check-changed.sh" 2>&1)" || status=$?
            [[ $status -ne 3 ]] || { echo "$out" >&2; exit 3; }
            [[ $status -eq 0 ]] || return 1
            free_targets="$(sed -n 's/^targets: //p' <<<"$out")"
            [[ -n "$free_targets" ]] || return 1
            for w in $free_targets; do
                case "$w" in check-docs | check-fast | static | lint | format | none | test | test-app | test-filter | *=*) ;; *) return 1 ;; esac
            done
            ;;
    esac
}
# long_holder: succeeds while a live holder runs a release call, a bench, a mutation pass, or a
# flake loop (long-runs.md): a lock-free call still waits for it.
long_holder() {
    local m c cmd w words make=""
    m="$(cat "$lock/pid" 2>/dev/null)" c="$(cat "$lock/child" 2>/dev/null)"
    alive "$m" || alive "$c" || alive "-$c" || return 1
    [[ ! -e "$lock/release" ]] || return 0
    cmd="$(cat "$lock/command" 2>/dev/null)"
    case "$cmd" in
        *check-changed*BASE=* | *land.sh* | *bench.sh* | *bench-pairs.sh* | *mutation-pass.sh* | *flake-monitor/loop.sh*) return 0 ;;
    esac
    # The goal bench or dmg of make, also after a NAME=value word (make bench FILTER=X, make FILTER=X bench).
    read -ra words <<<"$cmd"
    for w in ${words[@]+"${words[@]}"}; do
        if [[ "${w##*/}" == make ]]; then make=1; elif [[ -n "$make" && ($w == bench || $w == dmg) ]]; then return 0; fi
    done
    return 1
}
# wait_limit <command>: sets max (seconds of wait before exit 75, 0 for none) and uncapped.
uncapped=""
wait_limit() {
    max="${WITH_LOCK_MAX_WAIT:-120}"
    [[ "$max" =~ ^[0-9]+$ ]] || { echo "with-lock: WITH_LOCK_MAX_WAIT is '$max'; give whole seconds, or 0 for no limit" >&2; exit 2; }
    max=$((10#$max))
    if release_call "$@" || [[ -n "${DIRIGIBLE_LOCKED_SCRIPT:-}" || "${1##*/}" == mutation-pass.sh ]]; then max=0 uncapped=1; fi
}
# pause: sleeps one retry, cut to the seconds that are left of the wait limit; at the limit it exits 75.
pause() {
    local left nap="$retry"
    if [[ $max -gt 0 ]]; then
        left=$((max - ($(date +%s) - start)))
        [[ $left -gt 0 ]] || { echo "with-lock: still waiting after $max s (WITH_LOCK_MAX_WAIT); run the same command again" >&2; exit 75; }
        nap="$(awk -v r="$retry" -v l="$left" 'BEGIN { print (l < r) ? l : r }')"
    fi
    sleep "$nap"
}
# run_lock_free <command>: runs the command with no lock, as a child with its own process group,
# and exits with its status, or with 75 for the make line "Error 75" (see the header).
free_child=""
stop_free() { [[ -z "$free_child" ]] || { kill -TERM -- "-$free_child" 2>/dev/null; wait "$free_child"; }; exit "$1"; }
run_lock_free() {
    local err status
    err="$(mktemp)"
    trap 'rm -f "$err"' EXIT
    trap 'stop_free 130' INT
    trap 'stop_free 143' TERM
    set -m
    (set +m; "$@" 2>&1 >&3 3>&- | tee "$err" >&2 3>&-; exit "${PIPESTATUS[0]}") 3>&1 <&0 &
    free_child=$!
    set +m
    wait "$free_child"
    status=$?
    if [[ $status -ne 0 ]] && grep -qE '^[A-Za-z0-9_./-]+(\[[0-9]+\])?: \*\*\* \[check-changed\] Error 75$' "$err"; then exit 75; fi
    exit "$status"
}
# A lock-free call that starts behind a long holder waits here, with no lock, marker, or ticket,
# until one poll finds no long holder and no live ticket of a release call.
free_targets=""
if lock_free "$@"; then
    if long_holder; then
        wait_limit "$@"
        held="$(cat "$lock/command" 2>/dev/null)"
        echo "with-lock: $lock is held by pid $(cat "$lock/pid" 2>/dev/null) ($held); retry each $retry s" >&2
        while long_holder || ahead; do pause; done
        printf '%s\t%s\t%s\t%s\t%s\tlockfree\n' "$(date -r "$start" +%FT%T)" "$(($(date +%s) - start))" "$*" "$held" "$tree" >> "$waits" 2>/dev/null
    fi
    echo "with-lock: lock-free targets ($free_targets): no lock; it waits while a release call (a push check, the hooks pass, a land, or make dmg), a bench, a mutation pass, or a flake loop holds the lock" >&2
    run_lock_free "$@"
fi
wait_limit "$@"
long="" nocap=""
! release_call "$@" || nocap=1
[[ "${WITH_LOCK_NO_CAP:-}" != 1 ]] || nocap=1 uncapped=1
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
capsaid=""
while :; do
    blocked=""
    [[ -n "$uncapped" ]] || ! capped || blocked=1
    if [[ -z "$blocked" ]] && { [[ -n "$ticket" ]] || ! ahead; }; then
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
        elif [[ -z "$blocked" ]]; then
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
    if [[ -n "$blocked" && -z "$capsaid" ]]; then echo "$cap_line" >&2; capsaid=1; fi
    pause
done
[[ -z "$ticket" ]] || rmdir "$ticket" 2>/dev/null
rm -f ${marker:+"$marker"}
# A pid write can fail after the mkdir (a full disk): remove the lock, so no call waits on it.
{ echo $$ > "$lock/pid" && echo "$*" > "$lock/command" && echo "$tree" > "$lock/tree" && echo "$maxhold" > "$lock/maxhold" &&
    { [[ -z "$nocap" ]] || : > "$lock/nocap"; } && { ! release_call "$@" || : > "$lock/release"; }; } 2>/dev/null ||
    { rm -rf "$lock"; echo "with-lock: cannot write the pid into $lock; check the disk" >&2; exit 2; }
taken="$(date +%s)" cmdline="$*"
[[ -z "$told" ]] || printf '%s\t%s\t%s\t%s\t%s%s\n' "$(date -r "$start" +%FT%T)" "$((taken - start))" "$cmdline" "$held" "$tree" "${nocap:+$'\tnocap'}" \
    >> "$waits" 2>/dev/null
child="" watcher=""
release() {
    local extra=""
    [[ "$(cat "$lock/pid" 2>/dev/null)" != $$ ]] || {
        [[ -z "$watcher" ]] || kill "$watcher" 2>/dev/null
        [[ ! -e "$lock/limit" ]] || extra=$'\tlimit'
        [[ -z "$nocap" ]] || extra="${extra:-$'\t'}"$'\tnocap'
        printf '%s\t%s\t%s\t%s%s\n' "$(date -r "$taken" +%FT%T)" "$(($(date +%s) - taken))" "$cmdline" "$tree" "$extra" >> "$holds" 2>/dev/null
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
