#!/bin/bash
# Audit what a free-model session of OpenCode did, against the files that its brief allowed
# (docs/workflow/model-routing.md, free-job rules).
# Usage: free-lens-reads.sh <run>/<gate>/<lens> <allowed path>...
# One call audits one session. The key is the title that the delegate_task call gave it, which
# delegate_task does not return as an id: exactly one session_v2 row has the title, and its
# directory is not the main checkout. A second row with the title makes the key void.
# An allowed path is absolute or relative to .scratchpads/. The script reads the tool inputs only
# (a read path, a shell command and its workdir, a search path, Code Mode code), so a path that a
# tool output quotes does not count. These are failures:
# - Any other .scratchpads/ path in an input, also the bare folder (a cd into it or a search of it).
# - A session that starts in the main checkout, or an input that names its path (FREE_LENS_MAIN,
#   else the first entry of `git worktree list`). A session starts in the run worktree, where
#   .scratchpads/ holds only the brief files, so a search of the worktree cannot reach a review.
# - A shell search that skips .gitignore (rg -uu, rg --no-ignore), a recursive grep with no path,
#   and an rg or recursive grep of /, ~, $HOME, .., or a folder that holds the main checkout. The
#   check reads the shell text of a command and the shell text in Code Mode code, quotes removed.
# The database is OPENCODE_DB, else the opencode.db of the XDG data folder (OpenCode v2.0.29).
# Exit 0: each path is allowed. Exit 1: it prints each failure. Exit 2: usage, no sqlite3, no
# database, no main checkout, a title that is not <run>/<gate>/<lens>, no session, or two sessions
# for a title.
set -euo pipefail

die() { echo "free-lens-reads: $1" >&2; exit 2; }
[[ $# -ge 1 && -n "$1" ]] || die "usage: free-lens-reads.sh <run>/<gate>/<lens> <allowed path>..."
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

[[ "$arg" =~ ^[^/]+/[^/]+/[^/]+$ ]] || die "'$arg' is not a title of the form <run>/<gate>/<lens>"
sessions="$(sqlite3 -readonly "$db" "select id from session_v2 where title = '$query' order by id;")"
[[ -n "$sessions" ]] || die "no session with the title '$arg'"
[[ "$(wc -l <<< "$sessions")" -eq 1 ]] || die "two sessions have the title '$arg': give each free job a new title"

bad=0
# deny <text>: print one failure of the session once.
deny() {
    case "$reported" in *"|$1|"*) return ;; esac
    reported+="|$1|"
    echo "free-lens-reads: $s: not allowed: $1"
    found=1 bad=1
}

# True when a recursive search of the operand can reach the main checkout: the home folder, a
# parent folder, the root, or an absolute path or glob that holds the main checkout.
reaches_main() {
    local p="$1"
    case "$p" in
        '~'* | '$HOME'* | '${HOME}'* | .. | ../* | */.. | */../*) return 0 ;;
        /*)
            while [[ "$p" == */ ]]; do p="${p%/}"; done
            # shellcheck disable=SC2053
            [[ -z "$p" || "$main" == $p || "$main/" == "$p"/* ]] && return 0
            ;;
    esac
    return 1
}

# One word of a shell segment. The state is in the locals of search_failures.
search_word() {
    local w="$1" u
    if [[ -z "$tool" ]]; then
        case "${w##*/}" in rg | grep | egrep | fgrep) tool="${w##*/}" ;; esac
        return
    fi
    if [[ "$tool" == rg ]]; then
        if [[ "$w" =~ ^-[A-Za-z]+$ ]]; then u="${w//[^u]/}"; uu=$((uu + ${#u})); fi
        [[ "$w" == --no-ignore* ]] && deny "rg --no-ignore searches the ignored .scratchpads/ folder"
        [[ "$w" == --hidden || "$w" == "-." ]] && hidden=1
        [[ "$w" != -* ]] && reaches_main "$w" && roots+=" $w"
        return 0
    fi
    if [[ $skip -eq 1 ]]; then
        [[ $skipd -eq 1 && "$w" == recurse ]] && rec=1
        skip=0 skipd=0
        return
    fi
    case "$w" in
        --recursive | --dereference-recursive | --directories=recurse) rec=1 ;;
        --regexp=* | --file=*) haspat=1 ;;
        --regexp | --file) haspat=1 skip=1 ;;
        --*) ;;
        -[A-Za-z]*)
            [[ "$w" == *[rR]* ]] && rec=1
            case "${w: -1}" in
                e | f) haspat=1 skip=1 ;;
                d) skip=1 skipd=1 ;;
                A | B | C | m) skip=1 ;;
            esac
            ;;
        *) operands+=("$w") ;;
    esac
}

# The end of one shell segment: the failure of its rg or grep that skips .gitignore, has no folder,
# or searches a folder that holds the main checkout.
search_segment() {
    local o i=1
    if [[ "$tool" == rg ]]; then
        [[ $uu -ge 2 ]] && deny "rg -uu searches the ignored .scratchpads/ folder"
        if [[ -n "$roots" && $hidden -eq 1 ]]; then
            deny "rg --hidden with a root path searches the main checkout"
        elif [[ -n "$roots" ]]; then
            deny "rg searches$roots, which reaches the main .scratchpads/ folder"
        fi
    elif [[ -n "$tool" && $rec -eq 1 ]]; then
        # The first operand is the pattern, unless -e or -f gave it.
        [[ $haspat -eq 1 ]] && i=0
        if [[ $((${#operands[@]} - 1 + haspat)) -le 0 ]]; then
            deny "grep -r with no path searches the ignored .scratchpads/ folder"
        fi
        for o in ${operands[@]+"${operands[@]:$i}"}; do
            reaches_main "$o" && deny "grep -r searches $o, which reaches the main .scratchpads/ folder"
        done
    fi
    tool="" uu=0 hidden=0 skip=0 skipd=0 haspat=0 rec=0 roots="" operands=()
}

# The end of one word of search_failures.
end_word() {
    [[ $inw -eq 1 ]] || return 0
    if [[ $hasq -eq 1 && "$w" == *[[:space:]]* ]]; then search_failures "$w"; fi
    search_word "$w"
    w="" inw=0 hasq=0
}

# The failure of each rg or grep in a text of shell commands. Quotes group a word and then go; a
# quoted word with a space is scanned again, so sh -c "rg -uu x" and Code Mode strings count.
# Mode code also splits words at ( ) [ ] { } , : in the code.
search_failures() {
    local text="$1" mode="${2:-shell}" i c q="" w="" inw=0 hasq=0
    local tool="" uu=0 hidden=0 skip=0 skipd=0 haspat=0 rec=0 roots=""
    local -a operands=()
    for ((i = 0; i < ${#text}; i++)); do
        c="${text:i:1}"
        if [[ -n "$q" ]]; then
            if [[ "$c" == "$q" ]]; then
                q=""
            elif [[ "$c" == '\' && "$q" == '"' && $((i + 1)) -lt ${#text} ]]; then
                i=$((i + 1))
                w+="${text:i:1}"
            else
                w+="$c"
            fi
            continue
        fi
        case "$c" in
            "'" | '"' | '`') q="$c" inw=1 hasq=1 ;;
            '\')
                i=$((i + 1))
                w+="${text:i:1}" inw=1
                ;;
            ' ' | $'\t' | $'\r') end_word ;;
            ';' | '|' | '&' | $'\n') end_word; search_segment ;;
            '(' | ')' | '[' | ']' | '{' | '}' | ',' | ':')
                if [[ "$mode" == code ]]; then end_word; else w+="$c" inw=1; fi
                ;;
            *) w+="$c" inw=1 ;;
        esac
    done
    end_word
    search_segment
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
    # One line per shell command or Code Mode code; a newline separates two commands.
    while IFS= read -r command; do
        search_failures "$command"
    done < <(sqlite3 -readonly "$db" "select replace(json_extract(p.value, '$.state.input.command'), char(10), ' ; ') from session_message m, json_each(m.data, '$.content') p
        where m.session_id = '$s' and m.type = 'assistant' and json_extract(p.value, '$.type') = 'tool'
        and json_extract(p.value, '$.state.input.command') is not null;")
    while IFS= read -r code; do
        search_failures "$code" code
    done < <(sqlite3 -readonly "$db" "select replace(json_extract(p.value, '$.state.input.code'), char(10), ' ; ') from session_message m, json_each(m.data, '$.content') p
        where m.session_id = '$s' and m.type = 'assistant' and json_extract(p.value, '$.type') = 'tool'
        and json_extract(p.value, '$.state.input.code') is not null;")
    [[ $found -eq 0 ]] && echo "free-lens-reads: $s: clean ($calls tool calls)"
done
exit "$bad"
