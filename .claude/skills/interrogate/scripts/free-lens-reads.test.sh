#!/bin/bash
# Check that free-lens-reads.sh passes a session whose tool inputs name only allowed .scratchpads/
# paths, also when a tool output quotes another one; fails and names each other path (a read, a
# cd or a search of the folder, a workdir, Code Mode code); audits the one session of a
# <run>/<gate>/<lens> title; and exits 2 for a session id or another bad title, two rows with a
# title (in one directory, in two, or one in the main checkout), no session, or no database. The fixture database copies the opencode.db shape of
# OpenCode v2.0.29: session_v2 and session_message, with tool parts in the content of assistant
# rows. A session that starts in the main checkout, names its path, or runs a search that skips
# .gitignore (rg -uu, rg --no-ignore), a recursive grep with no path, or an rg or recursive grep of
# a root, home, or parent folder also fails, also when quoted or in Code Mode code. Run by
# `make test-hooks`.
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

[[ $failures -eq 0 ]] && echo "free-lens-reads tests: all passed"
exit $((failures > 0))
