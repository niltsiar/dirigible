#!/bin/bash
# Check scripts/wiki.py: the wiki path, init, the write lock, the page commands, the lint, the
# text from files, the seed, and the import. Each test wiki is a temp folder that DIRIGIBLE_WIKI
# names, so a test never reads or writes the real wiki.
# Run by `make test-hooks`.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
script="${WIKI_SCRIPT:-$repo/scripts/wiki.py}"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
holders=()
cleanup() {
    local p
    for p in ${holders[@]+"${holders[@]}"}; do kill -9 "$p" 2>/dev/null || true; done
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
unset DIRIGIBLE_WIKI_LOCK_WAIT

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
newwiki() {
    export DIRIGIBLE_WIKI="$tmp/$1"
    local out
    out="$("$script" init 2>&1)" || fail "init $1: $out"
}
head_of() { git -C "$DIRIGIBLE_WIKI" rev-parse HEAD; }
commits_of() { git -C "$DIRIGIBLE_WIKI" rev-list --count HEAD; }
status_of() { git -C "$DIRIGIBLE_WIKI" status --porcelain; }
tree_sums() { (cd "$1" && find . -type f -not -path './.git/*' | sort | xargs shasum); }
now_s() { python3 -c 'import time; print(time.time())'; }
elapsed_ok() { python3 -c "import sys; sys.exit(0 if $2 - $1 $3 else 1)"; }
# put_item <file> <title> <description> <body line>...: the add and edit file.
put_item() {
    local f="$1" t="$2" d="$3"
    shift 3
    { printf '%s\n%s\n\n' "$t" "$d"; printf '%s\n' "$@"; } > "$f"
}
# body_of <id>: the body of the page that show prints, without the hash line and the front matter.
body_of() {
    "$script" show "$1" | awk 'NR == 1 { next } c < 2 { if ($0 == "---") { c++; if (c == 2) getline }; next } { print }'
}
# run <cmd...>: sets out and rc.
run() { out="$("$@" 2>&1)"; rc=$?; }
want_rc() { [[ $rc -eq $1 ]] || fail "$2: exit $rc, want $1: $out"; }
want_out() { [[ "$out" == *"$1"* ]] || fail "$2: output lacks [$1]: $out"; }

# --- C14 init
newwiki init1
[[ -z "$(git -C "$DIRIGIBLE_WIKI" remote)" ]] || fail "init: the wiki has a remote"
for f in CLAUDE.md wiki/index.md wiki/now.md wiki/decision-numbers.md wiki/next/index.md wiki/later/index.md \
    wiki/done/index.md wiki/lessons/index.md wiki/log/index.md "wiki/log/$(date +%Y-%m).md" templates/item.md templates/lesson.md; do
    [[ -f "$DIRIGIBLE_WIKI/$f" ]] || fail "init: no $f"
done
run "$script" lint; want_rc 0 "lint of an empty wiki"
[[ -z "$(status_of)" ]] || fail "init: the tree is not clean"
before="$(tree_sums "$DIRIGIBLE_WIKI")"
run "$script" init; [[ $rc -ne 0 ]] || fail "init on an existing path exits 0"
[[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" ]] || fail "init on an existing path changed it"

# --- C9 no wiki
export DIRIGIBLE_WIKI="$tmp/missing"
for c in "list next" "count next" "now" "runs" "numbers" "lint"; do
    run "$script" $c
    [[ $rc -ne 0 ]] || fail "no wiki: $c exits 0"
    for w in "$tmp/missing" "scripts/wiki.py init" "DIRIGIBLE_WIKI"; do want_out "$w" "no wiki: $c"; done
done
[[ ! -e "$tmp/missing" ]] || fail "a reader made the wiki folder"
run "$script" path; want_rc 0 "path with no wiki"
[[ "$out" == "$tmp/missing" ]] || fail "path with no wiki: [$out]"

# --- C8 path from a worktree, from outside the repo, the override, and a .git file
mkdir -p "$tmp/main/scripts"
cp "$script" "$tmp/main/scripts/wiki.py"
g -C "$tmp/main" init -q -b main
g -C "$tmp/main" add -A
g -C "$tmp/main" commit -q -m base
g -C "$tmp/main" worktree add -q -b other "$tmp/wt"
unset DIRIGIBLE_WIKI
run "$tmp/wt/scripts/wiki.py" path; want_rc 0 "path from a worktree"
[[ "$out" == "$tmp/dirigible-wiki" ]] || fail "path from a worktree: [$out], want [$tmp/dirigible-wiki]"
run bash -c "cd / && '$tmp/main/scripts/wiki.py' path"
[[ "$out" == "$tmp/dirigible-wiki" ]] || fail "path from outside the repo: [$out]"
run env DIRIGIBLE_WIKI="$tmp/elsewhere" "$tmp/wt/scripts/wiki.py" path
[[ "$out" == "$tmp/elsewhere" ]] || fail "path with the override: [$out]"
mkdir -p "$tmp/gitfile"
printf 'gitdir: /nowhere\n' > "$tmp/gitfile/.git"
run env DIRIGIBLE_WIKI="$tmp/gitfile" "$script" path
[[ $rc -ne 0 ]] || fail "a .git file is not refused"
want_out ".git" "a .git file"

# --- the page commands: add, list, show, count
newwiki cmds
put_item "$tmp/a1.txt" "First item" "The first item has a short description" "Body line one" "  indented body line two"
run "$script" add next --from "$tmp/a1.txt"; want_rc 0 "add"
[[ ! -e "$tmp/a1.txt" ]] || fail "add keeps the --from file after its commit"
run "$script" list next; want_rc 0 "list"
[[ "$out" == "0001 First item: The first item has a short description" ]] || fail "list next: [$out]"
run "$script" count next; [[ "$out" == 1 ]] || fail "count next: [$out]"
run "$script" count later; [[ "$out" == 0 ]] || fail "count later: [$out]"
run "$script" show 0001; want_rc 0 "show"
[[ "$(head -n 1 <<<"$out")" =~ ^hash:\ [0-9a-f]{64}$ ]] || fail "show: no hash line: $out"
want_out "type: Item" "show"
want_out "status: next" "show"
[[ "$(body_of 0001)" == $'Body line one\n  indented body line two' ]] || fail "show body: [$(body_of 0001)]"
[[ -z "$(status_of)" ]] || fail "add leaves the tree dirty"
[[ "$(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | sort)" == $'wiki/items/0001.md\nwiki/next/index.md\nwiki/now.md' ]] \
    || fail "add commit paths: $(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | tr '\n' ' ')"
run "$script" lint; want_rc 0 "lint after add"
run "$script" show 9999; [[ $rc -ne 0 ]] || fail "show of a missing id exits 0"

# add with a refused text keeps the file and writes nothing
put_item "$tmp/a2.txt" "one two three four five six seven eight nine" "Too many words in the title" "Body"
h="$(head_of)"
run "$script" add next --from "$tmp/a2.txt"; want_rc 2 "a nine-word title"
want_out "title" "a nine-word title"
[[ -f "$tmp/a2.txt" ]] || fail "a refused add removed the --from file"
[[ "$h" == "$(head_of)" ]] || fail "a refused add made a commit"
put_item "$tmp/a3.txt" "Title" "one two three four five six seven eight nine ten eleven twelve thirteen" "Body"
run "$script" add next --from "$tmp/a3.txt"; want_rc 2 "a thirteen-word description"
run "$script" add next --from "$tmp/does-not-exist.txt"; want_rc 2 "a missing --from file"
run "$script" add sometime --from "$tmp/a3.txt"; want_rc 2 "a bad status"

# C2: text only from a file
h="$(head_of)"
run "$script" add next "some item text"; want_rc 2 "a text argument to add"
run "$script" log "a log line"; want_rc 2 "a text argument to log"
run "$script" lesson DLV-012/tool "- a line"; want_rc 2 "a text argument to lesson"
run "$script" reserve "0063 x (run 2026-10-23-x)"; want_rc 2 "a text argument to reserve"
run "$script" edit 0001 --expect "$(printf '0%.0s' {1..64})" "new text"; want_rc 2 "a text argument to edit"
[[ "$h" == "$(head_of)" && -z "$(status_of)" ]] || fail "a text argument wrote something"
want_out "--from" "the text-argument refusal names --from"

# C2: the round trip of text that a shell or the guardrail hook would read
printf '%s\n' 'Nasty: backtick ` and $(id) and it'"'"'s and "quotes" and \n and git reset --hard and --no-verify' \
    '  second line with `code` and a trailing space ' '---' 'status: done' 'taken: run 2026-10-23-x' > "$tmp/nasty-body.txt"
{ printf '%s\n%s\n\n' 'Round trip title' 'It'"'"'s a `test` of $(x)'; cat "$tmp/nasty-body.txt"; } > "$tmp/nasty-add.txt"
run "$script" add later --from "$tmp/nasty-add.txt"; want_rc 0 "add of nasty text"
body_of 0002 > "$tmp/got.txt"
cmp -s "$tmp/got.txt" "$tmp/nasty-body.txt" || fail "add: the body is not byte for byte"
[[ "$("$script" list later)" == "0002 Round trip title: It's a \`test\` of \$(x)" ]] || fail "list later: $("$script" list later)"
run "$script" show 0002
hash="$(head -n 1 <<<"$out" | sed 's/^hash: //')"
{ printf '%s\n%s\n\n' 'Edited title' 'Edited description'; cat "$tmp/nasty-body.txt"; printf 'edited `again` $(x)\n'; } > "$tmp/nasty-edit.txt"
run "$script" edit 0002 --expect "$hash" --from "$tmp/nasty-edit.txt"; want_rc 0 "edit of nasty text"
body_of 0002 > "$tmp/got.txt"
{ cat "$tmp/nasty-body.txt"; printf 'edited `again` $(x)\n'; } > "$tmp/want.txt"
cmp -s "$tmp/got.txt" "$tmp/want.txt" || fail "edit: the body is not byte for byte"
front="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$DIRIGIBLE_WIKI/wiki/items/0002.md")"
[[ "$front" == *"status: later"* && "$front" != *"status: done"* ]] || fail "an edit with status lines in the body changed the status: $front"
[[ "$front" != *taken:* ]] || fail "an edit with taken in the body set taken: $front"
[[ "$(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | sort)" == $'wiki/items/0002.md\nwiki/later/index.md' ]] \
    || fail "edit commit paths: $(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | tr '\n' ' ')"
# a file that starts with a front matter block is refused
{ printf -- '---\nstatus: done\ntaken: run 2026-10-23-x\n---\n\nbody\n'; } > "$tmp/fm.txt"
run "$script" show 0002; hash="$(head -n 1 <<<"$out" | sed 's/^hash: //')"
h="$(head_of)"
run "$script" edit 0002 --expect "$hash" --from "$tmp/fm.txt"; want_rc 2 "an edit file with front matter"
[[ -f "$tmp/fm.txt" && "$h" == "$(head_of)" ]] || fail "a refused edit changed the wiki or removed its file"

# stale edit: show, take, edit with the old hash
run "$script" show 0001; old="$(head -n 1 <<<"$out" | sed 's/^hash: //')"
run "$script" take 0001 2026-10-23-demo; want_rc 0 "take"
run "$script" list next --taken 2026-10-23-demo
[[ "$out" == "0001 First item: The first item has a short description (taken: 2026-10-23-demo)" ]] || fail "list --taken: [$out]"
run "$script" list next --taken 2026-10-23-other
[[ -z "$out" ]] || fail "list --taken of another run: [$out]"
put_item "$tmp/e1.txt" "Stale title" "Stale description" "stale body"
h="$(head_of)"; n="$(commits_of)"
page_before="$(shasum "$DIRIGIBLE_WIKI/wiki/items/0001.md")"
run "$script" edit 0001 --expect "$old" --from "$tmp/e1.txt"; want_rc 75 "a stale edit"
want_out "the page changed; run scripts/wiki.py show 0001 again" "a stale edit"
[[ "$h" == "$(head_of)" && "$n" == "$(commits_of)" ]] || fail "a stale edit made a commit"
[[ "$page_before" == "$(shasum "$DIRIGIBLE_WIKI/wiki/items/0001.md")" ]] || fail "a stale edit changed the page"
[[ -f "$tmp/e1.txt" ]] || fail "a stale edit removed the --from file"
run "$script" take 0001 2026-10-23-demo2; [[ $rc -ne 0 ]] || fail "take of a taken item by another run exits 0"
run "$script" move 0001 done; want_rc 0 "move"
run "$script" count next; [[ "$out" == 0 ]] || fail "count next after a move: [$out]"
run "$script" list done; want_out "0001 First item" "list done"
run "$script" move 0001 sometime; want_rc 2 "move to a bad status"
run "$script" move 0042 done; [[ $rc -ne 0 ]] || fail "move of a missing id exits 0"
run "$script" lint; want_rc 0 "lint after take and move"

# lesson, lessons --seen-once
printf '%s\n' '- 2026-10-23 seen-once 2026-10-23-demo DLV-012/tool: Edit refuses a file that Bash read; use `Read` first.' > "$tmp/l1.txt"
run "$script" lesson DLV-012/tool --from "$tmp/l1.txt"; want_rc 0 "lesson"
[[ ! -e "$tmp/l1.txt" ]] || fail "lesson keeps the --from file"
printf '%s\n' '- 2026-10-23 applied 2026-10-23-demo DLV-012/tool: done.' '- 2026-10-24 seen-once 2026-10-24-x NEW-AGT-x/cost: second key.' > "$tmp/l2.txt"
run "$script" lesson DLV-012/tool --from "$tmp/l2.txt"; [[ $rc -ne 0 ]] || fail "a lesson line of another key is accepted"
printf '%s\n' '- 2026-10-23 applied 2026-10-23-demo DLV-012/tool: done.' > "$tmp/l2.txt"
run "$script" lesson DLV-012/tool --from "$tmp/l2.txt"; want_rc 0 "lesson second line"
printf '%s\n' '- 2026-10-24 seen-once 2026-10-24-x NEW-AGT-x/cost: another key.' > "$tmp/l3.txt"
run "$script" lesson NEW-AGT-x/cost --from "$tmp/l3.txt"; want_rc 0 "lesson of a new-style key"
[[ -f "$DIRIGIBLE_WIKI/wiki/lessons/DLV-012--tool.md" && -f "$DIRIGIBLE_WIKI/wiki/lessons/NEW-AGT-x--cost.md" ]] || fail "lesson pages: $(ls "$DIRIGIBLE_WIKI/wiki/lessons")"
run "$script" lessons --seen-once; want_rc 0 "lessons --seen-once"
[[ "$out" == $'- 2026-10-23 seen-once 2026-10-23-demo DLV-012/tool: Edit refuses a file that Bash read; use `Read` first.\n- 2026-10-24 seen-once 2026-10-24-x NEW-AGT-x/cost: another key.' ]] || fail "seen-once: [$out]"
run "$script" lesson bad-key --from "$tmp/l3.txt"; want_rc 2 "a bad key"
run "$script" lint; want_rc 0 "lint after lessons"
[[ "$(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | sort)" == $'wiki/lessons/NEW-AGT-x--cost.md\nwiki/lessons/index.md' ]] \
    || fail "lesson commit paths: $(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | tr '\n' ' ')"

# log, runs, now
printf '%s\n' '| 2026-10-23-demo | demo | open | |' > "$tmp/g1.txt"
run "$script" log --from "$tmp/g1.txt"; want_rc 0 "log"
[[ ! -e "$tmp/g1.txt" ]] || fail "log keeps the --from file"
printf '%s\n' '2026-10-23 line with `backtick`, $(x), it'"'"'s, git reset --hard, --no-verify.' '' '2026-09-30 an older line' > "$tmp/g2.txt"
cp "$tmp/g2.txt" "$tmp/g2.want"
run "$script" log --from "$tmp/g2.txt"; want_rc 0 "log of nasty text"
run "$script" runs; want_rc 0 "runs"
{ printf '%s\n' '2026-09-30 an older line' '| 2026-10-23-demo | demo | open | |'; sed -n 1p "$tmp/g2.want"; } > "$tmp/runs.want"
[[ "$out" == "$(cat "$tmp/runs.want")" ]] || fail "runs: [$out]"
[[ -f "$DIRIGIBLE_WIKI/wiki/log/2026-10.md" && -f "$DIRIGIBLE_WIKI/wiki/log/2026-09.md" ]] || fail "log pages: $(ls "$DIRIGIBLE_WIKI/wiki/log")"
for i in $(seq 1 30); do printf 'filler log line %s of 2026-10-24\n' "$i"; done > "$tmp/g3.txt"
run "$script" log --from "$tmp/g3.txt"; want_rc 0 "log of 30 lines"
run "$script" now; want_rc 0 "now"
[[ "$(rg -c '^filler log line' <<<"$out")" == 15 ]] || fail "now holds $(rg -c '^filler log line' <<<"$out") of the last log lines, want 15"
want_out "filler log line 30 of" "now"
want_out "2026-10-23-demo" "now lists the open run"
[[ "$out" != *"filler log line 15 of"* ]] || fail "now holds a log line older than the last 15"
run "$script" lint; want_rc 0 "lint after log"

# reserve, numbers
printf '%s\n' '0063 wiki tool (run 2026-10-23-ledger-wiki)' > "$tmp/r1.txt"
run "$script" reserve --from "$tmp/r1.txt"; want_rc 0 "reserve"
[[ ! -e "$tmp/r1.txt" ]] || fail "reserve keeps the --from file"
printf '%s\n' '0064 second `entry` (run 2026-10-23-other)' > "$tmp/r2.txt"
run "$script" reserve --from "$tmp/r2.txt"; want_rc 0 "second reserve"
run "$script" numbers; want_rc 0 "numbers"
[[ "$out" == Decision\ numbers*"0063 wiki tool (run 2026-10-23-ledger-wiki), 0064 second \`entry\` (run 2026-10-23-other)." ]] || fail "numbers: [$out]"
printf '%s\n' '0063 another title (run 2026-10-23-third)' > "$tmp/r3.txt"
h="$(head_of)"
run "$script" reserve --from "$tmp/r3.txt"; [[ $rc -ne 0 ]] || fail "a taken number is reserved again"
[[ "$h" == "$(head_of)" && -f "$tmp/r3.txt" ]] || fail "a refused reserve wrote or removed its file"
printf '%s\n' 'not an entry' > "$tmp/r4.txt"
run "$script" reserve --from "$tmp/r4.txt"; want_rc 2 "a reserve entry in a bad form"
run "$script" lint; want_rc 0 "lint after reserve"

# --- C7 lint refusals
newwiki lint1
put_item "$tmp/p.txt" "Linked item" "A page that the index lists" "body"
"$script" add next --from "$tmp/p.txt" >/dev/null 2>&1 || fail "lint1 add"
printf -- '---\ntype: Item\ntitle: "Hidden"\ndescription: "No index lists it"\nstatus: next\n---\n\nbody\n' > "$DIRIGIBLE_WIKI/wiki/items/0099.md"
run "$script" lint; want_rc 1 "a page with no index link"
want_out "0099.md" "a page with no index link"
want_out "no index.md links" "a page with no index link"
rm "$DIRIGIBLE_WIKI/wiki/items/0099.md"
run "$script" lint; want_rc 0 "lint after the hidden page is gone"
printf -- '- [0001](../items/0001.md): changed by hand\n' >> "$DIRIGIBLE_WIKI/wiki/next/index.md"
run "$script" lint; want_rc 1 "a changed generated index"
want_out "wiki/next/index.md" "a changed generated index"
want_out "differs from its generated text" "a changed generated index"
git -C "$DIRIGIBLE_WIKI" checkout -q -- wiki/next/index.md
printf -- '---\ntype: Item\ntitle: "Bad"\ndescription: "x"\nstatus: soon\n---\n\nbody\n' > "$DIRIGIBLE_WIKI/wiki/items/0001.md"
run "$script" lint; want_rc 1 "a bad status"
want_out "status" "a bad status"
git -C "$DIRIGIBLE_WIKI" checkout -q -- wiki/items/0001.md
printf '[gone](../nowhere.md)\n' >> "$DIRIGIBLE_WIKI/wiki/items/0001.md"
run "$script" lint; want_rc 1 "a broken link"
want_out "nowhere.md" "a broken link"
git -C "$DIRIGIBLE_WIKI" checkout -q -- wiki/items/0001.md
run "$script" lint; want_rc 0 "lint at the end of the C7 cases"

# --- C6 two writers at once
newwiki race
c0="$(commits_of)"
writer() {
    local tag="$1" i
    for i in $(seq 1 20); do
        put_item "$tmp/race-$tag-$i.txt" "Item $tag $i" "Description of item $tag $i" "Body of item $tag $i"
        "$script" add next --from "$tmp/race-$tag-$i.txt" >> "$tmp/race-$tag.log" 2>&1 || echo "failed $tag $i" >> "$tmp/race-fail.log"
    done
}
writer A &
pa=$!
writer B &
pb=$!
wait "$pa" "$pb"
pages="$(find "$DIRIGIBLE_WIKI/wiki/items" -name '*.md' | wc -l | tr -d ' ')"
[[ "$pages" == 40 ]] || fail "two writers: $pages pages, want 40"
[[ "$(( $(commits_of) - c0 ))" == 40 ]] || fail "two writers: $(( $(commits_of) - c0 )) new commits, want 40"
[[ -z "$(status_of)" ]] || fail "two writers: the tree is dirty: $(status_of | head -n 3)"
[[ ! -s "$tmp/race-fail.log" ]] || fail "two writers: failed writes: $(head -n 3 "$tmp/race-fail.log")"
run "$script" lint; want_rc 0 "lint after two writers"
[[ "$("$script" count next)" == 40 ]] || fail "two writers: count next $("$script" count next)"

# --- C6 the lock: a killed holder, index.lock, a live pid in the lock file, and a live holder
holder_py='
import fcntl, os, sys, time
fd = os.open(os.path.join(sys.argv[1], ".git", "wiki-write.lock"), os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
if len(sys.argv) > 3:
    page = os.path.join(sys.argv[1], sys.argv[3])
    os.makedirs(os.path.dirname(page), exist_ok=True)
    open(page, "w").write("half written\n")
open(sys.argv[2], "w").write("held\n")
time.sleep(120)
'
# start_holder <name> [<page>]: a process that holds the write lock (and writes a page), as HOLDER_PID.
start_holder() {
    python3 -c "$holder_py" "$DIRIGIBLE_WIKI" "$tmp/$1.held" ${2:+"$2"} &
    HOLDER_PID=$!
    holders+=("$HOLDER_PID")
    local i
    for i in $(seq 1 100); do [[ -s "$tmp/$1.held" ]] && return 0; sleep 0.1; done
    fail "the holder $1 did not take the lock"
}
stop_holder() { kill -9 "$1"; { wait "$1"; } 2>/dev/null; return 0; }
newwiki lock1
put_item "$tmp/k.txt" "After the kill" "A write after a killed holder" "body"
start_holder h1 wiki/items/0777.md
stop_holder "$HOLDER_PID"
t0="$(now_s)"
run "$script" add next --from "$tmp/k.txt"
t1="$(now_s)"
want_rc 1 "a write after a killed holder"
want_out "git -C $DIRIGIBLE_WIKI status" "a write after a killed holder"
elapsed_ok "$t0" "$t1" "< 1.0" || fail "a write after a killed holder took the lock too late: $t0 $t1"
[[ -f "$tmp/k.txt" ]] || fail "a refused write removed its file"
[[ ! -e "$DIRIGIBLE_WIKI/wiki/items/0001.md" ]] || fail "a refused write made a page"
rm "$DIRIGIBLE_WIKI/wiki/items/0777.md"
run "$script" add next --from "$tmp/k.txt"; want_rc 0 "a write after the repair"

: > "$DIRIGIBLE_WIKI/.git/index.lock"
put_item "$tmp/k2.txt" "Index lock" "A write with an index lock" "body"
h="$(head_of)"
run "$script" add next --from "$tmp/k2.txt"; want_rc 1 "a write with .git/index.lock"
want_out "index.lock" "a write with .git/index.lock"
[[ "$h" == "$(head_of)" && -f "$tmp/k2.txt" ]] || fail "an index.lock refusal wrote or removed its file"
rm "$DIRIGIBLE_WIKI/.git/index.lock"

printf '%s\n' "$$" > "$DIRIGIBLE_WIKI/.git/wiki-write.lock"
t0="$(now_s)"
run "$script" add next --from "$tmp/k2.txt"
t1="$(now_s)"
want_rc 0 "a lock file with a live pid and no holder"
elapsed_ok "$t0" "$t1" "< 1.0" || fail "a lock file with a live pid blocked a write: $t0 $t1"

start_holder h2
live="$HOLDER_PID"
put_item "$tmp/k3.txt" "Live holder" "A write while the lock is held" "body"
t0="$(now_s)"
run env DIRIGIBLE_WIKI_LOCK_WAIT=1 "$script" add next --from "$tmp/k3.txt"
t1="$(now_s)"
want_rc 75 "a live holder"
elapsed_ok "$t0" "$t1" ">= 1.0" || fail "a live holder: the wait was shorter than 1 s: $t0 $t1"
elapsed_ok "$t0" "$t1" "< 5.0" || fail "a live holder: the wait was longer than 5 s: $t0 $t1"
[[ -f "$tmp/k3.txt" ]] || fail "a lock timeout removed the --from file"
stop_holder "$live"
run "$script" add next --from "$tmp/k3.txt"; want_rc 0 "a write after the holder ended"

if ((failures > 0)); then
    echo "wiki.test.sh: $failures failure(s)"
    exit 1
fi
echo "wiki.test.sh: ok"
