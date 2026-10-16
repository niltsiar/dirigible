#!/bin/bash
# Audit the .scratchpads/ paths that a free-model session of OpenCode named in its tool calls,
# against the files that its brief allowed (docs/workflow/model-routing.md, free-job rules).
# Usage: free-lens-reads.sh <session id or run/gate/lens title> <allowed path>...
# One call audits one session: the session id that delegate_task returns, else a title of the form
# <run>/<gate>/<lens> that one session has in the worktree directory (FREE_LENS_WORKTREE, else the
# top folder of the current directory). A session of another directory with that title is not read.
# An allowed path is absolute or relative to .scratchpads/. The script reads the tool inputs only
# (a read path, a shell command and its workdir, a search path, Code Mode code), so a path that a
# tool output quotes does not count. Any other .scratchpads/ path in an input is a failure, also
# the bare folder (a cd into it or a search of it).
# The database is OPENCODE_DB, else the opencode.db of the XDG data folder (OpenCode v2.0.29).
# Exit 0: each path is allowed. Exit 1: it prints each other path. Exit 2: usage, no sqlite3,
# no database, a title that is not <run>/<gate>/<lens>, no session, or two sessions for a title. free-lens-reads.test.sh tests it.
set -euo pipefail

die() { echo "free-lens-reads: $1" >&2; exit 2; }
[[ $# -ge 1 && -n "$1" ]] || die "usage: free-lens-reads.sh <session id or run/gate/lens title> <allowed path>..."
command -v sqlite3 > /dev/null || die "sqlite3 is not installed"
db="${OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
[[ -f "$db" ]] || die "no OpenCode database at $db (set OPENCODE_DB)"
arg="$1"
query="${arg//\'/\'\'}"
shift

# The path under .scratchpads/ with no slash at either end; the bare folder gives an empty text.
rel() {
    local p="$1"
    [[ "$p" == *.scratchpads* ]] && p="${p#*.scratchpads}"
    p="${p#/}"
    p="${p%/}"
    echo "$p"
}
allowed=()
for a in "$@"; do allowed+=("$(rel "$a")"); done
is_allowed() {
    local a
    for a in ${allowed[@]+"${allowed[@]}"}; do [[ "$1" == "$a" && -n "$a" ]] && return 0; done
    return 1
}

sessions="$(sqlite3 -readonly "$db" "select id from session_v2 where id = '$query';")"
if [[ -z "$sessions" ]]; then
    [[ "$arg" =~ ^[^/]+/[^/]+/[^/]+$ ]] || die "no session id '$arg', and it is not a title of the form <run>/<gate>/<lens>"
    worktree="${FREE_LENS_WORKTREE:-$(git rev-parse --show-toplevel)}"
    wt_sql="${worktree//\'/\'\'}"
    sessions="$(sqlite3 -readonly "$db" "select id from session_v2 where title = '$query' and directory = '$wt_sql' order by id;")"
    [[ -n "$sessions" ]] || die "no session with the title '$arg' in $worktree"
    [[ "$(wc -l <<< "$sessions")" -eq 1 ]] || die "two sessions have the title '$arg' in $worktree: audit by the session id"
fi

bad=0
for s in $sessions; do
    calls=0 found=0
    seen=" "
    # One line per tool input: the JSON text keeps a newline of a command as \n.
    while IFS= read -r input; do
        calls=$((calls + 1))
        while IFS= read -r token; do
            [[ -n "$token" ]] || continue
            r="$(rel "$token")"
            is_allowed "$r" && continue
            case "$seen" in *" $r "*) continue ;; esac
            seen+="$r "
            found=1
            echo "free-lens-reads: $s: not allowed: .scratchpads/$r"
            bad=1
        done < <(grep -oE "[^][{}[:space:]\"'\`;|&()<>=,\\\\]*\.scratchpads[^][{}[:space:]\"'\`;|&()<>=,\\\\]*" <<< "$input")
    done < <(sqlite3 -readonly "$db" "select json_extract(p.value, '$.state.input') from session_message m, json_each(m.data, '$.content') p
        where m.session_id = '$s' and m.type = 'assistant' and json_extract(p.value, '$.type') = 'tool';")
    [[ $found -eq 0 ]] && echo "free-lens-reads: $s: clean ($calls tool calls)"
done
exit "$bad"
