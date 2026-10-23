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
g() { git -c user.name=t -c user.email=t@t "$@"; }
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

# --- a wiki commit uses the git config as it is: no -c flag, so no signing bypass and no fixed identity
mkdir -p "$tmp/gitstub"
cat > "$tmp/gitstub/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$tmp/git-args.log"
exec "$(command -v git)" "\$@"
EOF
chmod +x "$tmp/gitstub/git"
run env PATH="$tmp/gitstub:$PATH" DIRIGIBLE_WIKI="$tmp/cfg" "$script" init; want_rc 0 "init with a git stub"
put_item "$tmp/cfg-a.txt" "Config item" "A write under a git stub" "body"
run env PATH="$tmp/gitstub:$PATH" DIRIGIBLE_WIKI="$tmp/cfg" "$script" add next --from "$tmp/cfg-a.txt"; want_rc 0 "add with a git stub"
[[ "$(rg -c ' commit ' "$tmp/git-args.log")" -ge 2 ]] || fail "the git stub saw fewer than 2 commits: $(cat "$tmp/git-args.log")"
! rg -q -- '(^| )-c ' "$tmp/git-args.log" || fail "wiki.py ran git with a -c flag: $(rg -- '(^| )-c ' "$tmp/git-args.log" | head -n 1)"

# --- init turns off commit signing in the new wiki only (user 2026-10-23): one local config write
[[ "$(git -C "$tmp/cfg" config --local --get commit.gpgsign)" == false ]] || fail "init did not set commit.gpgsign false in the wiki"
[[ "$(rg -c ' config ' "$tmp/git-args.log")" == 1 ]] || fail "wiki.py wrote git config other than once: $(rg ' config ' "$tmp/git-args.log")"
rg -q -F -x -- "-C $tmp/cfg config --local commit.gpgsign false" "$tmp/git-args.log" || fail "the config write is not the local signing key of the wiki: $(rg ' config ' "$tmp/git-args.log")"

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

# --- C16 seed
seedrepo="$tmp/seedrepo"
mkdir -p "$seedrepo/scripts" "$seedrepo/docs/requirements" "$tmp/bin"
cp "$script" "$seedrepo/scripts/wiki.py"
cat > "$seedrepo/docs/requirements/features.md" <<'EOF'
# Features

| ID | Feature | From | State | Req |
|---|---|---|---|---|
| F01 | Multitrack recording, one track per input | Hindenburg PRO | done, Release 1 run 2 | R3 |
| F02 | Punch-in recording | Logic Pro | Later (Autopunch at a selection) | R7 |
| F03 | Pre-roll, record at the playhead | Hindenburg PRO | Release 6 | R7 |
| F04 | A feature that we do not build | user 2026-10-01 | Dropped (no demand) | - |
| F05 | Noise reduction on the render | Audacity | Release 6 | R10 |
EOF
cat > "$seedrepo/docs/requirements/releases.md" <<'EOF'
# Releases

## Release 1: record

1. **Session core (F01).** Done long ago.

## Release 6: polish

1. **Pre-roll (F03).** Record at the playhead after a pre-roll.
   - **A sub item (F03).** Not a numbered item.
2. **Old run (F01).** A run of done features only.
3. **Noise and punch (F05, F02).** Two parts in one run.
EOF
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/bash
[[ "$*" == "pr list --state merged "* ]] || { echo "gh stub: $*" >&2; exit 1; }
cat "$GH_STUB_JSON"
EOF
chmod +x "$tmp/bin/gh"
cat > "$tmp/prs.json" <<'EOF'
[{"number":10,"body":"## Summary\n\nx\n\n- Deferred: the zoom bar (F44)\n- Follow-up: rename the menu item\n- Other bullet\n"},
 {"number":11,"body":"- follow-up: speed test on Intel\nA line with deferred but no bullet\n"}]
EOF
seed="$seedrepo/scripts/wiki.py"
export DIRIGIBLE_WIKI="$tmp/seeded"
"$seed" init >/dev/null 2>&1 || fail "seed: init"
run "$seed" seed; want_rc 0 "seed"
[[ "$("$seed" count next)" == 4 && "$("$seed" count later)" == 1 ]] || fail "seed counts: next $("$seed" count next), later $("$seed" count later), want 4 and 1"
run "$seed" list next
for want in "F03 Pre-roll, record at the playhead" "F05 Noise reduction on the render" "Pre-roll" "Noise and punch"; do
    [[ "$out" == *"$want"* ]] || fail "seed list next lacks [$want]: $out"
done
[[ "$out" != *"F01"* && "$out" != *"F04"* && "$out" != *"Old run"* && "$out" != *"sub item"* ]] || fail "seed listed a done, dropped, or sub item: $out"
run "$seed" list later; [[ "$out" == "0001 F02 Punch-in recording: "* ]] || fail "seed list later: [$out]"
run "$seed" show 0001
want_out "Logic Pro" "seed body"
run "$seed" show 0002
want_out "Hindenburg" "seed body"
run "$seed" lint; want_rc 0 "lint of a seeded wiki"
[[ -z "$(git -C "$DIRIGIBLE_WIKI" status --porcelain)" ]] || fail "seed left the tree dirty"
before="$(tree_sums "$DIRIGIBLE_WIKI")"; h="$(git -C "$DIRIGIBLE_WIKI" rev-parse HEAD)"
run "$seed" seed; [[ $rc -ne 0 ]] || fail "seed on a wiki with items exits 0"
want_out "item" "seed on a wiki with items"
[[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" && "$h" == "$(git -C "$DIRIGIBLE_WIKI" rev-parse HEAD)" ]] || fail "a refused seed changed the wiki"

export DIRIGIBLE_WIKI="$tmp/seeded-lesson"
"$seed" init >/dev/null 2>&1
printf '%s\n' '- 2026-10-23 seen-once 2026-10-23-demo DLV-012/tool: a line.' > "$tmp/sl.txt"
"$seed" lesson DLV-012/tool --from "$tmp/sl.txt" >/dev/null 2>&1 || fail "seed: lesson"
before="$(tree_sums "$DIRIGIBLE_WIKI")"; h="$(git -C "$DIRIGIBLE_WIKI" rev-parse HEAD)"
run "$seed" seed; [[ $rc -ne 0 ]] || fail "seed on a wiki with one lesson and no item exits 0"
want_out "lesson" "seed on a wiki with one lesson"
[[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" && "$h" == "$(git -C "$DIRIGIBLE_WIKI" rev-parse HEAD)" ]] || fail "a refused seed changed the wiki with a lesson"

export DIRIGIBLE_WIKI="$tmp/seeded-log"
"$seed" init >/dev/null 2>&1
printf '%s\n' '2026-10-23 a log line' > "$tmp/sg.txt"
"$seed" log --from "$tmp/sg.txt" >/dev/null 2>&1 || fail "seed: log"
run "$seed" seed; [[ $rc -ne 0 ]] || fail "seed on a wiki with a changed Log page exits 0"
want_out "log" "seed on a wiki with a changed Log page"
[[ "$("$seed" count next)" == 0 ]] || fail "a refused seed wrote items"

export DIRIGIBLE_WIKI="$tmp/seeded-prs"
"$seed" init >/dev/null 2>&1
run env PATH="$tmp/bin:$PATH" GH_STUB_JSON="$tmp/prs.json" "$seed" seed --prs; want_rc 0 "seed --prs"
[[ "$("$seed" count next)" == 4 && "$("$seed" count later)" == 4 ]] || fail "seed --prs counts: next $("$seed" count next), later $("$seed" count later), want 4 and 4"
run "$seed" list later
for want in "the zoom bar" "rename the menu item" "speed test on Intel"; do
    [[ "$out" == *"$want"* ]] || fail "seed --prs lacks [$want]: $out"
done
[[ "$out" != *"Other bullet"* && "$out" != *"no bullet"* ]] || fail "seed --prs took a line that is no deferred bullet: $out"
run "$seed" lint; want_rc 0 "lint of a seeded wiki with PR items"
export DIRIGIBLE_WIKI="$tmp/seeded-nogh"
"$seed" init >/dev/null 2>&1
run env PATH="$tmp/bin:$PATH" GH_STUB_JSON="$tmp/does-not-exist.json" "$seed" seed --prs; [[ $rc -ne 0 ]] || fail "seed --prs with a failing gh exits 0"
[[ "$("$seed" count next)" == 0 && "$("$seed" count later)" == 0 ]] || fail "a seed with a failing gh wrote items"
rm -f "$seedrepo/docs/requirements/releases.md"
run "$seed" seed; [[ $rc -ne 0 ]] || fail "seed with no releases file exits 0"
want_out "releases" "seed with no releases file"

# --- the import: C1 to C3, C12, C13
mkrepo() { # mkrepo <name>: a repo with a copy of the tool and one commit
    mkdir -p "$tmp/$1/scripts"
    cp "$script" "$tmp/$1/scripts/wiki.py"
    g -C "$tmp/$1" init -q -b main
    g -C "$tmp/$1" add -A
    g -C "$tmp/$1" commit -q -m base
}
mkfix() { # mkfix <dir>: the three old files in their old shape
    mkdir -p "$1"
    {
        printf '%s\n' '# Backlog' '' '## Next' ''
        printf '%s\n' '- ALPHA ITEM (user 2026-10-01): the first next item with a body long enough to make a description of more than twelve words.'
        printf '%s\n' '  indented continuation line of the alpha item'
        printf '%s\n' '- upkeep DLV-012/tool (run x): an upkeep item with a cause key'
        printf '%s\n' '- (from run y) lower case item with no capital title and more than eight words in its first line'
        printf '%s\n' '- LONG CAPITAL TITLE WITH MORE THAN EIGHT WORDS IN IT (taken: run 2026-10-23-demo): a taken item.'
        printf '%s\n' '' '## Later' '' '- LATER ONE: a later item' '### User requests 2026-09-26'
        printf '%s \n' '- GROUPED ONE: a grouped later item with a trailing space'
        printf '%s\n' '- GROUPED TWO: second, with `backtick`, $(x), and git reset --hard'
    } > "$1/backlog.txt"
    {
        printf '%s\n' '# Run ledger' ''
        printf '%s\n' 'Decision numbers taken or reserved (reserve at Phase 2, one entry "<number> <title> (run <run folder>)"; the next free number is after the last entry): 0050 a (run 2026-09-01-a), 0051 b (run 2026-09-02-b, landed).'
        printf '%s\n' '' '| Run | Goal | Status | Result |' '|---|---|---|---|'
        printf '%s\n' '| 2026-09-01-a | a | done | PR 1 |' '| 2026-09-02-b | b | done | PR 2 |' ''
        printf '%s\n' 'Stop 2026-10-16 ~04:00 for an update, with `code`.' '' '| 2026-10-17-c | c | open | |' '2026-10-17 a free line'
    } > "$1/ledger.txt"
    printf '%s\n' '# Learnings' '' \
        '- 2026-09-23: an unkeyed line with `code`.' \
        '- 2026-10-01 seen-once 2026-10-01-run NEW-AGT-x/cost: the first line of a key.' \
        '- 2026-10-02 applied 2026-10-02-run NEW-AGT-x/cost: the second line of the same key.' \
        '- 2026-10-03 seen-once 2026-10-03-run DLV-012/tool: also names NEW-AGT-x/cost as a second key.' \
        '- 2026-10-05: another unkeyed line.' > "$1/learnings.txt"
}
sums_of() { (cd "$1" && shasum backlog.txt ledger.txt learnings.txt); }
import_args() { printf '%s\n' --backlog "$1/backlog.txt" --ledger "$1/ledger.txt" --learnings "$1/learnings.txt"; }
imp_run() { # imp_run <tool> <fixture dir> [extra args]: sets out and rc
    local tool="$1" dir="$2"
    shift 2
    run "$tool" import --backlog "$dir/backlog.txt" --ledger "$dir/ledger.txt" --learnings "$dir/learnings.txt" "$@"
}

mkrepo imp0
imp="$tmp/imp0/scripts/wiki.py"
mkfix "$tmp/fx0"
before_sums="$(sums_of "$tmp/fx0")"
export DIRIGIBLE_WIKI="$tmp/imported"
"$imp" init >/dev/null 2>&1 || fail "import: init"
imp_run "$imp" "$tmp/fx0"; want_rc 0 "import"
imp_out="$out"
[[ "$("$imp" count next)" == 4 && "$("$imp" count later)" == 3 ]] || fail "import counts: next $("$imp" count next), later $("$imp" count later), want 4 and 3"
[[ "$imp_out" == *"next 4, later 3"* ]] || fail "the import does not print the counts: $imp_out"
run "$imp" list next
want="$(printf '%s\n' '0001 ALPHA ITEM: the first next item with a body long enough to make a' \
    '0002 upkeep DLV-012/tool: an upkeep item with a cause key' \
    '0003 lower case item with no capital title and: more than eight words in its first line' \
    '0004 LONG CAPITAL TITLE WITH MORE THAN EIGHT WORDS: a taken item. (taken: 2026-10-23-demo)')"
[[ "$out" == "$want" ]] || fail "import list next: [$out]"
run "$imp" list later
[[ "$out" == *"0005 LATER ONE: a later item"* && "$out" == *"0006 GROUPED ONE: a grouped later item with a trailing space"* ]] || fail "import list later: [$out]"
run "$imp" show 0006; want_out 'group: "User requests 2026-09-26"' "a group heading becomes the group field"
run "$imp" list next --taken 2026-10-23-demo; want_out "0004" "a (taken: run ...) item gets the taken field"

# C2: the item lines rebuilt from the page bodies equal the item lines of the old file
: > "$tmp/rebuilt.txt"
for id in 0001 0002 0003 0004 0005 0006 0007; do
    body_of "$id" | awk 'NR == 1 { print "- " $0; next } { print }' >> "$tmp/rebuilt.txt"
done
# the fixture files are now stubs: read the frozen copies
grep -E '^(- |  )' "$DIRIGIBLE_WIKI/raw/backlog-cutover.md" > "$tmp/want-items.txt"
cmp -s "$tmp/rebuilt.txt" "$tmp/want-items.txt" || fail "import: the item lines are not byte for byte"

# C3: the lessons, the log, and the decision numbers
"$imp" lessons | sort > "$tmp/got-lessons.txt"
grep '^- ' "$DIRIGIBLE_WIKI/raw/learnings-cutover.md" | sort > "$tmp/want-lessons.txt"
cmp -s "$tmp/got-lessons.txt" "$tmp/want-lessons.txt" || fail "import: the lesson lines differ from the learnings lines"
[[ "$(ls "$DIRIGIBLE_WIKI/wiki/lessons" | tr '\n' ' ')" == "DLV-012--tool.md NEW-AGT-x--cost.md index.md unkeyed-2026-09.md unkeyed-2026-10.md " ]] \
    || fail "import lesson pages: $(ls "$DIRIGIBLE_WIKI/wiki/lessons" | tr '\n' ' ')"
run "$imp" lessons --seen-once; [[ "$(wc -l <<<"$out" | tr -d ' ')" == 2 ]] || fail "import: seen-once lines: [$out]"
"$imp" runs > "$tmp/got-runs.txt"
tail -n +4 "$DIRIGIBLE_WIKI/raw/ledger-cutover.md" > "$tmp/want-runs.txt"
cmp -s "$tmp/got-runs.txt" "$tmp/want-runs.txt" || fail "import: runs differ from the ledger lines after line 3"
run "$imp" numbers
[[ "$out" == "$(sed -n 3p "$DIRIGIBLE_WIKI/raw/ledger-cutover.md")" ]] || fail "import: numbers: [$out]"
run "$imp" now; want_out "2026-10-17-c" "now lists the open run after an import"
run "$imp" lint; want_rc 0 "lint after an import"
[[ -z "$(status_of)" ]] || fail "the import left the tree dirty"

# C12: the raw copies and the shasum
for name in backlog ledger learnings; do
    want_sum="$(printf '%s' "$before_sums" | awk -v n="$name.txt" '$2 == n { print $1 }')"
    [[ "$(shasum "$DIRIGIBLE_WIKI/raw/$name-cutover.md" | awk '{ print $1 }')" == "$want_sum" ]] || fail "raw copy of $name has another shasum"
    [[ "$imp_out" == *"$name $want_sum"* ]] || fail "the import does not print the shasum of $name: $imp_out"
    git -C "$DIRIGIBLE_WIKI" ls-files --error-unmatch "raw/$name-cutover.md" >/dev/null 2>&1 || fail "raw/$name-cutover.md is not committed"
done

# C13: the read-only stubs
for name in backlog ledger learnings; do
    f="$tmp/fx0/$name.txt"
    [[ "$(cat "$f")" == *"$tmp/imp0/scripts/wiki.py"* ]] || fail "the stub of $name does not name the main-checkout tool path"
    [[ ! -w "$f" ]] || fail "the stub of $name is writable"
    (echo x >> "$f") 2>/dev/null && fail "an append to the stub of $name worked"
done

# C13: a second import exits nonzero and leaves the wiki as it is
mkfix "$tmp/fx0b"
before="$(tree_sums "$DIRIGIBLE_WIKI")"; h="$(head_of)"
imp_run "$imp" "$tmp/fx0b"; [[ $rc -ne 0 ]] || fail "a second import exits 0"
want_out "item" "a second import"
[[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" && "$h" == "$(head_of)" ]] || fail "a second import changed the wiki"
[[ "$(cat "$tmp/fx0b/backlog.txt")" != *wiki.py* && -w "$tmp/fx0b/backlog.txt" ]] || fail "a refused second import made a stub"

# C13: a wiki with a lesson (no item) is refused too
export DIRIGIBLE_WIKI="$tmp/imp-lesson"
"$imp" init >/dev/null 2>&1
printf '%s\n' '- 2026-10-23 seen-once 2026-10-23-demo DLV-012/tool: a line.' > "$tmp/il.txt"
"$imp" lesson DLV-012/tool --from "$tmp/il.txt" >/dev/null 2>&1
before="$(tree_sums "$DIRIGIBLE_WIKI")"
imp_run "$imp" "$tmp/fx0b"; [[ $rc -ne 0 ]] || fail "an import into a wiki with a lesson exits 0"
[[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" ]] || fail "an import into a wiki with a lesson changed it"

# C2 control: the item lines must come back byte for byte, or the import writes nothing
sed 's/"".join(line + "\\n" for line in lines)/"".join(line.rstrip() + "\\n" for line in lines)/' "$imp" > "$tmp/imp0/scripts/wiki-mut.py"
chmod +x "$tmp/imp0/scripts/wiki-mut.py"
cmp -s "$imp" "$tmp/imp0/scripts/wiki-mut.py" && fail "the mutation of the page writer did not apply"
export DIRIGIBLE_WIKI="$tmp/imp-mut"
"$imp" init >/dev/null 2>&1
mkfix "$tmp/fx-mut"
before="$(tree_sums "$DIRIGIBLE_WIKI")"; h="$(head_of)"
imp_run "$tmp/imp0/scripts/wiki-mut.py" "$tmp/fx-mut"; [[ $rc -ne 0 ]] || fail "an import that changes a byte exits 0"
want_out "round trip" "an import that changes a byte"
[[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" && "$h" == "$(head_of)" ]] || fail "an import that changes a byte wrote the wiki"
[[ "$(cat "$tmp/fx-mut/backlog.txt")" != *wiki.py* && -w "$tmp/fx-mut/backlog.txt" ]] || fail "an import that changes a byte replaced an old file"

# C13: a read-only raw/ stops the import before the stubs
export DIRIGIBLE_WIKI="$tmp/imp-ro"
"$imp" init >/dev/null 2>&1
mkfix "$tmp/fx-ro"
want_sums="$(sums_of "$tmp/fx-ro")"
chmod a-w "$DIRIGIBLE_WIKI/raw"
imp_run "$imp" "$tmp/fx-ro"
chmod u+w "$DIRIGIBLE_WIKI/raw"
[[ $rc -ne 0 ]] || fail "an import with a read-only raw/ exits 0"
[[ "$want_sums" == "$(sums_of "$tmp/fx-ro")" ]] || fail "an import with a read-only raw/ changed an old file"
for name in backlog ledger learnings; do [[ -w "$tmp/fx-ro/$name.txt" ]] || fail "an old file is not writable after a stopped import: $name"; done

# C13: the worktree gate
mkrepo gate
g -C "$tmp/gate" worktree add -q -b feat/x "$tmp/gate-wt"
printf 'more\n' > "$tmp/gate/more.txt"
g -C "$tmp/gate" add -A
g -C "$tmp/gate" commit -q -m advance
gate="$tmp/gate/scripts/wiki.py"
mkfix "$tmp/fx-gate"
want_sums="$(sums_of "$tmp/fx-gate")"
export DIRIGIBLE_WIKI="$tmp/imp-gate"
"$gate" init >/dev/null 2>&1
before="$(tree_sums "$DIRIGIBLE_WIKI")"; h="$(head_of)"
tab="$(printf '\t')"
gate_refuses() { # gate_refuses <why> <message part> [extra args]
    local why="$1" part="$2"
    shift 2
    imp_run "$gate" "$tmp/fx-gate" "$@"
    [[ $rc -ne 0 ]] || fail "the gate: $why exits 0"
    [[ "$out" == *"$part"* ]] || fail "the gate: $why: output lacks [$part]: $out"
    [[ "$before" == "$(tree_sums "$DIRIGIBLE_WIKI")" && "$h" == "$(head_of)" ]] || fail "the gate: $why changed the wiki"
    [[ "$want_sums" == "$(sums_of "$tmp/fx-gate")" ]] || fail "the gate: $why changed an old file"
}
gate_refuses "no trees file" "--trees-checked"
gate_refuses "a trees file that does not exist" "$tmp/no-such-trees.txt" --trees-checked "$tmp/no-such-trees.txt"
printf '%s\t%s\t%s\t%s\n' "$tmp/elsewhere-wt" feat/z 2026-10-23-demo 6 > "$tmp/trees-miss.txt"
gate_refuses "a trees file that misses the tree" "$tmp/gate-wt" --trees-checked "$tmp/trees-miss.txt"
printf '%s\t%s\t%s\n' "$tmp/gate-wt" feat/x 2026-10-23-demo > "$tmp/trees-short.txt"
gate_refuses "a three-field line" "four" --trees-checked "$tmp/trees-short.txt"
printf '%s\t%s\t%s\t%s\n' "$tmp/gate-wt" feat/x 2026-10-23-demo 8 > "$tmp/trees-old8.txt"
gate_refuses "a phase 8 line on a branch without the caller HEAD" "feat/x" --trees-checked "$tmp/trees-old8.txt"
printf '%s\t%s\t%s\t%s\n' "$tmp/gate-wt" feat/x 2026-10-23-demo 6 > "$tmp/trees-ok.txt"
imp_run "$gate" "$tmp/fx-gate" --trees-checked "$tmp/trees-ok.txt"; want_rc 0 "a full trees file"
log_text="$(git -C "$DIRIGIBLE_WIKI" log --format=%B)"
[[ "$log_text" == *"$tmp/gate-wt"* && "$log_text" == *"feat/x"* ]] || fail "the import commit message lacks the trees file text"
[[ "$(cat "$tmp/fx-gate/backlog.txt")" == *"$tmp/gate/scripts/wiki.py"* ]] || fail "the stub does not name the main-checkout tool path"

# a phase 8 branch that holds the caller HEAD passes
g -C "$tmp/gate" worktree add -q -b feat/y "$tmp/gate-wt2"
printf '%s\t%s\t%s\t%s\n' "$tmp/gate-wt" feat/x 2026-10-23-demo 6 > "$tmp/trees-two.txt"
printf '%s\t%s\t%s\t%s\n' "$tmp/gate-wt2" feat/y 2026-10-23-other 8 >> "$tmp/trees-two.txt"
export DIRIGIBLE_WIKI="$tmp/imp-gate2"
"$gate" init >/dev/null 2>&1
mkfix "$tmp/fx-gate2"
imp_run "$gate" "$tmp/fx-gate2" --trees-checked "$tmp/trees-two.txt"; want_rc 0 "a phase 8 branch that holds the caller HEAD"

# --- C23 items that wait: the waits field, wait, unwait, list --ready, the now line, the lint
waitrepo="$tmp/waitrepo"
waitrun=2026-10-23-waitrun
mkdir -p "$waitrepo/scripts" "$waitrepo/.scratchpads/runs/$waitrun"
cp "$script" "$waitrepo/scripts/wiki.py"
g -C "$waitrepo" init -q -b main
set_run_status() { printf '%s\n' "# Run $waitrun" '' "- Status: $1" > "$waitrepo/.scratchpads/runs/$waitrun/run.md"; }
set_run_status open
wt="$waitrepo/scripts/wiki.py"
export DIRIGIBLE_WIKI="$tmp/waits"
"$wt" init >/dev/null 2>&1 || fail "waits: init"
for n in 1 2 3 4 5 6 7 8 9; do
    put_item "$tmp/w$n.txt" "Wait item $n" "Description of wait item $n" "body $n"
    "$wt" add next --from "$tmp/w$n.txt" >/dev/null 2>&1 || fail "waits: add $n"
done
# ready_is <id>...: list next --ready prints exactly these items, in order.
ready_is() {
    run "$wt" list next --ready
    [[ "$(cut -d' ' -f1 <<<"$out" | tr '\n' ' ')" == "$* " ]] || fail "list next --ready: [$out], want ids: $*"
}
# front_of <id>: the front matter of an item page.
front_of() { awk 'NR == 1 { next } /^---$/ { exit } { print }' "$DIRIGIBLE_WIKI/wiki/items/$1.md"; }
ready_is 0001 0002 0003 0004 0005 0006 0007 0008 0009
run "$wt" wait 0002 user; want_rc 0 "wait on the user"
run "$wt" wait 0003 item:0004; want_rc 0 "wait on an item"
run "$wt" wait 0005 "run:$waitrun"; want_rc 0 "wait on a run"
ready_is 0001 0004 0006 0007 0008 0009
run "$wt" list next; want_rc 0 "list next with waits"
want_out "0002 Wait item 2: Description of wait item 2 (waits: user)" "list next shows waits"
want_out "0003 Wait item 3: Description of wait item 3 (waits: item:0004)" "list next shows waits"
want_out "0005 Wait item 5: Description of wait item 5 (waits: run:$waitrun)" "list next shows waits"
[[ "$out" == "0001 Wait item 1: Description of wait item 1"$'\n'* ]] || fail "list next shows a waits value for an item that does not wait: $out"
run "$wt" move 0004 done; want_rc 0 "move the awaited item to done"
ready_is 0001 0003 0006 0007 0008 0009
set_run_status done
ready_is 0001 0003 0005 0006 0007 0008 0009
set_run_status open
ready_is 0001 0003 0006 0007 0008 0009
# set_run_line <line>: run.md with this exact status line.
set_run_line() { printf '%s\n' "# Run $waitrun" '' "$1" > "$waitrepo/.scratchpads/runs/$waitrun/run.md"; }
for form in '- Status: done (PR 168, 57707169..81629836; no tag, no DMG: workflow only)' \
    'Status: done. PR https://github.com/niltsiar/dirigible/pull/109 landed on main.' \
    '- Status: done' 'Status: done' '- Status: dropped (wrong name and scope)'; do
    set_run_line "$form"
    ready_is 0001 0003 0005 0006 0007 0008 0009
done
for form in '- Status: open (plan gate closed; next: Phase 4)' '- Status: deferred (features first)' \
    '- Status: doneness' '- Status: undone' '- Status:' 'Status: open'; do
    set_run_line "$form"
    ready_is 0001 0003 0006 0007 0008 0009
done
set_run_status open
run "$wt" move 0003 dropped; want_rc 0 "move a waiting item to dropped"
run "$wt" wait 0006 item:0003; want_rc 0 "wait on a dropped item"
ready_is 0001 0006 0007 0008 0009
run "$wt" wait 0009 run:2026-10-23-no-such-run; want_rc 0 "wait on a run with no folder"
ready_is 0001 0006 0007 0008 0009
run "$wt" unwait 0002; want_rc 0 "unwait"
ready_is 0001 0002 0006 0007 0008 0009
run "$wt" list next
[[ "$out" != *"0002 Wait item 2: Description of wait item 2 (waits"* ]] || fail "unwait leaves the waits value in list next"
[[ "$(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | sort)" == $'wiki/items/0002.md\nwiki/now.md' ]] \
    || fail "unwait commit paths: $(git -C "$DIRIGIBLE_WIKI" show --name-only --format= HEAD | tr '\n' ' ')"

# the now text counts the open items that wait for the user
run "$wt" wait 0002 user; want_rc 0 "wait on the user again"
run "$wt" wait 0006 user; want_rc 0 "wait on the user, second item"
run "$wt" wait 0009 user; want_rc 0 "wait on the user, third item"
run "$wt" move 0009 done; want_rc 0 "move a waiting item to done"
run "$wt" now; want_rc 0 "now with waits"
want_out "Waiting for the user: 2 (0002, 0006)." "now lists the items that wait for the user"
run "$wt" unwait 0002; want_rc 0 "unwait before the now count"
run "$wt" unwait 0006; want_rc 0 "unwait before the now count"
run "$wt" now
want_out "Waiting for the user: 0." "now with no waiting item"

# wait and unwait refuse and write nothing
h="$(head_of)"; n="$(commits_of)"
refuse_wait() {
    local want="$1"
    shift
    run "$wt" "$@"
    [[ $rc -eq $want ]] || fail "$*: exit $rc, want $want: $out"
    [[ "$h" == "$(head_of)" && "$n" == "$(commits_of)" && -z "$(status_of)" ]] || fail "$*: it wrote"
}
refuse_wait 1 wait 0006 item:9999
refuse_wait 1 wait 0099 user
refuse_wait 1 wait 0008 item:0008
want_out "cycle" "a wait of an item on itself"
refuse_wait 2 wait 0006 later
refuse_wait 2 wait 0006 item:xyz
refuse_wait 2 wait 0006 run:Bad_Name
refuse_wait 2 wait 0006 user:0002
refuse_wait 2 wait 0006 "item:0007 extra"
refuse_wait 1 unwait 0007
refuse_wait 1 unwait 0099
run "$wt" wait 0007 item:0008; want_rc 0 "first wait of a pair"
h="$(head_of)"; n="$(commits_of)"
refuse_wait 1 wait 0008 item:0007
want_out "cycle" "a cycle of two items"
run "$wt" wait 0006 item:0007; want_rc 0 "a chain of waits"
h="$(head_of)"; n="$(commits_of)"
refuse_wait 1 wait 0008 item:0006
want_out "cycle" "a cycle of three items"
[[ "$(front_of 0008)" != *waits:* ]] || fail "a refused cycle left a waits value"
ready_is 0001 0002 0008
run "$wt" lint; want_rc 0 "lint with waits"

# edit and move never change waits, and a body line never sets it
put_item "$tmp/we1.txt" "Edited wait title" "Edited wait description" "waits: user" "status: done"
run "$wt" show 0007; hash="$(head -n 1 <<<"$out" | sed 's/^hash: //')"
want_out "waits: item:0008" "show prints waits"
run "$wt" edit 0007 --expect "$hash" --from "$tmp/we1.txt"; want_rc 0 "edit of a waiting item"
front="$(front_of 0007)"
[[ "$front" == *"waits: item:0008"* && "$front" != *"waits: user"* && "$front" == *"status: next"* ]] || fail "edit changed waits or status: $front"
run "$wt" move 0007 later; want_rc 0 "move of a waiting item"
run "$wt" list later
want_out "0007 Edited wait title: Edited wait description (waits: item:0008)" "move keeps waits"
put_item "$tmp/we2.txt" "Edited plain title" "Edited plain description" "waits: user"
run "$wt" show 0001; hash="$(head -n 1 <<<"$out" | sed 's/^hash: //')"
run "$wt" edit 0001 --expect "$hash" --from "$tmp/we2.txt"; want_rc 0 "edit of an item with no waits"
[[ "$(front_of 0001)" != *waits:* ]] || fail "an edit with a waits line in the body set waits: $(front_of 0001)"

# the lint fails on a waits value that is no kind or names a missing item
for bad in "item:9999" "soon" "run:Bad_Name" "item:"; do
    printf -- '---\ntype: Item\ntitle: "Wait item 6"\ndescription: "Description of wait item 6"\nstatus: next\nwaits: %s\n---\n\nbody 6\n' "$bad" > "$DIRIGIBLE_WIKI/wiki/items/0006.md"
    run "$wt" lint; want_rc 1 "lint of waits: $bad"
    want_out "0006.md: waits" "lint of waits: $bad"
done
git -C "$DIRIGIBLE_WIKI" checkout -q -- wiki/items/0006.md
run "$wt" lint; want_rc 0 "lint after the bad waits value is gone"

if ((failures > 0)); then
    echo "wiki.test.sh: $failures failure(s)"
    exit 1
fi
echo "wiki.test.sh: ok"
