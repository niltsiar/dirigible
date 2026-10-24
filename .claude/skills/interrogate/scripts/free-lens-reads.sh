#!/bin/bash
# Audit what a free-model session of OpenCode did, against the files that its brief allowed
# (docs/workflow/model-routing.md, free-job rules).
# Usage: free-lens-reads.sh <run>/<gate>/<lens> <allowed path>...
#        free-lens-reads.sh --t3 <activity file> <allowed path>...
# One call audits one session. The key is the title that the delegate_task call gave it, which
# delegate_task does not return as an id: exactly one session_v2 row has the title, and its
# directory is not the main checkout. A second row with the title makes the key void.
# An allowed path is absolute or relative to .scratchpads/. The script reads the tool inputs only
# (a read path, a shell command and its workdir, a search path, Code Mode code), so a path that a
# tool output quotes does not count. These are failures:
# - Any other .scratchpads/ path in an input, also the bare folder (a cd into it or a search of it).
# - A session that starts in the main checkout, or an input that names its path (FREE_LENS_MAIN,
#   else the first entry of `git worktree list`). The isolation worktree of delegate_task has
#   no .scratchpads/ folder, so a search of it cannot reach a review.
# - A shell search that skips .gitignore (rg -uu, rg --no-ignore), a recursive grep with no path,
#   and an rg or recursive grep of /, ~, $HOME, .., or a folder that holds the main checkout. The
#   check reads the shell text of a command and the shell text in Code Mode code, quotes removed.
# The database is OPENCODE_DB, else the opencode.db of the XDG data folder (OpenCode v2.0.29).
# The --t3 mode audits a T3 thread (an Antigravity child) from the output of t3_thread_read with
# view "activity" and maxCharsPerItem 50000, saved whole. It reads two item types: a dynamic_tool
# item (its text is JSON with toolName and input) and a command_execution item (its text is
# "$ <command>" and then the output, which never counts). Each string under a tool input and the
# first line of a command go to the checks above. It fails closed on what it cannot read in full:
# - a thread with no worktreePath or one in the main checkout;
# - a dynamic_tool item that is truncated, is not complete JSON, names a tool other than Read, or
#   has no AbsolutePath or path field;
# - a command_execution item that is truncated with no newline in its text (a first line may be
#   cut), or whose first line ends with a backslash, opens a heredoc, or has an open quote;
# - positions that are not 0, 1, 2, ... or a count that differs from thread.itemCount (a dropped
#   item), and a file whose last item except a checkpoint is not an assistant_message.
# Exit 0: each path is allowed. Exit 1: it prints each failure. Exit 2: usage, no sqlite3, no
# database, no main checkout, a title that is not <run>/<gate>/<lens>, no session, or two sessions
# for a title. In the --t3 mode, exit 2 is also no python3, no file, or no thread object.
set -euo pipefail

die() { echo "free-lens-reads: $1" >&2; exit 2; }
t3=0
if [[ "${1:-}" == --t3 ]]; then
    t3=1
    shift
    [[ $# -ge 1 && -n "$1" ]] || die "usage: free-lens-reads.sh --t3 <activity file> <allowed path>..."
    command -v python3 > /dev/null || die "python3 is not installed"
    [[ -f "$1" ]] || die "no activity file at $1"
    activity="$1"
else
    [[ $# -ge 1 && -n "$1" ]] || die "usage: free-lens-reads.sh <run>/<gate>/<lens> <allowed path>..."
    command -v sqlite3 > /dev/null || die "sqlite3 is not installed"
    db="${OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
    [[ -f "$db" ]] || die "no OpenCode database at $db (set OPENCODE_DB)"
    arg="$1"
    query="${arg//\'/\'\'}"
fi
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

if [[ $t3 -eq 0 ]]; then
    [[ "$arg" =~ ^[^/]+/[^/]+/[^/]+$ ]] || die "'$arg' is not a title of the form <run>/<gate>/<lens>"
    sessions="$(sqlite3 -readonly "$db" "select id from session_v2 where title = '$query' order by id;")"
    [[ -n "$sessions" ]] || die "no session with the title '$arg'"
    [[ "$(wc -l <<< "$sessions")" -eq 1 ]] || die "two sessions have the title '$arg': give each free job a new title"
fi

bad=0
# deny <text>: print one failure of the session once.
deny() {
    case "$reported" in *"|$1|"*) return 0 ;; esac
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

# check_input <text>: the failures of one tool input. The text is the JSON of an OpenCode input,
# or one string of a T3 input. $dir is the directory of the session or the worktree of the thread.
check_input() {
    local input="$1" token r f
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
    return 0
}

# The reader of a saved T3 activity view. It prints one line for each fact: "WT" and the
# worktreePath, "FAIL" and a failure, "S" and a string to check. A newline in a string becomes " ; ".
# It exits 2 for a file with no thread object.
t3_read() {
    python3 -I - "$1" << 'PY'
import json, re, sys

KNOWN_TOOLS = {"Read"}
PATH_FIELDS = ("AbsolutePath", "path")


def emit(kind, text):
    print(kind + "\t" + re.sub(r"[\t\r]", " ", text).replace("\n", " ; "))


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def open_quote(line):
    quote = ""
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 1
            elif c == quote:
                quote = ""
        elif c == "\\":
            i += 1
        elif c in "'\"`":
            quote = c
        i += 1
    return quote != ""


try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(2)
thread = data.get("thread") if isinstance(data, dict) else None
if not isinstance(thread, dict):
    sys.exit(2)
emit("WT", thread.get("worktreePath") or "")
items = data.get("items")
if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
    emit("FAIL", "the file has no list of items")
    sys.exit(0)
positions = [i.get("position") for i in items]
if sorted(positions, key=lambda p: (not isinstance(p, int), p if isinstance(p, int) else 0)) != list(range(len(items))):
    emit("FAIL", "the positions are not 0 to " + str(len(items) - 1) + " with no gap")
if thread.get("itemCount") != len(items):
    emit("FAIL", "itemCount is " + str(thread.get("itemCount")) + " and the file has " + str(len(items)) + " items")
ordered = sorted((i for i in items if isinstance(i.get("position"), int)), key=lambda i: i["position"])
tools = [i for i in ordered if i.get("type") != "checkpoint"]
if not tools or tools[-1].get("type") != "assistant_message":
    emit("FAIL", "the thread has no closing assistant_message item")
for i in ordered:
    kind, text, cut = i.get("type"), i.get("text"), i.get("textTruncated") is True
    where = "item " + str(i["position"])
    if kind == "dynamic_tool":
        if cut:
            emit("FAIL", where + " is a truncated dynamic_tool item")
            continue
        try:
            call = json.loads(text)
        except (TypeError, ValueError):
            call = None
        if not isinstance(call, dict) or not isinstance(call.get("input"), dict):
            emit("FAIL", where + " is not complete JSON with a toolName and an input")
            continue
        if call.get("toolName") not in KNOWN_TOOLS:
            emit("FAIL", where + " names the unknown tool " + str(call.get("toolName")))
            continue
        if not any(isinstance(call["input"].get(k), str) and call["input"][k] for k in PATH_FIELDS):
            emit("FAIL", where + " has no path field (" + ", ".join(PATH_FIELDS) + ")")
            continue
        for s in strings(call["input"]):
            emit("S", s)
    elif kind == "command_execution":
        if not isinstance(text, str) or (cut and "\n" not in text):
            emit("FAIL", where + " is a command_execution item with a truncated first line")
            continue
        line = text.split("\n", 1)[0]
        if line.startswith("$ "):
            line = line[2:]
        if line.rstrip().endswith("\\") or re.search(r"<<(?!<)", line) or open_quote(line):
            emit("FAIL", where + " has a first line that may go on in the next lines: " + line)
            continue
        emit("S", line)
PY
}

# The audit of a saved T3 activity view: one thread, with its worktree as its directory.
t3_audit() {
    local out rc=0 kind text calls=0 s=t3 found=0 reported="|" dir=/nonexistent-worktree
    out="$(t3_read "$activity")" || rc=$?
    [[ $rc -eq 0 ]] || die "no thread object in $activity"
    while IFS=$'\t' read -r kind text; do
        case "$kind" in
            WT)
                if [[ -z "$text" ]]; then
                    deny "the thread has no worktreePath, so it did not run in an isolation worktree"
                elif [[ "${text%/}" == "$main" ]]; then
                    deny "the thread starts in the main checkout $main, not in its isolation worktree"
                else
                    dir="${text%/}"
                fi
                ;;
            FAIL) deny "$text" ;;
            S)
                calls=$((calls + 1))
                check_input "$text"
                search_failures "$text"
                ;;
        esac
    done <<< "$out"
    [[ $found -eq 0 ]] && echo "free-lens-reads: $s: clean ($calls tool calls)"
    return 0
}
if [[ $t3 -eq 1 ]]; then
    t3_audit
    exit "$bad"
fi

for s in $sessions; do
    calls=0 found=0 reported="|"
    dir="$(sqlite3 -readonly "$db" "select directory from session_v2 where id = '$s';")"
    dir="${dir%/}"
    [[ "$dir" == "$main" ]] && deny "the session starts in the main checkout $main, not in its isolation worktree"
    # One line per tool input: the JSON text keeps a newline of a command as \n.
    while IFS= read -r input; do
        calls=$((calls + 1))
        check_input "$input"
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
