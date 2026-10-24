#!/bin/bash
# Check that free-lens-reads.sh passes a session whose tool inputs name only allowed .scratchpads/
# paths, also when a tool output quotes another one; fails and names each other path (a read, a
# cd or a search of the folder, a workdir, Code Mode code); audits the one session of a
# <run>/<gate>/<lens> title; and exits 2 for a session id or another bad title, two rows with a
# title (in one directory, in two, or one in the main checkout), no session, or no database. The
# fixture database copies the opencode.db shape of OpenCode v2.0.29: session_v2 and
# session_message, with tool parts in the content of assistant rows. A session that starts in the
# main checkout, names its path, or runs a search that skips .gitignore (rg -uu, rg --no-ignore),
# a recursive grep with no path, or an rg or recursive grep of a root, home, or parent folder also
# fails, also when quoted or in Code Mode code. The --t3 mode reads a saved activity view of a T3
# thread (the shape of a real Antigravity child thread): it passes the inputs of an isolation
# worktree and fails closed on an item that it cannot read in full. Run by `make test-hooks`.
set -uo pipefail
audit="$(cd "$(dirname "$0")" && pwd)/free-lens-reads.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

db="$tmp/opencode.db"
sqlite3 "$db" "create table session_v2 (id text primary key, title text, directory text not null);
  create table session_message (id text primary key, session_id text not null, type text not null, seq integer not null, data text not null);"
scratch=/repo/.scratchpads
n=0
sq="'"
# session <id> <title> [<directory>]
session() { sqlite3 "$db" "insert into session_v2 values ('$1', '$2', '${3:-/repo}');"; }
# tool <session> <tool name> <input JSON> [<output text>]
tool() {
  n=$((n + 1))
  local data
  data="{\"content\":[{\"type\":\"text\",\"text\":\"step\"},{\"type\":\"tool\",\"name\":\"$2\",\"state\":{\"status\":\"completed\",\"input\":$3,\"content\":[{\"type\":\"text\",\"text\":\"${4:-ok}\"}]}}]}"
  data="${data//$sq/$sq$sq}"
  sqlite3 "$db" "insert into session_message values ('m$n', '$1', 'assistant', $n, '$data');"
}
run() { OPENCODE_DB="$db" FREE_LENS_MAIN="${MAIN:-/main}" "$audit" "$@" > "$tmp/out" 2>&1; code=$?; }

session ses_ok r/g/ok
tool ses_ok read "{\"path\":\"$scratch/runs/r/brief.txt\"}"
tool ses_ok shell '{"command":"cat .scratchpads/runs/r/brief.txt\nls Sources"}'
tool ses_ok read '{"path":"/repo/Sources/A.swift"}' "see $scratch/runs/old/review-diff-1.md for the key"
tool ses_ok write "{\"path\":\"$scratch/runs/r/answer.md\",\"content\":\"x\"}"
tool ses_ok shell '{"command":"rg --hidden stopGrace Sources && grep -rn stopGrace Sources Tests && rg -u foo && ls /repo-two"}'
tool ses_ok shell '{"command":"rg \"a b\" ./Sources /repo/Tests; rg --files Sources; grep -rn \"/\" Sources; grep -rn -e .. Sources; rg \"x|y; z\" Sources"}'
run r/g/ok runs/r/brief.txt "$scratch/runs/r/answer.md"
[[ $code -eq 0 ]] || fail "allowed reads, a quote in output: exit $code: $(cat "$tmp/out")"

session ses_bad r/g/bad
tool ses_bad read "{\"path\":\"$scratch/runs/r/brief.txt\"}"
tool ses_bad read "{\"path\":\"$scratch/runs/old/review-diff-1.md\"}"
run r/g/bad runs/r/brief.txt
[[ $code -eq 1 ]] || fail "read outside the list: expected exit 1, got $code"
grep -q 'runs/old/review-diff-1.md' "$tmp/out" || fail "read outside the list: path not named: $(cat "$tmp/out")"
grep -q 'runs/r/brief.txt' "$tmp/out" && fail "read outside the list: an allowed path is named"

session ses_cd r/g/cd
tool ses_cd shell '{"command":"cd /repo/.scratchpads && cat runs/old/review-diff-1.md"}'
run r/g/cd runs/r/brief.txt
[[ $code -eq 1 ]] || fail "cd into the folder: expected exit 1, got $code"

session ses_rg r/g/rg
tool ses_rg shell '{"command":"rg -uu review .scratchpads/"}'
run r/g/rg runs/r/brief.txt
[[ $code -eq 1 ]] || fail "search of the folder: expected exit 1, got $code"

session ses_cm r/g/cm
tool ses_cm execute '{"code":"await tools.shell({command: \"grep -r review ~\"})"}'
tool ses_cm execute '{"code":"await tools.shell({command: `rg -uu review`})"}'
tool ses_cm execute '{"code":"exec(\"rg\", [\"--no-ignore\", \"x\"])"}'
run r/g/cm runs/r/brief.txt
[[ $code -eq 1 ]] || fail "shell text in Code Mode: expected exit 1, got $code: $(cat "$tmp/out")"
[[ "$(grep -c 'not allowed' "$tmp/out")" -eq 3 ]] || fail "shell text in Code Mode: expected 3 failures: $(cat "$tmp/out")"

session ses_cmok r/g/cmok
tool ses_cmok execute '{"code":"const r = await tools.shell({command: \"rg stopGrace Sources\"}); return [1, 2].map((x) => x + 1)"}'
run r/g/cmok runs/r/brief.txt
[[ $code -eq 0 ]] || fail "Code Mode with a clean search: expected exit 0, got $code: $(cat "$tmp/out")"

session ses_wd r/g/wd
tool ses_wd shell "{\"command\":\"cat review-diff-1.md\",\"workdir\":\"$scratch/runs/old\"}"
run r/g/wd runs/r/brief.txt
[[ $code -eq 1 ]] || fail "workdir in the folder: expected exit 1, got $code"

session ses_ex r/g/ex
tool ses_ex execute '{"code":"await tools.read({path: `.scratchpads/runs/old/run.md`})"}'
run r/g/ex runs/r/brief.txt
[[ $code -eq 1 ]] || fail "Code Mode read: expected exit 1, got $code"

# A search or path that could reach the answer key from the worktree: one case each.
# deny <id> <command> <text of the failure line>
deny() {
  session "ses_$1" "r/g/$1"
  tool "ses_$1" shell "{\"command\":\"$2\"}"
  run "r/g/$1" runs/r/brief.txt
  [[ $code -eq 1 ]] || fail "$1: expected exit 1, got $code: $(cat "$tmp/out")"
  grep -q "$3" "$tmp/out" || fail "$1: no failure line with '$3': $(cat "$tmp/out")"
}
deny uu 'rg -uu review' 'rg -uu'
deny uuu 'cd Sources && rg -uuu review' 'rg -uu'
deny noign 'rg --no-ignore review' 'rg --no-ignore'
deny hidroot 'rg --hidden review /' 'rg --hidden with a root path'
deny hidhome 'rg --hidden review ~' 'rg --hidden with a root path'
deny grepnopath 'grep -r review' 'grep -r with no path'
deny grepnopath2 'cat a | grep -rn review' 'grep -r with no path'
deny grepafterrg 'rg review Sources | grep -r review' 'grep -r with no path'
deny maincat 'cat /main/AGENTS.md' 'main checkout'
deny mainls 'ls /main' 'main checkout'

# A recursive search of a root, home, or parent folder, also quoted or inside Code Mode input.
deny rghome 'rg review ~' 'reaches the main'
deny rghomesub 'rg review ~/projects' 'reaches the main'
deny rgenv 'rg review $HOME/projects' 'reaches the main'
deny rgenvbrace 'rg review ${HOME}' 'reaches the main'
deny rgparent 'rg review ..' 'reaches the main'
deny rgparent2 'rg review ../..' 'reaches the main'
deny rgmid 'rg review Sources/../..' 'reaches the main'
deny rgroot 'rg review /' 'reaches the main'
deny grephome 'grep -rn review ~' 'reaches the main'
deny grepenv 'grep -r review $HOME' 'reaches the main'
deny grepparent 'grep -R review ../x' 'reaches the main'
deny greproot 'grep -r review /' 'reaches the main'
deny greplong 'grep --recursive review ..' 'reaches the main'
deny grepdir 'grep -d recurse review ..' 'reaches the main'
deny greppath 'grep review .. -r' 'reaches the main'
MAIN=/home/u/proj/main deny ancrg 'rg review /home/u/proj' 'reaches the main'
MAIN=/home/u/proj/main deny ancgrep 'grep -r review /home/u/' 'reaches the main'
MAIN=/home/u/proj/main deny ancglob 'rg review /home/u/*' 'reaches the main'
deny quoteduu 'rg \"-uu\" review' 'rg -uu'
deny quotednoign "rg '--no-ignore' review" 'rg --no-ignore'
deny quotedhome 'rg review \"$HOME\"' 'reaches the main'
deny quotedpath "grep -r review '..'" 'reaches the main'
deny shellc 'sh -c \"rg -uu review\"' 'rg -uu'
deny nopathquoted 'grep -r \"a b\"' 'grep -r with no path'

session ses_inmain r/g/inmain /main
tool ses_inmain read '{"path":"/main/Sources/A.swift"}'
run r/g/inmain runs/r/brief.txt
[[ $code -eq 1 ]] || fail "a session that starts in the main checkout: expected exit 1, got $code"
grep -q 'starts in the main checkout' "$tmp/out" || fail "a session that starts in the main checkout: no failure line: $(cat "$tmp/out")"

session ses_old r/g/lens /old-worktree
tool ses_old read "{\"path\":\"$scratch/runs/old/review-diff-1.md\"}"
session ses_new r/g/lens
tool ses_new read "{\"path\":\"$scratch/runs/r/brief.txt\"}"
run r/g/lens runs/r/brief.txt
[[ $code -eq 2 ]] || fail "a title with two rows in two directories: expected exit 2, got $code: $(cat "$tmp/out")"
grep -q 'ses_old\|ses_new' "$tmp/out" && fail "a title with two rows: a session is audited"
grep -q 'two sessions' "$tmp/out" || fail "a title with two rows: no failure line: $(cat "$tmp/out")"

session ses_t1 r/g/twice
session ses_t2 r/g/twice
run r/g/twice runs/r/brief.txt
[[ $code -eq 2 ]] || fail "a title with two rows in the worktree: expected exit 2, got $code"

session ses_m1 r/g/mixed /main
session ses_m2 r/g/mixed
run r/g/mixed runs/r/brief.txt
[[ $code -eq 2 ]] || fail "a title with a row in the main checkout and a row in the worktree: expected exit 2, got $code"

run ses_ok runs/r/brief.txt
[[ $code -eq 2 ]] || fail "a session id in place of the title: expected exit 2, got $code"
grep -q 'run>/<gate>/<lens' "$tmp/out" || fail "a session id in place of the title: no form hint: $(cat "$tmp/out")"

session ses_loose loose
run loose runs/r/brief.txt
[[ $code -eq 2 ]] || fail "a title not in the run/gate/lens form: expected exit 2, got $code"
grep -q 'run>/<gate>/<lens' "$tmp/out" || fail "a title not in the run/gate/lens form: no form hint: $(cat "$tmp/out")"

run r/g/none runs/r/brief.txt
[[ $code -eq 2 ]] || fail "no session: expected exit 2, got $code"

OPENCODE_DB="$tmp/missing.db" "$audit" r/g/ok runs/r/brief.txt > /dev/null 2>&1; code=$?
[[ $code -eq 2 ]] || fail "no database: expected exit 2, got $code"

run
[[ $code -eq 2 ]] || fail "no argument: expected exit 2, got $code"

# The --t3 mode. The fixture has the shape of a real activity view of an Antigravity child thread:
# a truncated user_message at position 0, a command_execution item for the workspace, dynamic_tool
# Read items, command_execution items whose first line is whole and whose output is cut, a closing
# assistant_message, and a checkpoint. thread.itemCount is the item count.
wt=/home/u/.t3/worktrees/repo/t3-1
# t3 <name> [<python statement that changes d>]: write $tmp/<name>.json
t3() {
  python3 -I -c '
import json, sys
wt = sys.argv[2]
def read(path, **extra):
    return json.dumps({"toolName": "Read", "input": {"AbsolutePath": path, "path": path, **extra}}, indent=2)
def item(pos, kind, text, cut=False):
    return {"position": pos, "type": kind, "status": "completed", "text": text, "textTruncated": cut, "nextTextOffset": 400 if cut else None}
d = {"thread": {"worktreePath": wt, "itemCount": 8}, "nextPosition": 7, "hasMore": False, "items": [
    item(0, "user_message", "Act as the review sub-agent", True),
    item(1, "command_execution", "$ Preparing workspace\nWorkspace preparation completed."),
    item(2, "dynamic_tool", read(wt + "/Sources/A.swift")),
    item(3, "dynamic_tool", read(wt + "/.scratchpads/runs/r/brief.txt")),
    item(4, "command_execution", "$ rg -n stopGrace Sources\n<truncated 3 lines>\nSources/A.swift:1:x", True),
    item(5, "command_execution", "$ cat " + wt + "/Sources/A.swift\nline"),
    item(6, "assistant_message", "major | S1 | text", True),
    item(7, "checkpoint", "[]")]}
exec(sys.argv[3])
json.dump(d, open(sys.argv[1], "w"))
' "$tmp/$1.json" "$wt" "${2:-pass}"
}
runt3() { FREE_LENS_MAIN="${MAIN:-/main}" "$audit" --t3 "$tmp/$1.json" "${@:2}" > "$tmp/out" 2>&1; code=$?; }
# t3deny <name> <python statement> <text of the failure line>: one fail-closed case
t3deny() {
  t3 "$1" "$2"
  runt3 "$1" runs/r/brief.txt
  [[ $code -eq 1 ]] || fail "--t3 $1: expected exit 1, got $code: $(cat "$tmp/out")"
  grep -qF -- "$3" "$tmp/out" || fail "--t3 $1: no failure line with '$3': $(cat "$tmp/out")"
}

t3 t3ok
runt3 t3ok runs/r/brief.txt
[[ $code -eq 0 ]] || fail "--t3 a thread of an isolation worktree: expected exit 0, got $code: $(cat "$tmp/out")"
grep -qF 'clean' "$tmp/out" || fail "--t3 a clean thread: no clean line: $(cat "$tmp/out")"

t3deny t3main 'd["items"][2]["text"] = read("/main/Sources/A.swift")' '/main/Sources/A.swift'
t3deny t3nowt 'd["thread"]["worktreePath"] = None' 'worktreePath'
t3deny t3inmain 'd["thread"]["worktreePath"] = "/main"' 'starts in the main checkout'
t3deny t3scratch 'd["items"][5]["text"] = "$ cat " + wt + "/.scratchpads/runs/old/run.md\nout"' '.scratchpads/runs/old/run.md'
t3deny t3mainscratch 'd["items"][5]["text"] = "$ rg -n x /main/.scratchpads/runs/old/run.md\nout"' '.scratchpads/runs/old/run.md'
t3deny t3uu 'd["items"][5]["text"] = "$ rg -uu x\nout"' 'rg -uu'
t3deny t3rgparent 'd["items"][5]["text"] = "$ rg x ..\nout"' 'reaches the main'
t3deny t3grepnopath 'd["items"][5]["text"] = "$ grep -rn x\nout"' 'grep -r with no path'
t3deny t3input 'd["items"][2]["text"] = read(wt + "/Sources/A.swift", query="rg -uu x")' 'rg -uu'
t3deny t3inputpath 'd["items"][2]["text"] = read(wt + "/Sources/A.swift", extra="/main/AGENTS.md")' '/main/AGENTS.md'

# A path that two items name is one failure, and a failure after it is still printed.
t3deny t3dup 'd["items"][3]["text"] = read(wt + "/.scratchpads/runs/old/run.md"); d["items"][4]["text"] = "$ cat " + wt + "/.scratchpads/runs/old/run.md\nout"; d["items"][5]["text"] = "$ rg -uu x\nout"' 'rg -uu'

# The output of a command never counts: a path that only the output quotes passes.
t3 t3outquote 'd["items"][5]["text"] = "$ cat " + wt + "/Sources/A.swift\n/main/AGENTS.md and .scratchpads/runs/old/run.md"'
runt3 t3outquote runs/r/brief.txt
[[ $code -eq 0 ]] || fail "--t3 a path that only an output quotes: expected exit 0, got $code: $(cat "$tmp/out")"

# Fail closed: an item that the audit cannot read in full.
t3deny t3badjson 'd["items"][2]["text"] = "{\"toolName\": \"Read\", \"inp"' 'complete JSON'
t3deny t3dtcut 'd["items"][2]["textTruncated"] = True' 'truncated'
t3deny t3tool 'd["items"][2]["text"] = json.dumps({"toolName": "Grep", "input": {"path": wt}})' 'Grep'
t3deny t3nopath 'd["items"][2]["text"] = json.dumps({"toolName": "Read", "input": {"StartLine": 1}})' 'path field'
t3deny t3cmdcut 'd["items"][5]["text"] = "$ cat " + wt; d["items"][5]["textTruncated"] = True' 'truncated'
t3deny t3backslash 'd["items"][5]["text"] = "$ cat a \\\nb\nout"' 'first line'
t3deny t3heredoc 'd["items"][5]["text"] = "$ cat <<EOF\nrg -uu x\nEOF"' 'first line'
t3deny t3quote 'd["items"][5]["text"] = "$ echo \"a\nrg -uu x\""' 'first line'
t3deny t3gap 'd["items"][5]["position"] = 9' 'positions'
t3deny t3count 'd["thread"]["itemCount"] = 9' 'itemCount'
t3deny t3dropped 'del d["items"][3]' 'itemCount'
t3deny t3noclose 'd["items"][6]["type"] = "user_message"' 'closing'
echo '{"items": []}' > "$tmp/t3nothread.json"
runt3 t3nothread runs/r/brief.txt
[[ $code -eq 2 ]] || fail "--t3 a file with no thread object: expected exit 2, got $code: $(cat "$tmp/out")"
echo 'not json' > "$tmp/t3garbage.json"
runt3 t3garbage runs/r/brief.txt
[[ $code -eq 2 ]] || fail "--t3 a file that is not JSON: expected exit 2, got $code: $(cat "$tmp/out")"
FREE_LENS_MAIN=/main "$audit" --t3 "$tmp/missing.json" > /dev/null 2>&1; code=$?
[[ $code -eq 2 ]] || fail "--t3 no file: expected exit 2, got $code"

[[ $failures -eq 0 ]] && echo "free-lens-reads tests: all passed"
exit $((failures > 0))
