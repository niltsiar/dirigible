#!/bin/bash
# Check that free-lens-reads.sh passes a session whose tool inputs name only allowed .scratchpads/
# paths, also when a tool output quotes another one; fails and names each other path (a read, a
# cd or a search of the folder, a workdir, Code Mode code); audits each session of a title; and
# exits 2 for no session or no database. The fixture database copies the opencode.db shape of
# OpenCode v2.0.29: session_v2 and session_message, with tool parts in the content of assistant
# rows. Run by `make test-hooks`.
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
# session <id> <title>
session() { sqlite3 "$db" "insert into session_v2 values ('$1', '$2', '/repo');"; }
# tool <session> <tool name> <input JSON> [<output text>]
tool() {
  n=$((n + 1))
  local data
  data="{\"content\":[{\"type\":\"text\",\"text\":\"step\"},{\"type\":\"tool\",\"name\":\"$2\",\"state\":{\"status\":\"completed\",\"input\":$3,\"content\":[{\"type\":\"text\",\"text\":\"${4:-ok}\"}]}}]}"
  sqlite3 "$db" "insert into session_message values ('m$n', '$1', 'assistant', $n, '$data');"
}
run() { OPENCODE_DB="$db" "$audit" "$@" > "$tmp/out" 2>&1; code=$?; }

session ses_ok lens-ok
tool ses_ok read "{\"path\":\"$scratch/runs/r/brief.txt\"}"
tool ses_ok shell '{"command":"cat .scratchpads/runs/r/brief.txt\nls Sources"}'
tool ses_ok read '{"path":"/repo/Sources/A.swift"}' "see $scratch/runs/old/review-diff-1.md for the key"
tool ses_ok write "{\"path\":\"$scratch/runs/r/answer.md\",\"content\":\"x\"}"
run ses_ok runs/r/brief.txt "$scratch/runs/r/answer.md"
[[ $code -eq 0 ]] || fail "allowed reads, a quote in output: exit $code: $(cat "$tmp/out")"

session ses_bad lens-bad
tool ses_bad read "{\"path\":\"$scratch/runs/r/brief.txt\"}"
tool ses_bad read "{\"path\":\"$scratch/runs/old/review-diff-1.md\"}"
run ses_bad runs/r/brief.txt
[[ $code -eq 1 ]] || fail "read outside the list: expected exit 1, got $code"
grep -q 'runs/old/review-diff-1.md' "$tmp/out" || fail "read outside the list: path not named: $(cat "$tmp/out")"
grep -q 'runs/r/brief.txt' "$tmp/out" && fail "read outside the list: an allowed path is named"

session ses_cd lens-cd
tool ses_cd shell '{"command":"cd /repo/.scratchpads && cat runs/old/review-diff-1.md"}'
run ses_cd runs/r/brief.txt
[[ $code -eq 1 ]] || fail "cd into the folder: expected exit 1, got $code"

session ses_rg lens-rg
tool ses_rg shell '{"command":"rg -uu review .scratchpads/"}'
run ses_rg runs/r/brief.txt
[[ $code -eq 1 ]] || fail "search of the folder: expected exit 1, got $code"

session ses_wd lens-wd
tool ses_wd shell "{\"command\":\"cat review-diff-1.md\",\"workdir\":\"$scratch/runs/old\"}"
run ses_wd runs/r/brief.txt
[[ $code -eq 1 ]] || fail "workdir in the folder: expected exit 1, got $code"

session ses_ex lens-ex
tool ses_ex execute '{"code":"await tools.read({path: `.scratchpads/runs/old/run.md`})"}'
run ses_ex runs/r/brief.txt
[[ $code -eq 1 ]] || fail "Code Mode read: expected exit 1, got $code"

session ses_d1 lens-dup
tool ses_d1 read "{\"path\":\"$scratch/runs/r/brief.txt\"}"
session ses_d2 lens-dup
tool ses_d2 read "{\"path\":\"$scratch/backlog.md\"}"
run lens-dup runs/r/brief.txt
[[ $code -eq 1 ]] || fail "a title with two sessions: expected exit 1, got $code"
grep -q 'ses_d2.*backlog.md' "$tmp/out" || fail "a title with two sessions: the second session is not audited: $(cat "$tmp/out")"

run lens-none runs/r/brief.txt
[[ $code -eq 2 ]] || fail "no session: expected exit 2, got $code"

OPENCODE_DB="$tmp/missing.db" "$audit" ses_ok runs/r/brief.txt > /dev/null 2>&1; code=$?
[[ $code -eq 2 ]] || fail "no database: expected exit 2, got $code"

run
[[ $code -eq 2 ]] || fail "no argument: expected exit 2, got $code"

[[ $failures -eq 0 ]] && echo "free-lens-reads tests: all passed"
exit $((failures > 0))
