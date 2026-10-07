#!/bin/bash
# Check that git-guardrails.sh blocks and allows the right commands, and that the post-commit hook
# of .githooks deletes the commit message file. Run by `make check`.
set -uo pipefail
hook="$(dirname "$0")/git-guardrails.sh"
failures=0

# Build the hook input with plutil, the same tool the hook reads it with (no jq on macOS 14).
input="$(mktemp)"
tmp="$(mktemp -d)"
trap 'rm -f "$input"; rm -rf "$tmp"' EXIT

expect() {
  local want="$1" command="$2" got
  plutil -create xml1 "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert tool_input.command -string "$command" "$input"
  plutil -convert json "$input"
  "$hook" < "$input" 2>/dev/null
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $command"; failures=$((failures + 1)); }
}

expect block 'git push --force origin feat/x'
expect block 'git push -f origin feat/x'
expect block 'git push origin +feat/x'
expect block 'git push origin main'
expect block 'git push origin HEAD:main'
expect block 'git reset --hard HEAD~1'
expect block 'git clean -fd'
expect block 'git branch -D feat/x'
expect block 'git branch -d -f feat/x'
expect block 'git checkout .'
expect block 'git restore .'
expect block 'git switch feat/x --discard-changes'
expect block 'git switch -f main'
expect block 'git stash drop'
# A forced worktree remove deletes the uncommitted work of the tree.
expect block 'git worktree remove --force ../wt'
expect block 'git worktree remove -f ../wt'
expect block 'git -C /repo worktree remove ../wt --force'
expect allow 'git worktree remove ../wt'
expect block 'git commit -m "x" --no-verify'
expect block 'git commit -n -m "x"'
expect block 'git config --local core.hooksPath /dev/null'
expect block 'git config --local --unset core.hooksPath'
expect block 'gh pr merge 3 --rebase --admin'
expect block 'git -C . reset --hard'
expect block 'git -C /repo push -f origin feat/x'
expect block 'git -c core.hooksPath=/dev/null commit -m x'
expect block 'git push origin feat/x:main'
expect block 'git push origin HEAD:refs/heads/main'
expect block 'git push -uf origin feat/x'
expect block 'make check && git push origin main'
expect block 'git status; git reset --hard'
expect block 'env X=1 git push -f origin feat/x'
expect block 'bash -c "git push -f origin feat/x"'
expect block 'git commit -n -m x | cat'
# An absolute message path can name the file of another work tree (run flakes-2).
expect block 'git commit -F /Users/x/repo/.scratchpads/commit-msg.txt'
expect block 'git -C /Users/x/wt commit -F /Users/x/repo/.scratchpads/commit-msg.txt'
expect block 'git commit --file=/Users/x/repo/.scratchpads/commit-msg.txt'
expect allow 'git -C /Users/x/wt commit -F .scratchpads/commit-msg.txt'
# Only that relative path: a relative, ~, or $HOME path can name another tree too (code gate 1).
expect block 'git commit -F ../repo/.scratchpads/commit-msg.txt'
expect block 'git commit -F ~/repo/.scratchpads/commit-msg.txt'
expect block 'git commit -F "$HOME/repo/.scratchpads/commit-msg.txt"'
expect block 'git commit --file ../wt/.scratchpads/notes.txt'
expect block 'git commit -F /tmp/commit-msg.txt'
expect allow 'git commit --file=.scratchpads/commit-msg.txt'
expect allow 'git commit -F "/tmp/release notes.txt"'
expect allow 'git commit -m "read .scratchpads/commit-msg.txt"'

expect allow 'git push -u origin feat/multitrack-capture'
expect allow 'git push origin chore/refine-setup'
expect allow 'git branch -d feat/x'
expect allow 'git switch main'
expect allow 'git switch -c feat/x'
expect allow 'git commit -m "feat(capture): record two devices"'
expect allow 'git config --local core.hooksPath .githooks'
expect allow 'git config --local --get core.hooksPath'
expect allow 'gh pr merge 3 --rebase --delete-branch'
expect allow 'git stash push -m wip'
expect allow 'make check'
expect allow 'git -C /repo status'
expect allow 'git push -u origin feat/main-window'
expect allow 'git push --follow-tags origin feat/x'
# One segment of a chained command must not match a pattern with a word of the next segment.
expect allow 'git push -u origin feat/x && gh pr create --base main --title x'
expect allow 'git commit -F msg.txt; sed -n 1p file'
expect allow 'git commit -F msg.txt && sed -n 1p file'
expect allow 'git push -u origin feat/x || gh pr view --json baseRefName | grep main'

# A commit in one command with make check runs only after a green check: only && joins them.
expect block 'make check > log 2>&1; echo "exit $?"; git commit -m "x"'
expect block 'make check || true && git commit -m "x"'
expect block 'make check | tail -3 && git commit -m "x"'
expect block $'make check\ngit commit -m "x"'
expect allow 'make check && git commit -m "x"'
expect allow 'git add a && make check > log 2>&1 && grep -c ok log && git commit -F msg.txt'
expect allow $'make check > log 2>&1 \\\n  && git commit -m "x"'
# The regex matches make check as a prefix, so make check-changed gets the same rule.
expect block 'make check-changed; git commit -m "x"'
expect allow 'make check-changed > log 2>&1 && git commit -m "x"'
# The inner-commit check of a slice: FILTER is test names with spaces between them.
expect allow "make check-changed FILTER='ClipTests TrackTests' > log 2>&1 && git commit -F m.txt"
# Only the check-changed recipe writes the pass stamp. A direct write skips the land check.
expect block 'echo abc >> .git/dirigible-check-stamp'
expect block 'cp x "$(git rev-parse --git-path dirigible-check-stamp)"'
expect block 'scripts/check-stamp.sh write abc clean def check'
expect block 'bash scripts/check-stamp.sh  write abc clean def check'
expect allow 'scripts/check-stamp.sh read origin/main'
expect allow 'scripts/check-stamp.test.sh'
# Only a passing make test-slow writes the slow-run date. A direct write skips the daily slow run.
expect block 'date +%F > .git/dirigible-slow-date'
expect block 'echo 2026-01-01 > "$(git rev-parse --git-common-dir)/dirigible-slow-date"'
expect allow 'make test-slow'
expect allow 'scripts/check-changed.test.sh'

# A quoted main is the same push to main.
expect block "git push origin 'main'"
expect block 'git push origin "main"'
expect block "git push origin HEAD:'refs/heads/main'"
expect block 'git push origin "feat/x:main"'
expect allow "git push -u origin 'feat/main-feature'"
expect allow 'git push -u origin "main-feature"'
# Any character that cannot be in a branch name ends main. Any white space separates the words.
expect block '(git push origin main)'
expect block 'git push origin main>log 2>&1'
expect block $'git push origin \\\nmain'
expect block $'git push\torigin main'
expect block $'git\tpush origin main'
expect block $'git -C\t/repo push origin main'
expect block 'git  push  origin  main'
expect block $'git push\t-f origin feat/x'
expect block 'git push origin "main":feat/x'
expect allow 'git push -u origin main-feature'
expect allow 'git push origin feat/x > main.log 2>&1'

# The hook matches quoted text too. Each block message gives the reason and tells how to write data.
expect_message() {
  local reason="$1" msg
  expect block "$2"
  msg="$("$hook" < "$input" 2>&1)"
  [[ "$msg" == *"$reason"* && "$msg" == *"If the matched text is only data, write it with the Write tool"* ]] \
    || { echo "FAIL: no reason or no data hint in the message: $2"; failures=$((failures + 1)); }
}
expect_message "matches '--no-verify'" "git commit -m 'docs(agents): the hook blocks --no-verify'"
expect_message 'without &&' $'cat > notes.md <<\'EOF\'\nRun make check; then git commit.\nEOF'
# git -C <path> is the same commit for the make-check rule.
expect block 'make check-changed > log 2>&1; git -C /x/wt commit -F .scratchpads/commit-msg.txt'

# A decisions.tsv row joined after a commit or a build by ;, a newline, or a pipe can come before the
# status is read (run 2026-10-07-heap-corruption: a failed commit was logged with the old HEAD).
ld='.claude/skills/deliver/scripts/log-decision.sh r 4 a b c d'
expect block "git commit -F .scratchpads/commit-msg.txt; $ld"
expect block $'git commit -F .scratchpads/commit-msg.txt\n'"$ld"
expect block $'make\n'"$ld"
expect block "make test-filter FILTER=X > log 2>&1; $ld"
expect block "swift test; $ld"
expect block "git -C /x/wt commit -F .scratchpads/commit-msg.txt; $ld"
expect block "make test-filter FILTER=X | tail -3 && log-decision.sh r 4 a b c VERIFIED"
expect allow "git commit -F .scratchpads/commit-msg.txt && $ld"
expect allow "make test-filter FILTER=X > log 2>&1 && $ld"
expect allow "make test-filter FILTER=X > log 2>&1 || $ld"
expect allow "$ld"
# A background job: the row comes before make ends. A redirect with & is not a background job.
expect block "make test > log 2>&1 & $ld"
expect allow "make test &> log && $ld"
expect allow "make test >& log && $ld"
expect allow "$ld; make lint"
expect allow "remake; $ld"
expect allow $'make lint \\\n  && '"$ld"
# Each run of tabs and spaces is one space, as in the other rules.
expect block "git  commit -F .scratchpads/commit-msg.txt; $ld"
expect block $'make\tcheck; git commit -m x'
expect_message 'in its own command' "swift build; $ld"

# The project settings parse, and register this hook as a PreToolUse hook for Bash.
settings="$(dirname "$0")/../settings.json"
python3 -m json.tool "$settings" >/dev/null 2>&1 || { echo "FAIL: .claude/settings.json does not parse"; failures=$((failures + 1)); }
python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
ok = any(e.get("matcher") == "Bash"
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/git-guardrails.sh") for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$settings" 2>/dev/null || { echo "FAIL: .claude/settings.json does not register git-guardrails.sh for Bash"; failures=$((failures + 1)); }

# The shipped post-commit hook deletes .scratchpads/commit-msg.txt of the work tree that commits, so
# the next `git commit -F` cannot take a stale message. A worktree uses the hooks folder of the main
# checkout, and the hook deletes the file of the worktree only. With no file, the hook exits 0.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
gc() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty "${@:2}"; }
post_fail() { echo "FAIL: post-commit: $1"; failures=$((failures + 1)); }
git init -q "$tmp/r"
mkdir -p "$tmp/r/.githooks" "$tmp/r/.scratchpads"
cp "$(dirname "$0")/../../.githooks/post-commit" "$tmp/r/.githooks/" || post_fail 'no .githooks/post-commit'
git -C "$tmp/r" config core.hooksPath "$tmp/r/.githooks"
printf 'one\n' > "$tmp/r/.scratchpads/commit-msg.txt"
gc "$tmp/r" -F .scratchpads/commit-msg.txt || post_fail 'a commit with -F failed'
[[ ! -e "$tmp/r/.scratchpads/commit-msg.txt" ]] || post_fail 'the message file is still there after the commit'
gc "$tmp/r" -m two || post_fail 'a commit with no message file failed'
(cd "$tmp/r" && .githooks/post-commit) || post_fail "the hook exits $? with no message file"
git -C "$tmp/r" worktree add -q "$tmp/w" 2>/dev/null || post_fail 'git worktree add failed'
mkdir -p "$tmp/w/.scratchpads"
printf 'main\n' > "$tmp/r/.scratchpads/commit-msg.txt"
printf 'three\n' > "$tmp/w/.scratchpads/commit-msg.txt"
gc "$tmp/w" -F .scratchpads/commit-msg.txt || post_fail 'a commit in the worktree failed'
[[ ! -e "$tmp/w/.scratchpads/commit-msg.txt" ]] || post_fail 'the worktree message file is still there'
[[ "$(cat "$tmp/r/.scratchpads/commit-msg.txt" 2>/dev/null)" == main ]] || post_fail 'a worktree commit deleted the file of the main checkout'

# The shipped pre-commit hook refuses a commit when core.hooksPath is not exactly .githooks: with an
# absolute path, each worktree runs the hooks of the main checkout. With .githooks, the hook of the
# worktree runs make lint, which fails here because the repo has no Makefile.
pre_fail() { echo "FAIL: pre-commit: $1"; failures=$((failures + 1)); }
git init -q "$tmp/p"
mkdir -p "$tmp/p/.githooks"
cp "$(dirname "$0")/../../.githooks/pre-commit" "$tmp/p/.githooks/" || pre_fail 'no .githooks/pre-commit'
git -C "$tmp/p" add .githooks
gc "$tmp/p" -m hook || pre_fail 'the commit of the hook failed'
git -C "$tmp/p" worktree add -q "$tmp/pw" 2>/dev/null || pre_fail 'git worktree add failed'
git -C "$tmp/p" config core.hooksPath "$tmp/p/.githooks"
gc "$tmp/pw" -m absolute 2>"$tmp/err" && pre_fail 'a commit with an absolute hooks path passed'
grep -q 'make setup' "$tmp/err" || pre_fail 'the refusal does not name make setup'
git -C "$tmp/p" config core.hooksPath .githooks
gc "$tmp/pw" -m relative 2>"$tmp/err" && pre_fail 'a commit with no Makefile passed'
grep -q lint "$tmp/err" || pre_fail 'the hook of the worktree did not run make lint'
grep -q 'make setup' "$tmp/err" && pre_fail 'the hook names make setup with the .githooks path'

# The shipped commit-msg hook refuses a word pair ("10 before, 11 after") that no staged budgeted
# file shows: wc -w at HEAD or HEAD^ (an amend) before, in the index after; a missing copy counts 0.
# Run 2026-10-07-upkeep-batch-3 wrote 978 for 979 and 772 for 774.
msg_fail() { echo "FAIL: commit-msg: $1"; failures=$((failures + 1)); }
m="$tmp/m"
git init -q "$m"
mkdir -p "$m/.githooks" "$m/docs/workflow"
cp "$(dirname "$0")/../../.githooks/commit-msg" "$m/.githooks/" || msg_fail 'no .githooks/commit-msg'
git -C "$m" config core.hooksPath .githooks
printf 'path\twords\tdecision\na.md\t100\tx\nb.md\t100\tx\nd/\t100\tx\nTOTAL\t200\tx\n' > "$m/docs/workflow/budgets.tsv"
words() { seq "$2" | sed 's/^/w/' > "$m/$1"; }
words a.md 10
git -C "$m" add -A
gc "$m" -m 'first: 0 before, 10 after' || msg_fail 'a first commit (no HEAD) was refused'
echo x > "$m/other.txt"
git -C "$m" add other.txt
gc "$m" -m 'other: 3 before, then a change' || msg_fail 'a comma form with no after number was refused'
refused() {
  local before after
  before="$(git -C "$m" rev-parse HEAD)"
  gc "$m" "$@" 2>"$tmp/err" && msg_fail "a wrong pair passed: $*"
  after="$(git -C "$m" rev-parse HEAD)"
  [[ "$before" == "$after" ]] || msg_fail "HEAD moved after a refusal: $*"
  grep -q 'a.md\|before' "$tmp/err" || msg_fail "the refusal names no pair or count: $(cat "$tmp/err")"
}
echo y > "$m/other2.txt"
git -C "$m" add other2.txt
refused -m 'x: 10 before, 11 after'
git -C "$m" reset -q other2.txt
words a.md 11
git -C "$m" add a.md
refused -m 'x: 10 before, 12 after'
refused -m 'x: 9 before, 11 after'
gc "$m" -m 'x: 10 before, 11 after' || msg_fail 'a true pair was refused'
gc "$m" --amend -m 'x: 10 words before, 11 after' || msg_fail 'a message-only amend with a pair from HEAD^ was refused'
gc "$m" --amend -m $'x: 10 before,\n\n11 after' || msg_fail 'a pair split by a blank line was refused'
printf 'r\n' > "$m/rules.tsv"
git -C "$m" add rules.tsv
gc "$m" --amend -m 'x: 10 before, 11 after' || msg_fail 'an amend that stages only rules.tsv was refused'
gc "$m" -m 'no pair here' || msg_fail 'a message with no pair was refused'
words b.md 3
git -C "$m" add b.md
gc "$m" -m 'new file: 0 before, 3 after' || msg_fail 'a new budgeted file was refused'
git -C "$m" rm -q a.md
gc "$m" -m 'delete: 11 before, 0 after' || msg_fail 'a staged delete was refused'
[[ "$(printf 'a: 5 words before,\n6 after; b: 7 before and after; c: 3 before, then\n' | "$m/.githooks/commit-msg" --pairs)" == $'5 6\n7 7' ]] \
  || msg_fail "--pairs prints: $(printf 'a: 5 words before,\n6 after; b: 7 before and after\n' | "$m/.githooks/commit-msg" --pairs 2>&1)"

# Unreadable input fails closed.
printf 'not json' | "$hook" 2>/dev/null
[[ $? -eq 2 ]] || { echo "FAIL: unreadable input was allowed"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "git-guardrails: all cases pass" || exit 1
