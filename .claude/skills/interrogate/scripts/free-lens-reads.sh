#!/bin/bash
# Audit what a free-model session of OpenCode did, against the files that its brief allowed
# (docs/workflow/model-routing.md, free-job rules).
# Usage: free-lens-reads.sh <session id or run/gate/lens title> <allowed path>...
# One call audits one session: the session id that delegate_task returns, else a title of the form
# <run>/<gate>/<lens> that one session has in the worktree directory (FREE_LENS_WORKTREE, else the
# top folder of the current directory). A session of another directory with that title is not read.
# An allowed path is absolute or relative to .scratchpads/. The script reads the tool inputs only
# (a read path, a shell command and its workdir, a search path, Code Mode code), so a path that a
# tool output quotes does not count. These are failures:
# - Any other .scratchpads/ path in an input, also the bare folder (a cd into it or a search of it).
# - A session that starts in the main checkout, or an input that names its path (FREE_LENS_MAIN,
#   else the first entry of `git worktree list`). A session starts in the run worktree, where
#   .scratchpads/ holds only the brief files, so a search of the worktree cannot reach a review.
# - A shell search that skips .gitignore or goes to a root folder: rg -uu, rg --no-ignore,
#   rg --hidden with a root path (/, ~, $HOME, ..), and a recursive grep with no path.
# The database is OPENCODE_DB, else the opencode.db of the XDG data folder (OpenCode v2.0.29).
# Exit 0: each path is allowed. Exit 1: it prints each failure. Exit 2: usage, no sqlite3, no
# database, no main checkout, a title that is not <run>/<gate>/<lens>, no session, or two sessions
# for a title. free-lens-reads.test.sh tests it.
set -euo pipefail

die() { echo "free-lens-reads: $1" >&2; exit 2; }
[[ $# -ge 1 && -n "$1" ]] || die "usage: free-lens-reads.sh <session id or run/gate/lens title> <allowed path>..."
command -v sqlite3 > /dev/null || die "sqlite3 is not installed"
db="${OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
[[ -f "$db" ]] || die "no OpenCode database at $db (set OPENCODE_DB)"
arg="$1"
query="${arg//\'/\'\'}"
shift
main="${FREE_LENS_MAIN:-$(git worktree list --porcelain 2> /dev/null | sed -n 's/^worktree //;1p')}"
[[ -n "$main" ]] || die "cannot find the main checkout (set FREE_LENS_MAIN)"
main="${main%/}"
# The forms of the main checkout path that a shell accepts.
main_forms=("$main")
if [[ "$main" == "$HOME"/* ]]; then main_forms+=("~${main#"$HOME"}" "\$HOME${main#"$HOME"}"); fi

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
# deny <text>: print one failure of the session once.
deny() {
    case "$reported" in *"|$1|"*) return ;; esac
    reported+="|$1|"
    echo "free-lens-reads: $s: not allowed: $1"
    found=1 bad=1
}

# The failure of each rg or grep in one shell command that skips .gitignore or has no folder.
search_failures() {
    local seg w tool uu hidden root skip operands haspat rec last u
    local -a words
    while IFS= read -r seg; do
        read -ra words <<< "$seg"
        tool="" uu=0 hidden=0 root=0 skip=0 operands=0 haspat=0 rec=0
        for w in ${words[@]+"${words[@]}"}; do
            if [[ -z "$tool" ]]; then
                case "${w##*/}" in rg | grep | egrep | fgrep) tool="${w##*/}" ;; esac
                continue
            fi
            if [[ "$tool" == rg ]]; then
                if [[ "$w" =~ ^-[A-Za-z]+$ ]]; then u="${w//[^u]/}"; uu=$((uu + ${#u})); fi
                [[ "$w" == --no-ignore* ]] && deny "rg --no-ignore searches the ignored .scratchpads/ folder"
                [[ "$w" == --hidden || "$w" == "-." ]] && hidden=1
                case "$w" in / | '~' | '~/' | '$HOME' | '${HOME}' | .. | ../*) root=1 ;; esac
                continue
            fi
            if [[ $skip -eq 1 ]]; then skip=0; continue; fi
            case "$w" in
                --recursive | --dereference-recursive) rec=1 ;;
                --regexp=* | --file=*) haspat=1 ;;
                --regexp | --file) haspat=1 skip=1 ;;
                --*) ;;
                -[A-Za-z]*)
                    [[ "$w" == *[rR]* ]] && rec=1
                    last="${w: -1}"
                    case "$last" in e | f) haspat=1 skip=1 ;; A | B | C | m) skip=1 ;; esac
                    ;;
                *) operands=$((operands + 1)) ;;
            esac
        done
        if [[ "$tool" == rg ]]; then
            [[ $uu -ge 2 ]] && deny "rg -uu searches the ignored .scratchpads/ folder"
            [[ $hidden -eq 1 && $root -eq 1 ]] && deny "rg --hidden with a root path searches the main checkout"
        elif [[ -n "$tool" && $rec -eq 1 && $((operands - 1 + haspat)) -le 0 ]]; then
            deny "grep -r with no path searches the ignored .scratchpads/ folder"
        fi
    done < <(sed -E "s/\"[^\"]*\"/Q/g; s/'[^']*'/Q/g" <<< "$1" | tr ';|&' '\n\n\n')
    return 0
}

for s in $sessions; do
    calls=0 found=0 reported="|"
    dir="$(sqlite3 -readonly "$db" "select directory from session_v2 where id = '$s';")"
    dir="${dir%/}"
    [[ "$dir" == "$main" ]] && deny "the session starts in the main checkout $main, not in the run worktree"
    # One line per tool input: the JSON text keeps a newline of a command as \n.
    while IFS= read -r input; do
        calls=$((calls + 1))
        while IFS= read -r token; do
            [[ -n "$token" ]] || continue
            r="$(rel "$token")"
            is_allowed "$r" && continue
            deny ".scratchpads/$r"
        done < <(grep -oE "[^][{}[:space:]\"'\`;|&()<>=,\\\\]*\.scratchpads[^][{}[:space:]\"'\`;|&()<>=,\\\\]*" <<< "$input")
        while IFS= read -r token; do
            [[ "$token" == "$dir" || "$token" == "$dir"/* ]] && continue
            for f in "${main_forms[@]}"; do
                [[ "$token" == "$f" || "$token" == "$f"/* ]] && deny "the main checkout path $token"
            done
        done < <(grep -oE "[^][{}[:space:]\"'\`;|&()<>=,\\\\]+" <<< "${input//\\n/ }")
    done < <(sqlite3 -readonly "$db" "select json_extract(p.value, '$.state.input') from session_message m, json_each(m.data, '$.content') p
        where m.session_id = '$s' and m.type = 'assistant' and json_extract(p.value, '$.type') = 'tool';")
    # One line per shell command; a newline in a command separates two commands.
    while IFS= read -r command; do
        search_failures "$command"
    done < <(sqlite3 -readonly "$db" "select replace(json_extract(p.value, '$.state.input.command'), char(10), ' ; ') from session_message m, json_each(m.data, '$.content') p
        where m.session_id = '$s' and m.type = 'assistant' and json_extract(p.value, '$.type') = 'tool'
        and json_extract(p.value, '$.state.input.command') is not null;")
    [[ $found -eq 0 ]] && echo "free-lens-reads: $s: clean ($calls tool calls)"
done
exit "$bad"
