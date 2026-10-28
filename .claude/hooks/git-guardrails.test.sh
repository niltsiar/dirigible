#!/bin/bash
# Check that git-guardrails.sh blocks and allows the right commands, and that the post-commit hook
# of .githooks deletes the commit message file. It also checks agent-guard.sh, the hook of the tools
# that brief an agent, usage-hook.sh, the hook that gives the usage mode at an agent start,
# handback-guard.sh, the hook that refuses a hand-back while a background task runs, agent-clock.sh,
# the hook that stops a subagent after 90 active minutes, and write-guard.sh, the hook that refuses a
# Write over an existing run file. Run by `make check`.
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

# expect_agent <want> <command>: as expect, with agent_id in the input, as in the input of a subagent.
# The message of a block goes to $tmp/agent.err.
expect_agent() {
  local want="$1" command="$2" got
  plutil -create xml1 "$input"
  plutil -insert agent_id -string a1 "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert tool_input.command -string "$command" "$input"
  plutil -convert json "$input"
  "$hook" < "$input" 2>"$tmp/agent.err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: subagent expected $want, got $got: $command"; failures=$((failures + 1)); }
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
# Only the -F of the commit counts: a later -F of another command neither hides a wrong path nor
# blocks a right one.
expect block 'git commit -F ../main/.scratchpads/commit-msg.txt then rg -F foo bar'
expect allow 'git commit -F .scratchpads/commit-msg.txt then rg -F .scratchpads/runs/x/rows .gitignore'
expect block 'git commit -F ../other/.scratchpads/commit-msg.txt then git commit -F .scratchpads/commit-msg.txt'
# The commit ends at the first command separator, so a commit with no -F does not take the -F of a
# later command.
expect allow 'git commit -m fix && rg -F .scratchpads/runs/x/rows .gitignore'
expect allow 'git commit -m fix; rg -F .scratchpads/runs/x/rows .gitignore'
expect allow 'git commit -m fix | rg -F .scratchpads/runs/x/rows'
expect allow 'git commit -m fix & rg -F .scratchpads/runs/x/rows .gitignore'

expect allow 'git push -u origin feat/multitrack-capture'
expect allow 'git push origin chore/refine-setup'
expect allow 'git branch -d feat/x'
expect allow 'git switch main'
expect allow 'git switch -c feat/x'
expect allow 'git commit -m "feat(capture): record two devices"'
expect allow 'git config --local core.hooksPath .githooks'
expect allow 'git config --local --get core.hooksPath'
# A read of the hooks path with no value is allowed (user decision of the retro, option A). A write
# chained after a read, and each other config action, stays blocked.
expect allow 'git config core.hooksPath'
expect allow 'git config --local core.hooksPath'
expect allow 'echo "$(git config core.hooksPath)"'
expect block 'git config core.hooksPath x; ls'
expect block 'git config core.hooksPath; git -c core.hooksPath=/dev/null commit -m x'
expect block 'git config --unset-all core.hooksPath'
expect block 'git config --replace-all core.hooksPath x'
expect block 'git config --add core.hooksPath x'
# The key matches in any case. The read form must start a command, and its flags come in any order
# (code gate item B).
expect block 'git config core.hookspath x'
expect block 'git config CORE.HOOKSPATH /dev/null'
expect block 'git -c core.hookspath=/x commit -m x'
expect block 'xargs git config core.hooksPath'
expect block 'echo x | xargs git config core.hooksPath'
expect allow 'git config core.hookspath'
expect allow 'git config --get --local core.hooksPath'
expect allow 'git -C /repo config --local --get core.hooksPath'
expect allow 'git config get core.hooksPath'
expect allow 'git config get --local core.hooksPath'
expect allow 'git config core.hooksPath; git config --get core.hooksPath'
expect allow 'git config core.hooksPath && git status'
# Each read form is allowed: --get, --get-all, --show-origin, --worktree, --local, a stderr redirect
# to /dev/null, and a chain member. A value, --unset, --add, and --replace-all stay blocked.
expect allow 'git config --get-all core.hooksPath'
expect allow 'git config --show-origin --get-all core.hooksPath'
expect allow 'git config --worktree --get core.hooksPath'
expect allow 'git config --local core.hooksPath 2>/dev/null'
expect allow 'git config --get core.hooksPath 2>/dev/null; git status'
expect allow 'echo "hooks: $(git config --get core.hooksPath 2>/dev/null)"'
expect block 'git config --worktree core.hooksPath x'
expect block 'git config --get-all core.hooksPath x'
expect block 'git config --show-origin --unset core.hooksPath'
expect block 'git config --get core.hooksPath 2>/dev/null; git config --add core.hooksPath x'
expect block 'gh pr merge 3 --rebase --delete-branch'
expect allow 'git stash push -m wip'
expect allow 'make check'
expect allow 'git -C /repo status'
expect allow 'git push -u origin feat/main-window'
expect allow 'git push --follow-tags origin feat/x'
# A release tag comes only from scripts/tag-release.sh: a hand tag, a tag delete, or a tag push
# blocks, and the message names the script. A list of the tags passes.
expect block 'git tag -a v0.3.10 -m x'
expect block 'git tag v0.3.10 abc123'
expect block 'git -C ../wt tag -d v0.3.10'
expect block 'git push origin v0.3.10'
expect block 'git push --tags'
expect block 'git push origin refs/tags/v1'
expect block 'cd x && git tag -f v1'
expect allow 'git tag'
expect allow "git tag -l 'v0.3.*'"
expect allow 'git tag --list'
expect allow 'git tag --points-at HEAD'
# Every read form passes: a note list, a sort, a format, a column, and a verify. --sort, --format,
# and --column make a tag when a name follows and no list flag does, so a name blocks them.
expect allow 'git tag -n'
expect allow 'git tag -n5 v0.3.10'
expect allow 'git tag -ln'
expect allow 'git tag --sort=-v:refname | head -3'
expect allow "git tag --sort=-creatordate --format='%(refname) %(creatordate)'"
expect allow 'git tag --format=%(refname)'
expect allow 'git tag --column'
expect allow 'git tag -v v0.3.10'
expect allow 'git tag --verify v0.3.10'
expect allow "git tag -l 'v0.3.*' --sort=-v:refname"
expect block 'git tag --sort=-v:refname v1'
expect block "git tag --format='%(refname)' 'v1'"
expect block 'git tag --column v1'
expect block 'git tag -n -a v1 -m x'
expect allow 'scripts/tag-release.sh 0.3.10 abc123 run'
expect allow 'git push origin chore/x'
expect allow "rg -n 'git tag -d' scripts"
got="$(printf '{"tool_input":{"command":"git tag -d v0.3.10"}}' | "$hook" 2>&1)"
[[ "$got" == *scripts/tag-release.sh* ]] ||
  { echo "FAIL: the tag block message does not name scripts/tag-release.sh: $got"; failures=$((failures + 1)); }
# A pull request merges only through scripts/land.sh: each merge form in the Bash command text
# blocks, and the block message names that script. The reads and the land command pass.
expect block 'gh pr merge --auto --rebase 3'
expect block 'cd x && gh pr merge 3'
expect block 'gh pr merge'
expect block 'gh api -X PUT repos/o/r/pulls/3/merge'
expect block 'gh api repos/o/r/pulls/3/merge --method PUT'
expect block 'gh api repos/o/r/pulls/3/merge --method=PUT'
expect block 'gh api repos/o/r/pulls/3/merge -XPUT -f merge_method=squash'
expect block 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }" | cat; echo done'
expect block $'gh api graphql -f query=\'mutation {\n  mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId }\n}\''
expect block "gh alias set m 'pr merge'"
expect allow 'gh pr view 3 --json state'
expect allow 'gh api repos/o/r/pulls/3'
expect allow 'gh api repos/o/r/pulls/3/merge'
expect allow 'gh api repos/o/r/pulls/3/merge --jq .merged'
expect allow 'gh pr list --state merged'
expect allow 'gh alias set v "pr view"'
expect allow 'scripts/land.sh "t" pr.md'
# The route itself never blocks: a land title or a commit message may hold merge words. A command
# after the route in the chain, and a substitution in the text, still block.
expect allow 'scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow './scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow 'cd x && scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow 'scripts/land.sh "docs: gh api mergePullRequest" pr.md'
# A repo flag of gh (-R, --repo) before or after the command word still runs the same merge.
expect block 'gh pr -R o/r merge 3'
expect block 'gh pr -Ro/r merge 3'
expect block 'gh -R o/r pr merge 3'
expect block 'gh --repo=o/r pr merge 3'
expect block 'gh --repo o/r pr merge --auto --rebase 3'
expect block 'gh pr --repo o/r merge'
expect block 'gh -R o/r pr --repo=o/r merge 3'
expect block 'cd x && gh -R o/r pr merge 3'
expect block 'gh -R o/r api repos/o/r/pulls/3/merge -X PUT'
expect block 'gh --repo o/r api repos/o/r/pulls/3/merge --method PUT'
expect block 'gh -R o/r api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block 'gh --repo=o/r api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block "gh -R o/r alias set m 'pr merge'"
expect allow 'gh pr list --search merge'
expect allow 'gh -R o/r pr list --search merge'
expect allow 'gh pr -R o/r view 3'
expect allow 'gh --repo o/r api repos/o/r/pulls/3/merge'
expect allow 'git commit -m "fix(land): retry gh pr merge after a 502"'
expect allow 'git -C ../wt commit -m "docs: gh alias set m pr merge"'
expect block 'scripts/land.sh "t" pr.md && gh pr merge 3'
expect block 'git commit -m x; gh pr merge 3'
expect block 'gh pr merge 3 && scripts/land.sh "t" pr.md'
expect block 'scripts/land.sh "$(gh pr merge 3)" pr.md'
expect block 'git commit -m "`gh pr merge 3`"'
expect allow 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh "t" .scratchpads/runs/r/pr.md'
got="$(printf '{"tool_input":{"command":"gh pr merge 3 --rebase"}}' | "$hook" 2>&1)"
[[ "$got" == *scripts/land.sh* ]] ||
  { echo "FAIL: the merge block message does not name scripts/land.sh: $got"; failures=$((failures + 1)); }
[[ "$got" != *'Write tool'* ]] ||
  { echo "FAIL: the merge block message talks about the Write tool: $got"; failures=$((failures + 1)); }
got="$(printf '{"tool_input":{"command":"git reset --hard"}}' | "$hook" 2>&1)"
[[ "$got" == *'Write tool'* ]] ||
  { echo "FAIL: another block message lost its Write tool line: $got"; failures=$((failures + 1)); }
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
expect allow 'scripts/with-lock.sh scripts/check-stamp.test.sh'
# Only a passing make test-slow or test-slow-push writes the slow-run date. A direct write skips the daily slow run.
expect block 'date +%F > .git/dirigible-slow-date'
expect block 'echo 2026-01-01 > "$(git rev-parse --git-common-dir)/dirigible-slow-date"'
expect allow 'make test-slow'
expect allow 'make test-slow-push'
# expect_each_write <path>: each form of one shared list of writes blocks on <path>. A rule that
# guards a file allows a list of read forms and blocks all other forms (a list of write forms
# missed sed -i, dd of=, and a variable), so a new write form goes in this list once and runs for
# each guarded file. @P@ is the path.
write_forms=(
  'rm @P@' 'rm -r @P@' 'mv @P@ /tmp/x' 'cp x @P@' 'truncate -s 0 @P@' 'touch @P@' 'ln -sf x @P@'
  ': > @P@' 'echo x > @P@' 'echo x >> @P@' 'echo x>>@P@' 'echo x 2>> @P@' 'echo x >| @P@'
  'echo x | tee @P@' 'echo x | tee -a @P@' 'printf x >"@P@"' "printf x > '@P@'" 'cat x > @P@'
  "sed -i '' 1d @P@" 'sed 1d @P@' "sed -n -i '' 1d @P@" "perl -i -pe 's/1/2/' @P@"
  'dd if=/dev/null of=@P@' 'sort -o @P@ x' "awk '{ print > \"@P@\" }' x" 'f=@P@; : > "$f"'
  "python3 -c 'open(\"@P@\", \"w\")'"
)
# A command that names a guarded path must hold only reads: a variable or a pipe must not carry
# the path to a segment that writes or runs a program.
write_forms+=(
  'f=@P@; rmdir "$f"' 'f=@P@; mkdir "$f"' 'f=@P@; rm -rf "$f"' 'f=@P@; mv "$f" /tmp/x'
  'f=@P@; g=$f; rm "$g"' 'f=@P@; for x in "$f"/*; do rm "$x"; done'
  'f=@P@; for x in "$f"/*; do echo y > "$x"; done' "f=@P@ bash -c 'rmdir \"\$f\"'"
  'f=$(rm -rf @P@); echo "$f"' "f=@P@; printf '%s\n' \"\$f\" | xargs rmdir"
  'ls -d @P@ | xargs rmdir' 'cat @P@/pid | xargs kill' 'ls @P@ & rmdir @P@'
  'cat $(rmdir @P@)/x' 'cat `rmdir @P@`/x'
  'f=@P@; for x in "$f"/*; do echo "$x"; done; rmdir "$x"' 'f=@P@; X=f; rmdir "${!X}"'
  "f=@P@; export f; python3 -c 'import os; os.rmdir(os.environ[\"f\"])'"
  "f=@P@; declare -x f; python3 -c 'import os; os.rmdir(os.environ[\"f\"])'"
  'ls @P@ && make test'
  'cd /x && rmdir @P@' 'cd /x > f && ls @P@' 'cd /x /y && ls @P@' 'cd /x && N=$(rmdir @P@) && ls @P@'
  'PATH=/tmp/x && ls @P@' 'N=1 rmdir @P@'
  'path=/tmp/x && ls @P@' 'cdpath=/x && ls @P@' 'ld_library_path=/x && ls @P@'
)
read_forms=(
  'ls @P@ | wc -l' 'cat @P@/* | grep pid' 'ls @P@ 2>/dev/null | head -3' 'ls @P@ 2>&1 | tail -2'
  'cat @P@ && echo ok' 'f=@P@; [ -d "$f" ] && echo present || echo absent'
  'f=@P@; test -d "$f" && cat "$f"/pid' 'for x in @P@/*; do cat "$x"; done'
  'f=@P@; for x in "$f"/*; do echo "$x: $(cat $x)"; done'
  'cd /x && ls @P@' 'cd /x && cat @P@/tree' 'N=1 && ls @P@' 'cd /x && N=a/b.c:1 && ls @P@ | wc -l'
)
expect_each_write() {
  local form
  for form in "${write_forms[@]}"; do expect block "${form//@P@/$1}"; done
}
expect_each_read() {
  local form
  for form in "${read_forms[@]}"; do expect allow "${form//@P@/$1}"; done
}

# Only run-checks.sh appends to the flakes file and only land.sh removes its lines, so a flake row
# cannot be erased between the push check and the land.
expect block 'rm "$(git rev-parse --git-common-dir)/dirigible-flakes"'
expect allow 'scripts/with-lock.sh scripts/run-checks.test.sh'
expect allow 'scripts/run-checks.sh --flakes'
# Each simple command that names the flakes file must be a read: a read tool first, no -i, and no
# redirect into the name (quotes and a $(...) path too). A grep whose quoted pattern holds a > is
# a read (the path of a redirect stops at * and [). All else blocks.
expect_each_write .git/dirigible-flakes
# More read tools: git grep, rg, sort (no -o), grep -i, sed -n (no -i), awk (no redirect). A \|
# in a quoted grep pattern does not split the command.
expect allow 'git grep -n dirigible-flakes'
expect allow 'rg dirigible-flakes scripts'
expect allow 'sort .git/dirigible-flakes'
expect allow 'grep -i x .git/dirigible-flakes'
expect allow 'sed -n 1p .git/dirigible-flakes'
expect allow "awk '{ print \$1 }' .git/dirigible-flakes"
expect allow "grep -n 'land\\|dirigible-flakes' scripts/run-checks.sh"
# A folder path with no .git in it (a worktree named dirigible-flakes) is not the file: the past
# commands of probe-u1/commands.txt stay allowed.
expect allow 'git worktree add -b fix/flakes-and-upkeep ../dirigible-flakes main 2>&1 | tail -1'
expect allow 'cd /Users/x/projects/dirigible-flakes && git status --porcelain'
expect allow 'git -C ../dirigible-flakes status --porcelain && git worktree remove ../dirigible-flakes'
expect allow "R=.scratchpads/runs/2026-10-05-flakes-2/run.md && sed -n 1p \$R"
expect allow 'cd /Users/x/projects/dirigible-flakes2 && git status --porcelain'
expect allow 'git -C ../dirigible-flakes2 status --porcelain && git worktree remove ../dirigible-flakes2'
expect block ': > "$(git rev-parse --git-common-dir)/dirigible-flakes"'
expect block 'echo x >> "$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes"'
expect block 'echo x >> "$d"/dirigible-flakes'
expect block 'printf x "$a">"$d/dirigible-flakes"'
expect allow 'grep -n dirigible-flakes .claude/hooks/git-guardrails.sh'
# Only run-checks.sh appends to the partial stamp file, so a hand-written line cannot narrow a
# push check to a rerun of chosen tests. A read is allowed.
expect_each_write .git/dirigible-check-partial
expect block 'echo abc base failed fast:a slow: >> "$(git rev-parse --git-common-dir)/dirigible-check-partial"'
expect allow 'cat .git/dirigible-check-partial'
expect allow 'grep -c failed .git/dirigible-check-partial'
expect allow 'cat .git/dirigible-flakes'
expect allow 'grep -c x .git/dirigible-flakes > /tmp/count.txt'
expect allow "grep -n '>.*dirigible-flakes' .claude/hooks/git-guardrails.sh"
expect allow 'grep -n ">.*dirigible-flakes" .claude/hooks/git-guardrails.sh'
expect allow "grep -n ' >.*dirigible-flakes' .claude/hooks/git-guardrails.sh"
# A quoted ; or & splits the command, so that grep blocks. The body of a cat sink is data.
expect block "grep -nE 'x >[[:space:]]*[^;&|]*dirigible-flakes' .claude/hooks/git-guardrails.sh"
expect allow $'cat >> scripts/run-checks.test.sh <<\'EOF\'\nflakes="$tmp/dirigible-flakes"\nEOF'
# Only run-checks.sh writes and removes the run marks that the pre-commit hook reads, so an agent
# cannot clear a mark to commit during a check. A read of the marks is allowed.
expect_each_write .git/dirigible-check-running/5
expect block 'rm -r .git/dirigible-check-running'
expect block 'mv .git/dirigible-check-running /tmp/x'
expect block ': > "$(git rev-parse --git-dir)/dirigible-check-running/5"'
expect block 'echo 1 >> "$(git rev-parse --path-format=absolute --git-dir)/dirigible-check-running/5"'
expect block 'echo 1 >> "$d"/dirigible-check-running/5'
expect block 'printf 1 "$a">"$d/dirigible-check-running/5"'
# A subagent never runs a lock wait with no limit: WITH_LOCK_MAX_WAIT=0, a land, a push check (a
# BASE= word, or BASE in the environment), make dmg, or a mutation pass, also inside bash -c and
# sh -c. After a second exit 75 it returns to the lead. The lead runs the wait, so the input with
# no agent_id allows each form.
unlimited_forms=(
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed'
  'WITH_LOCK_MAX_WAIT=00 scripts/with-lock.sh make check-changed'
  'export WITH_LOCK_MAX_WAIT=0; scripts/with-lock.sh make x'
  'env WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make x'
  '(WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed) &'
  'scripts/with-lock.sh scripts/land.sh "feat: x" .scratchpads/body.md'
  'scripts/with-lock.sh make check-changed BASE=origin/main'
  'scripts/with-lock.sh make check-changed FILTER=ATests BASE=origin/main'
  'scripts/with-lock.sh make BASE=origin/main check-changed'
  'BASE=origin/main scripts/with-lock.sh make check-changed'
  'export BASE=origin/main; scripts/with-lock.sh make check-changed'
  'scripts/with-lock.sh make dmg'
  'cd /x && scripts/with-lock.sh make dmg'
  '(scripts/with-lock.sh make dmg) &'
  'scripts/with-lock.sh .claude/skills/deliver/scripts/mutation-pass.sh /tmp/tree /tmp/batch'
  '.claude/skills/deliver/scripts/mutation-pass.sh /tmp/tree /tmp/batch'
  'bash .claude/skills/deliver/scripts/mutation-pass.sh /tmp/tree /tmp/batch'
  "bash -c 'scripts/with-lock.sh make dmg'"
  "bash -lc 'scripts/with-lock.sh make check-changed BASE=origin/main'"
  'sh -c "scripts/with-lock.sh scripts/land.sh t b"'
  "sh -c 'cd /x; scripts/with-lock.sh make dmg'"
  "sh -c 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make x'"
  "/bin/bash -c 'export WITH_LOCK_MAX_WAIT=0; scripts/with-lock.sh make x'"
  "env bash -c 'scripts/with-lock.sh make dmg'"
)
for form in "${unlimited_forms[@]}"; do
  expect_agent block "$form"
  grep -q 'return to the lead' "$tmp/agent.err" || { echo "FAIL: the subagent block says nothing of the lead: $form"; failures=$((failures + 1)); }
  expect allow "$form"
done
expect_agent allow 'WITH_LOCK_MAX_WAIT=120 scripts/with-lock.sh make x'
expect_agent allow 'scripts/with-lock.sh make check-changed'
expect_agent allow 'scripts/with-lock.sh make check-changed FILTER=ATests'
expect_agent allow 'scripts/with-lock.sh make test-filter FILTER=ATests'
expect_agent allow 'scripts/with-lock.sh make check-changed BASE='
expect_agent allow "bash -c 'scripts/with-lock.sh make check-changed'"
expect_agent allow "rg -n 'WITH_LOCK_MAX_WAIT=0' AGENTS.md"
expect_agent allow "rg -n 'with-lock.sh make dmg' AGENTS.md"
expect_agent allow "echo 'scripts/with-lock.sh make dmg'"
expect_agent allow 'git commit -m "docs: say scripts/with-lock.sh make dmg is for the lead"'
expect_agent allow 'scripts/land.sh --help'
# Only scripts/with-lock.sh takes and removes the build lock, after its own take: a hand-written
# mkdir and rmdir chain removed the lock of another agent three times. A read is allowed.
expect_each_write .git/dirigible-build.lock
expect block 'mkdir .git/dirigible-build.lock && make test; rmdir .git/dirigible-build.lock'
expect block 'rmdir "$(git rev-parse --git-common-dir)/dirigible-build.lock"'
expect block 'rm -rf /Users/x/repo/.git/dirigible-build.lock'
expect allow 'ls .git/dirigible-build.lock'
expect allow 'cat .git/dirigible-build.lock/pid .git/dirigible-build.lock/command'
# Only scripts/verify-copy.sh start takes the screen lock and stop removes it: a hand-written
# remove freed the screen for a second verify copy. A read is allowed.
expect_each_write .git/dirigible-screen
expect block 'rm -rf "$(git rev-parse --git-common-dir)/dirigible-screen"'
expect allow 'ls .git/dirigible-screen'
expect allow 'cat .git/dirigible-screen/root .git/dirigible-screen/pid'
# Only scripts/test-hooks.sh appends to the hooks pass stamp, after a pass of the whole list, so
# a Bash command cannot write it to skip the hook tests. A read is allowed.
expect_each_write .git/dirigible-hooks-stamp
expect block 'echo k >> "$(git rev-parse --git-common-dir)/dirigible-hooks-stamp"'
expect block 'rm .git/dirigible-hooks-stamp'
expect block "sed -i '' 1d .git/dirigible-hooks-stamp"
expect allow 'cat .git/dirigible-hooks-stamp'
expect allow 'grep -c . "$(git rev-parse --git-common-dir)/dirigible-hooks-stamp"'
# Each guarded path allows the read forms of one shared list.
for guarded in .git/dirigible-flakes .git/dirigible-check-partial .git/dirigible-check-running/5 \
  .git/dirigible-build.lock .git/dirigible-screen .git/dirigible-hooks-stamp; do
  expect_each_read "$guarded"
done
# A plain assignment must not let a read tool run another program: these names block.
for name in PATH IFS ENV BASH_ENV CDPATH SHELLOPTS LD_PRELOAD DYLD_INSERT_LIBRARIES GIT_PAGER \
  RIPGREP_CONFIG_PATH HOME PAGER; do
  expect block "$name=x && ls .git/dirigible-build.lock"
done
# A loop over the lock files, a test of the lock, and a quoted pattern with a pipe are reads.
expect allow 'L=.git/dirigible-build.lock; [ -d "$L" ]'
expect allow 'L=.git/dirigible-build.lock; test -d "$L" && cat "$L"/pid'
expect allow 'L=$(git rev-parse --git-common-dir)/dirigible-build.lock; for f in "$L"/*; do echo "$f: $(cat $f)"; done'
expect allow 'for f in .git/dirigible-build.lock/*; do cat "$f"; done'
expect allow $'wc -l .claude/hooks/git-guardrails.sh .claude/hooks/git-guardrails.test.sh; rg -n -i \'heredoc|here-doc|<<|LOCKED_SCRIPT|hooksPath|reads_only|dirigible-build.lock|tccutil|screencapture|\\-F|--file|\\.index\\(|flakes|pass-stamp|commit-after|log-decision\' .claude/hooks/git-guardrails.sh | cut -c1-220'
# A hand-set reuse value would run a build beside the holder of the lock.
expect block 'DIRIGIBLE_BUILD_LOCK=123 scripts/with-lock.sh make test'
expect block 'DIRIGIBLE_LOCKED_SCRIPT=scripts/bench.sh scripts/bench.sh X'
expect allow 'scripts/with-lock.sh make test'
expect allow "grep -n '>.*dirigible-check-running' .claude/hooks/git-guardrails.sh"
expect allow 'ls .git/dirigible-check-running'
expect allow 'cat .git/dirigible-check-running/5'
expect allow 'grep -r x .git/dirigible-check-running'
# The block message of the flakes file names its read route.
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string 'echo x >> .git/dirigible-flakes' "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == *'read it with scripts/run-checks.sh --flakes'* ]] ||
  { echo "FAIL: the flakes block message names no read route: $message"; failures=$((failures + 1)); }
expect allow 'scripts/with-lock.sh scripts/check-changed.test.sh'

# The body of a heredoc that goes to a file (cat or tee, a plain file) is data: no rule reads it. The
# marker ends the first line, or only a redirect to a plain file follows it, and an exact end line
# follows the body. All else keeps the body in the text: a pipe, bash, an inline text, a here-string.
sink_bodies=(
  'x=1 DIRIGIBLE_LOCKED_SCRIPT="$0" exec'
  $'make lint; echo\n.claude/skills/deliver/scripts/log-decision.sh r 4 a b c d'
  'git -c core.hooksPath=/dev/null commit -m x'
  'git push origin main'
  'rm .git/dirigible-flakes'
  'echo k >> .git/dirigible-check-stamp'
)
for body in "${sink_bodies[@]}"; do
  expect allow $'cat > f <<\'EOF\'\n'"$body"$'\nEOF'
  expect allow $'tee f <<\'EOF\'\n'"$body"$'\nEOF'
  expect allow $'cat <<\'EOF\' > f\n'"$body"$'\nEOF'
  expect block $'bash <<EOF\n'"$body"$'\nEOF'
done
expect allow $'cat >> f <<-EOF\n\tgit reset --hard\n\tEOF'
expect allow $'tee -a f <<\'EOF\'\ngit push origin main\nEOF'
expect allow $'cat <<\'EOF\' > f\ngit reset --hard\nEOF'
# An unquoted marker expands $(...) and backticks in the body, so the shell runs them.
expect block $'cat > f <<EOF\n$(git reset --hard)\nEOF'
expect block $'cat > f <<EOF\n`git reset --hard`\nEOF'
expect allow $'cat > f <<\'EOF\'\n$(git reset --hard)\nEOF'
# No sink: the body stays in the text.
expect block $'cat <<\'EOF\' | bash\ngit push --force origin main\nEOF'
expect block $'tee f <<EOF | sh\ngit reset --hard\nEOF'
expect block $'cat > f <<EOF; git reset --hard\nx\nEOF'
expect block $'cat > f <<EOF\nx\nEOF\ngit reset --hard'
expect block $'cat > f <<EOF\ngit reset --hard'
expect block $'cat > f <<A && bash <<B\nx\nA\ngit reset --hard\nB'
expect block $'cat > >(bash) <<EOF\ngit reset --hard\nEOF'
expect block $'tee >(sh) <<EOF\ngit reset --hard\nEOF'
expect block $'bash <<-EOF\n\tgit reset --hard\n\tEOF'
expect block $'bash <<< \'git reset --hard\''
expect block $'cat <<< \'git reset --hard\' | sh'
expect block $'cat <<EOF > f; git reset --hard\nx\nEOF'
expect block $'cat <<EOF > f | sh\ngit reset --hard\nEOF'
expect block $'cat <<EOF > >(sh)\ngit reset --hard\nEOF'
expect block $'cat > f <<EOF\ngit reset --hard\nEOF x'
# An interpreter heredoc is read as a program. The lock-value rule and the log-decision rule skip
# its body. Each other rule reads it, so python3 can not remove the lock or write a stamp.
expect allow $'python3 - <<\'EOF\'\n'"${sink_bodies[0]}"$'\nEOF'
expect allow $'python3 <<\'EOF\'\n'"${sink_bodies[1]}"$'\nEOF'
for body in "${sink_bodies[@]:2}"; do
  expect block $'python3 - <<\'EOF\'\n'"$body"$'\nEOF'
done
for name in dirigible-check-stamp dirigible-slow-date dirigible-flakes dirigible-check-partial \
  dirigible-check-running dirigible-build.lock dirigible-screen dirigible-hooks-stamp; do
  expect block $'python3 - <<\'EOF\'\nimport os\nos.remove(".git/'"$name"$'")\nEOF'
done
expect block $'python3 - <<\'EOF\'\nimport os\nos.rmdir(".git/dirigible-build.lock")\nEOF'
expect block $'python3 - <<\'EOF\'\nopen(".git/dirigible-check-stamp", "a").write("x")\nEOF'
expect block $'python3 - <<\'EOF\'\nopen(".git/dirigible-flakes", "a").write("x")\nEOF'
expect block $'node - <<\'EOF\'\nrequire("fs").rmdirSync(".git/dirigible-build.lock")\nEOF'
expect block $'perl <<\'EOF\'\nrmdir ".git/dirigible-build.lock";\nEOF'
expect block $'ruby <<\'EOF\'\nDir.rmdir(".git/dirigible-build.lock")\nEOF'
expect block $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run("make check; git commit -m x", shell=True)\nEOF'
expect block $'bash <<EOF\nmake check; git commit -m x\nEOF'
expect block "python3 -c 'import os; os.rmdir(\".git/dirigible-build.lock\")'"
expect block "node -e 'require(\"fs\").rmdirSync(\".git/dirigible-build.lock\")'"
expect block "perl -e 'rmdir \".git/dirigible-build.lock\"'"
expect block "ruby -e 'Dir.rmdir(\".git/dirigible-build.lock\")'"
# After one `cd <word> &&`, a cat, tee, or python3 - body is data as without the prefix. A ; join,
# a bash body, an unquoted marker with $( in the body, and a python3 body that pushes main block.
expect allow $'cd /x && cat > f.txt <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect allow $'cd /x && tee f.txt <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect allow $'cd /x && cat > f.txt <<\'EOF\'\ngit push origin main\nEOF'
expect allow $'cd /x && python3 - <<\'EOF\'\ns = \'DIRIGIBLE_LOCKED_SCRIPT="$0" exec\'\nEOF'
expect block $'cd /x && bash <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect block $'cd /x; cat > f.txt <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect block $'cd /x && cat > f.txt <<EOF\nDIRIGIBLE_LOCKED_SCRIPT=$(date) exec\nEOF'
expect block $'cd /x && python3 - <<\'EOF\'\nimport os; os.system(\'git push origin main\')\nEOF'

# A text rule of osascript must hold for each shell form, not only for the forms that a gate found
# one at a time (run 2026-10-08-upkeep-batch-6). expect_each_form <want> <line>... runs one
# AppleScript body (one argument for each line) as: one -e for each line, all lines in one -e, a
# heredoc, one -e with escaped double quotes, the first form in upper case, and the first form
# with a tab and doubled spaces. A line must not hold a single quote.
expect_each_form() {
  local want="$1" line parts="" body=""
  shift
  for line in "$@"; do parts+=" -e '$line'"; body+="$line"$'\n'; done
  body="${body%$'\n'}"
  expect "$want" "osascript$parts"
  expect "$want" "osascript -e '$body'"
  expect "$want" "osascript <<EOF"$'\n'"$body"$'\n'"EOF"
  expect "$want" "osascript -e \"${body//\"/\\\"}\""
  expect "$want" "$(tr '[:lower:]' '[:upper:]' <<<"osascript$parts")"
  expect "$want" "osascript"$'\t'"$(sed 's/ /  /g' <<<"${parts# }")"
}

# A new Finder window opens as a tab of the window group of the user, so a bounds or position
# change of a Finder window moves the windows of the user. A read, and a move of another app, pass.
expect_each_form block 'tell application "Finder" to set bounds of window 1 to {0, 0, 800, 600}'
expect_each_form block 'tell application "System Events" to set position of window 1 of process "Finder" to {0, 0}'
expect_each_form block 'tell application "Finder"' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
expect_each_form block 'tell application id "com.apple.finder" to set position of window 1 to {0, 0}'
expect_each_form block 'tell app "Finder" to set bounds of window 1 to {0, 0, 9, 9}'
expect_each_form block 'tell application "System Events" to tell process "Finder" to set position of window 1 to {0, 0}'
# The System Events form of a process tell: through the Finder rule (a).
expect_each_form block 'tell application "System Events"' 'tell application process "Finder"' 'set position of window 1 to {0, 0}' 'end tell' 'end tell'
# A set after a nested end tell is still in the Finder clause; a size change moves the group too.
expect_each_form block 'tell application "Finder"' 'tell front window' 'get name' 'end tell' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
expect_each_form block 'tell application "System Events" to set size of window 1 of process "Finder" to {9, 9}'
expect_each_form block 'tell application "Finder" to set size of window 1 to {9, 9}'
# A read of the Finder window through System Events, then a move of the verify copy, passes.
expect allow "osascript -e 'tell application \"System Events\" to get name of window 1 of process \"Finder\"'; osascript -e 'tell application \"System Events\" to set position of window 1 of application process \"Dirigible\" to {0, 0}'"
expect_each_form allow 'tell application "System Events" to get position of window 1 of process "Finder"'
expect_each_form allow 'tell application "System Events" to set position of window 1 of process "Dirigible" to {900, 100}'
expect_each_form allow 'tell application "System Events"' 'set position of window 1 of process "Dirigible" to {900, 100}' 'get position of window 1 of process "Finder"' 'end tell'
expect_each_form allow 'tell application id "com.apple.systemevents" to get name of every process'
expect_each_form allow 'tell app "System Events"' 'tell application process "Dirigible"' 'get position of window 1' 'end tell' 'end tell'
expect_each_form allow 'display notification "done"'
expect allow "grep -n 'quit app \"QuickTime Player\"' notes.txt"

# An Apple Event to an app other than System Events (a tell, quit, activate, or launch) makes
# macOS show an Automation prompt for the terminal app, and the call waits until it times out.
expect_each_form block 'tell application "QuickTime Player" to get name of document 1'
expect_each_form block 'tell app "Google Chrome" to get URL of active tab of window 1'
expect_each_form block 'tell application id "com.google.Chrome" to get name of window 1'
expect_each_form block 'tell application "Finder" to get bounds of window 1'
expect_each_form block 'tell application "Finder" to set sizeKB to size of (POSIX file "/tmp/x" as alias)'
expect_each_form block 'quit app "QuickTime Player"'
expect_each_form block 'activate application "Google Chrome"'
expect_each_form block 'launch application id "com.google.Chrome"'
expect_each_form block 'tell application "System Events" to quit application "QuickTime Player"'
# A reference to another app with no tell verb sends the same Apple Event.
expect_each_form block 'set bounds of window 1 of application "Finder" to {0, 0, 9, 9}'
expect_each_form block 'run application "QuickTime Player"'
expect_each_form block 'get name of application id "com.google.Chrome"'
expect_each_form allow 'tell application "System Events" to get name of window 1 of application process "Finder"'
# The two Finder gaps that end a Finder clause early: a System Events line, and an osascript word.
expect_each_form block 'tell application "Finder"' 'tell application "System Events" to get name of every process' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
expect_each_form block 'tell application "Finder"' 'get name of file "osascript.txt" of desktop' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
# The block message names System Events and leaves the prompt to the user.
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string "osascript -e 'tell application \"QuickTime Player\" to get name of document 1'" "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == *'Automation prompt'* && "$message" == *'through System Events'* && "$message" == *'leave it'* ]] ||
  { echo "FAIL: the Apple Event block message: $message"; failures=$((failures + 1)); }
# The Finder block message gives the reason and the way, keeps the data hint, and has no git sentence.
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string "osascript -e 'tell app \"Finder\" to set bounds of window 1 to {0, 0, 9, 9}'" "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == 'BLOCKED by .claude/hooks/git-guardrails.sh: '* && "$message" == *'opens as a tab'* &&
  "$message" == *'move only the window of the verify copy'* && "$message" == *'through System Events'* &&
  "$message" == *'If the matched text is only data'* &&
  "$message" != *'deliver flow'* ]] ||
  { echo "FAIL: the Finder block message: $message"; failures=$((failures + 1)); }

# A quit by name also quits the copy of the user, with its unsaved work (AGT-120).
expect block 'killall Dirigible'
expect block 'killall -9 Dirigible'
expect block '/usr/bin/killall Dirigible'
expect block 'sudo killall Dirigible'
expect block 'make app && killall Dirigible'
expect block 'pgrep Dirigible | xargs killall'
expect block 'pkill -x Dirigible'
expect block 'pkill -9 -x Dirigible'
expect block 'pkill -ix dirigible'
expect block 'pkill -xf Dirigible'
expect block '/usr/bin/pkill -x Dirigible'
expect allow 'pkill -INT -f mutate.py'
expect allow 'pkill -TERM -f "mutation-pass.sh --run x"'
expect allow 'pkill -f "scripts/probe.sh .scratchpads/p -x"'
expect allow 'pgrep -x Dirigible'
expect allow 'kill 4242'
expect allow 'grep -n skillall notes.md'
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string 'killall Dirigible' "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == *'pgrep'* && "$message" == *'only that PID'* && "$message" != *'deliver flow'* ]] ||
  { echo "FAIL: the quit-by-name block message: $message"; failures=$((failures + 1)); }

# A privacy reset of the bundle ID of the user removes the grants of each build of the user. Only the
# ID of the verify copy (.verify-<hash>) may be reset.
expect block 'tccutil reset AudioCapture com.delineas.dirigible'
expect block 'tccutil reset All com.delineas.dirigible'
expect block 'make app && tccutil reset Microphone com.delineas.dirigible'
expect allow 'tccutil reset All com.delineas.dirigible.verify-1a2b3c4d'
expect allow 'tccutil reset Microphone com.example.other'
expect allow 'rg -n com.delineas.dirigible Package.swift'
expect allow $'cat > notes.md <<\'EOF\'\ntccutil reset All com.delineas.dirigible\nEOF'
# A reset with no bundle ID removes the grants of every app, and a bundle ID from a variable can
# name the ID of the user: both block.
expect block 'tccutil reset Microphone'
expect block 'tccutil reset All'
expect block 'tccutil reset All 2>&1'
expect block 'make app && tccutil reset Microphone && echo done'
expect block $'tccutil reset All\nls'
expect block $'id=com.delineas.dirigible; tccutil reset Microphone "$id"'
expect block 'tccutil reset Microphone "$(printf com.delineas.dirigible)"'
expect block 'tccutil reset Microphone `printf com.delineas.dirigible`'
expect allow 'tccutil reset All com.delineas.dirigible.verify-1a2b3c4d 2>&1'
expect allow $'cat > notes.md <<\'EOF\'\ntccutil reset All\nEOF'
message="$(printf '{"tool_input":{"command":"tccutil reset All"}}' | "$hook" 2>&1)"
[[ "$message" == *'scripts/verify-copy.sh'* && "$message" == *'no bundle ID'* ]] ||
  { echo "FAIL: the no-ID tccutil block message: $message"; failures=$((failures + 1)); }
message="$(printf '{"tool_input":{"command":"tccutil reset All com.delineas.dirigible"}}' | "$hook" 2>&1)"
[[ "$message" == *'scripts/verify-copy.sh'* && "$message" != *'deliver flow'* ]] ||
  { echo "FAIL: the tccutil block message names no verify copy route: $message"; failures=$((failures + 1)); }

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
expect_message 'without &&' 'make check; git commit -m x'
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
# A quoted path with a space after git -C.
expect block "git -C '/x y/wt' commit -F .scratchpads/commit-msg.txt; $ld"
expect block "git -C \"/x y/wt\" commit -F .scratchpads/commit-msg.txt; $ld"
expect_message 'in its own command' "swift build; $ld"
# The rule matches git commit, make, or swift only at a command start, after the prefix words
# NAME=value, time, with-lock.sh, and probe.sh <folder>. The word make in row text is data.
expect allow $'printf \'4\\twe make the row\\n\' > row.txt; .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect allow $'cat > row.txt <<\'EOF\'\n4\nwe make the row\nEOF\n.claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
# The rule fires only when log-decision.sh starts a command, so a read of the script passes.
expect allow 'git commit --amend --no-edit -q; cat .claude/skills/deliver/scripts/log-decision.sh | head -5'
expect allow 'git commit -q -m x; sed -n 1,5p .claude/skills/deliver/scripts/log-decision.sh'
expect allow 'make lint; head -3 .claude/skills/deliver/scripts/log-decision.sh'
expect block $'make check-docs\n.claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect block 'make check-docs | tee x.log; bash .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect block 'swift build & .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect allow 'git commit -q -m x && .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
# run.md, plan.md, and analysis.md change only with the Edit tool (AGENTS.md, Run ledger). A
# segment that names one of them and holds a write form blocks, with and without a runs path.
# A read, a -n copy or move, and the names in quoted data, a row file body, or another segment pass.
expect block $'cd .scratchpads/runs/r && sed -i \'\' \'s/a/b/\' run.md'
expect block $'python3 - <<\'EOF\'\nopen("run.md", "a").write("x")\nEOF'
expect block $'python3 - <<\'EOF\'\nopen(".scratchpads/runs/r/run.md", "a").write("x")\nEOF'
expect block $'python3 -c \'open("plan.md", "w")\''
expect block $'python3 -c \'open(".scratchpads/runs/r/plan.md", "w")\''
expect block $'node -e \'require("fs").writeFileSync("analysis.md", "x")\''
expect block $'perl -e \'open(F, ">", "analysis.md")\''
expect block $'ruby -e \'File.write("analysis.md", "x")\''
expect block $'ruby -e \'File.write(".scratchpads/runs/r/analysis.md", "x")\''
expect block $'cat >> $R/run.md <<\'EOF\'\nx\nEOF'
expect block $'cat >> run.md <<\'EOF\'\nx\nEOF'
expect block $'R=.scratchpads/runs/r/run.md; echo x >> $R'
expect block $'R=run.md; echo x >> $R'
expect block $'tee -a analysis.md < x'
expect block $'echo x | tee -a .scratchpads/runs/r/analysis.md'
expect block $'rm plan.md'
expect block $'rm -f .scratchpads/runs/r/plan.md'
expect block $'truncate -s 0 plan.md'
expect block $'dd if=x of=run.md'
expect block $'dd if=x of=.scratchpads/runs/r/run.md'
expect block $'mv x plan.md'
expect block $'mv x .scratchpads/runs/r/plan.md'
expect block $'cp x run.md'
expect block $'sed -i.bak \'s/a/b/\' run.md'
expect block $'sed --in-place \'s/a/b/\' run.md'
expect block $'sed -i \'\' \'s/a/b/\' .scratchpads/runs/r/run.md'
expect block $'echo x > analysis.md'
expect block $'perl -i -pe \'s/a/b/\' plan.md'
expect allow $'rg x run.md'
expect allow $'cat run.md'
expect allow $'head -5 plan.md'
expect allow $'tail analysis.md'
expect allow $'wc -l run.md'
expect allow $'sed -n 1,5p run.md'
expect allow $'awk \'{print}\' plan.md'
expect allow $'cp plan.md plan-0.md'
expect allow $'cp -n plan.md plan-0.md'
expect allow $'cp -n analysis.md analysis-l2-0.md'
expect allow $'mv -n analysis.txt analysis.md && test ! -e analysis.txt'
expect allow $'.claude/skills/deliver/scripts/log-decision.sh .scratchpads/runs/r 3 "plan.md changed; mv x plan.md" w e r'
expect allow $'printf \'%s\\n\' 4 "edit run.md > done" > row.txt'
expect allow $'echo "S5 changed run.md and plan.md" >> notes.txt'
expect allow $'cat > row.txt <<\'EOF\'\nanalysis.md > x; rm plan.md\nEOF'
expect allow $'python3 -I -c \'import json,sys; print(json.load(sys.stdin))\' < x.json; rg y .scratchpads/runs/r/run.md'
expect allow $'sed -i \'\' s/a/b/ notes.txt && rg x run.md'
expect allow $'rg x review-plan-1.md > out.txt'
expect allow $'echo x > plan-0.md'
expect allow $'rm run.md.bak'
expect allow $'sed -i \'\' s/a/b/ review-plan-1.md'
expect allow $'git diff --stat; rg -c x .scratchpads/runs/r/run.md'
# The first command of each section of the replay of past commands (run 2026-10-27-upkeep-fifth,
# plan gate 1): 9 block forms and 5 pass forms.
expect block $'cd /repo/.scratchpads/runs/2026-10-26-agent-transport && python3 - <<\'EOF\'\nimport pathlib\np=pathlib.Path("run.md"); t=p.read_text()\nfor a,b in [("- Requirements:\\n","- Requirements: R16 (an agent can play, stop, and locate in the running app); tester proposal wiki 0029 item 4 (user order 2026-10-18). Branch made at Phase 4 from origin/main.\\n"),\n            ("- [ ] 0 Open the run","- [x] 0 Open the run (2026-10-26 08:15; decisions.tsv phase 0 rows)")]:\n    assert t.count(a)==1; t=t.replace(a,b)\np.write_text(t)\nEOF\nls ../../tester-feedback-2026-10-16/ 2>/dev/null'
expect block $'cd /repo/.scratchpads && python3 -I - <<\'EOF\'\np="runs/2026-10-18-envelope-ducking/run.md"; s=open(p).read()\ns=s.replace("L2 and L3 wait for a lead decision with the limits read again)","L2 and L3 paused until the 7-day reset on 2026-10-21 16:00 CEST, row 16:00)",1)\ns=s.replace("## Handoff\\n\\n","## Handoff\\n\\n- Pause (2026-10-19 16:00): the 7-day use is 83 %, and L2 needs a UI panel and Opus slices, so it waits for the reset on 2026-10-21 16:00 CEST (row 16:00). Main is 81629836 with no run worktree open for this run. Next step: read `~/.claude/usage/limits.json`, then start L2 on `feat/envelope-ui` in a new worktree from main, with the plan gate rule of upkeep-3 (a review-plan file and a phase 3 row before the first phase 4 row).\\n\\n",1)\nopen(p,"w").write(s)\nEOF\nrg -n \'Pause \\(|paused until\' runs/2026-10-18-envelope-ducking/run.md | cut -c1-90\necho "2026-10-19 loop paused at 16:00: 7-day use 83 % (stop at 85 %); envelope L2 (UI panel, Opus) waits for the reset 2026-10-21 16:00 CEST. Beam-free bench done (runs/2026-10-16-agent-setup/bench/grades.md section 9); routing change is in backlog FREE LENS ROUTING." >> ledger.md'
expect block $'cd /repo/.scratchpads && python3 -I - <<\'EOF\'\np="backlog.md"; s=open(p).read().split("\\n"); k=s.index("## Later")\ns.insert(k+1,"- UPKEEP-3 GATE FOLLOW-UPS (code gate 2026-10-19, runs/2026-10-15-workflow-upkeep-3/review-diff-1.md): (a) an empty `review-plan-1.md` passes the phase 4 gate of check-x.sh; require content or an `## Act on` heading; (b) check-y.sh reads `- Branch:` from run.md (lines 170 and 182), so a missing or wrong line escapes the Lands rules; fail on a missing line or read the branch of HEAD; (c) two committers in one checkout share `.scratchpads/commit-msg.txt`; one committer at a time per checkout; (d) `git diff --name-only | grep -q` under pipefail can fail on a file list over the pipe buffer (check-y.sh lines 170 and 182).")\nopen(p,"w").write("\\n".join(s))\nEOF\nsed -n \'/^## Later/,+1p\' backlog.md | cut -c1-90'
expect block $'cd /repo; f=.scratchpads/runs/2026-10-27-armed-app-track/analysis.md; python3 -I - "$f" <<\'EOF\'\nimport sys\np=sys.argv[1]; t=open(p).read()\nold="`git diff --stat origin/main -- Sources/DirigibleAudio/Capture/CaptureRing.swift Sources/DirigibleAudio/Capture/HAL.swift` prints nothing (the IOProc, the ring, and the listeners; 0013 Callbacks)"\nnew="`git diff --stat origin/main -- Sources/DirigibleAudio/Capture/CaptureRing.swift Sources/DirigibleAudio/Capture/HAL.swift Sources/DirigibleAudio/Capture/LiveAttach.swift Sources/DirigibleAudio/Capture/DeviceList.swift Sources/DirigibleAudio/Listen` prints nothing (each file with an IOProc or a property listener; 0013 Callbacks)"\nassert t.count(old)==1; open(p,"w").write(t.replace(old,new))\nEOF\ngit diff --stat origin/main -- Sources/DirigibleAudio/Capture/CaptureRing.swift Sources/DirigibleAudio/Capture/HAL.swift Sources/DirigibleAudio/Capture/LiveAttach.swift Sources/DirigibleAudio/Capture/DeviceList.swift Sources/DirigibleAudio/Listen; echo "exit $?"'
expect block $'R=.scratchpads/runs/2026-10-20-yesyak-ideas && printf \'%s\\n\' 6 "code gate closed after round 2 fixes: Act on 1 to 3 and the 3 folded nits fixed in ce9ef97c..189bcb6d; the lead fix check found one meaning change from a word cut (deliver SKILL.md \'the run ledger\' became \'the ledger\', which names .scratchpads/ledger.md); the closing agent restores \'run\' first" "one open round (small run, no critical item); lead fix check per lead-judgment" "bash scripts/check-x.test.sh all passed (lead run); git diff b12504d2..HEAD of deliver SKILL.md and AGENTS.md read by the lead" "done" > $R/rows/g.txt && .claude/skills/deliver/scripts/log-decision.sh $R --from $R/rows/g.txt && rm $R/rows/g.txt && sed -i \'\' \'s/^- \\[ \\] 6 Code gate/- [x] 6 Code gate/\' $R/run.md && ../dirigible-yesyak/scripts/evals-for.sh --quoted origin/main 2>&1 | tail -5'
expect block $'cd /repo/.scratchpads/runs/2026-10-19-trim-past-neighbor && sed -i \'\' \'s#^- Branch: fix/trim-past-neighbor$#- Branch: fix/trim-past-neighbor\\n- Worktree: /wt (from main 7792a54d); small run, risk no, one Sonnet agent for Phases 1, 2, 4, 5#\' run.md && sed -n 1,12p run.md'
expect block $'cd /repo/.scratchpads && R=runs/2026-10-19-trim-past-neighbor/run.md && sed -i \'\' -e \'s/^- Status: open (Phases 1 to 8 done; the lead runs the push check and the cold reader, then lands)$/- Status: done (PR 164, 7792a54d..18967aea, tag v0.4.6.1)/\' -e \'s/^- \\[ \\] 9 Land and close$/- [x] 9 Land and close (2026-10-19 09:30, push check 2 exit 0 after push check 1 was killed by a T3 auto-settle; worktree removed)/\' $R && sed -i \'\' \'s/^| 2026-10-19-trim-past-neighbor | trim-past-neighbor | open | |$/| 2026-10-19-trim-past-neighbor | trim-past-neighbor | done | PR 164, v0.4.6.1 |/\' ledger.md && rg -n \'^- Status|^- \\[x\\] 9\' $R && rg -n \'trim-past-neighbor\' ledger.md | cut -c1-120'
expect block $'R=.scratchpads/runs/2026-10-16-timeline-clarity; cat >> $R/run.md <<\'EOF\'\n\n## L3 plan gate closed (2026-10-25)\n\n- review-plan-4.md (round 1: architecture and devils-advocate, 3 Act on, no critical, so no round 2). Fixes by a plan-fix agent (C24, C19 to C21, C23) and by the lead after the UI panel (C25: variant C plus a 1 pt edge, proto/l3/variants/). check-x exit 0.\n- Open risks: the dark edge 0xA8C4EA is a bright line on every clip (HIG lens noise concern), judged on screen in L3-S1; the bench budget effect of the bar and the edge runs at L3-S1 (C22).\n- Order: L3 codes before the workflow upkeep run that the last handoff put first; the upkeep run plans beside it (decisions.tsv, phase 3).\nEOF\n.claude/skills/deliver/scripts/log-decision.sh $R 3 "default: L3 Phase 4 starts before the workflow upkeep run that reflect rule 6 asks for; the upkeep run plans in the free planning slot" "the tester request goes first and its plan is refreshed and gated; the upkeep run is docs and tooling, so it plans with no build beside L3. Reverse: pause the L3 implementer at a slice commit and land the upkeep run first" "new-x.sh rule 6 count 48 upkeep items; run.md handoff of 2026-10-25" "default: L3 first"'
expect block $'cat >> plan.md <<\'EOF\'\n\n## Plan gate changes\n\nThese items override the slice text and the criteria of analysis.md where they differ (review-plan-1.md).\n\n1. S1 scope: count criterion IDs and ranges only inside `## Slices` and `## Criteria map` of plan.md. New C12 case: an Inputs line with `C1 to C3` above `## Slices`, and slices that name only C1: exit 1 with `criterion C2`. Run `probe-c8/replay2.sh` again with that scope and log the result. Criteria: C12\n2. S1 cutoff: the rule checks a run whose first decisions.tsv row (the run start) is at or after the S1 commit time, and a run with no row. The record-number cutoff keeps `first3`. New C12 case: a run with an old first row, no phase 3 row, and a missing criterion passes. C13 then holds for all 10 replay runs. Criteria: C12, C13\n3. S8: deliver Phase 0 step 2 keeps `git status --porcelain` and `git branch` in its first sentence; the resume compares the handoff "with them, the last commit, and the PR state". The C6 check becomes: step 2 has `git status --porcelain` before the resume sentence, and the resume line has `the last commit` and `the PR state`. Criteria: C6\n4. S6: the AGENTS.md words are "and a Monitor that waits until the call ends, re-armed at each expiry"; E37 (b) gets the same words. The C11 check greps `a Monitor that waits until the call ends, re-armed at each expiry`. Criteria: C11\n5. S10: after the C4 checks, commit the edit in `~/projects/agentic_stuff` on its `main` branch, one commit, a plain imperative English subject with no type prefix (that repo\'s style), no push (user, row 11:20). C4 adds: `git -C ~/projects/agentic_stuff log -1 --format=%s` prints the new subject, and its status is clean. Criteria: C4\n6. Phase 4 brief: the agent writes run files and ledger lines in the main checkout by absolute path (the run folder, `.scratchpads/backlog.md`, `.scratchpads/learnings.md`); committed text keeps no local path. Criteria: none\nEOF\ncd /repo && R=.scratchpads/runs/2026-10-20-yesyak-ideas\nw(){ printf \'%s\\n\' "$@" > $R/rows/g.txt; .claude/skills/deliver/scripts/log-decision.sh $R --from $R/rows/g.txt >/dev/null || echo "row failed: $2"; }\nw 3 "criterion change C12: S1 counts IDs and ranges only in ## Slices and ## Criteria map, with a case for an Inputs range; and the cutoff keys on the first decisions.tsv row, with a case for an old run with no phase 3 row" "plan gate 1 Act on 1 and 2: a range in the Inputs line passed every ID, and the phase 3 cutoff checked past runs with no phase 3 row" "review-plan-1.md Act on 1 and 2; 2026-10-16-diagnostics/plan.md:3; replay-2.log" "resolved: plan.md Plan gate changes items 1 and 2"\nw 3 "criterion change C13: the replay holds because the cutoff keys on the first decisions.tsv row, so no past run is checked" "plan gate 1 Act on 2: governance-later-landing and shard1-crash have no phase 3 row and miss IDs" "review-plan-1.md Act on 2" "resolved: plan.md Plan gate changes item 2"\nw 3 "criterion change C6: deliver Phase 0 step 2 keeps git status --porcelain and git branch at every session start; the resume compares the handoff with them, the last commit, and the PR state" "plan gate 1 Act on 3: the draft moved the git check into the resume branch, so a session with no open run skipped it" "review-plan-1.md Act on 3; deliver SKILL.md:23" "resolved: plan.md Plan gate changes item 3"\nw 3 "criterion change C11: the Monitor words are \'a Monitor that waits until the call ends, re-armed at each expiry\', in AGENTS.md and E37 (b)" "plan gate 1 Act on 4: no script prints an exit line; the lead arms the Monitor with its own command" "review-plan-1.md Act on 4" "resolved: plan.md Plan gate changes item 4"\nw 3 "criterion change C4: S10 ends with one commit in ~/projects/agentic_stuff, plain imperative subject, no push; C4 checks the subject and a clean status" "user at 11:20 allowed the commit there (row 11:20)" "review-plan-1.md Noted; row 2026-10-20T11:20" "resolved: plan.md Plan gate changes item 5"\nw 3 "Phase 4 brief gives absolute main-checkout paths for run files and ledger lines" "plan gate 1 Act on 5: the worktree has no .scratchpads" "review-plan-1.md Act on 5" "resolved: plan.md Plan gate changes item 6"\nw 3 "plan gate 1 closed: 5 Act on items fixed in the plan, 4 refuted findings dismissed, 0 Consider; one round (small run, no critical item)" "deliver class table: risk no, one round of two class lenses" "review-plan-1.md; workflow wf_4f98857b-2af, no missing lens" "done"\nrm $R/rows/g.txt; CHECK_PLAN_AT_PHASE4=1 scripts/check-x.sh $R; echo "exit $?"'
expect allow $'R=.scratchpads/runs/2026-10-26-agent-transport && .claude/skills/deliver/scripts/log-decision.sh $R 0 "default: goal agent-transport (MCP play, stop, locate in the app); the batch tool stays out" "tester proposal 0029 item 4 is next in the user order of 2026-10-18 after read by time (done, run 13); brief R16 names play, stop, locate; no such tool exists (MCPToolTests list). batch needs a nested edit design, so it is its own run. Reverse: plan batch first" "wiki 0029; docs/requirements/brief.md:32; Tests/DirigibleCLITests/MCPToolTests.swift toolsListHasEachTool" "default planning slot to agent-transport" && .claude/skills/deliver/scripts/log-decision.sh $R 0 "default: the architecture audit run (2026-10-15-architecture-audit) gets a plan refresh after split-stereo L1 merges" "new-x.sh: 20 product runs since the last architecture run (cadence 5); its slices move Core and Audio files that split L1 changes (NewClipFiles, flush, fades), so a parallel run gives rebase conflicts. Reverse: refresh it now and hold split L1" "new-x.sh output 2026-10-26; architecture-audit plan.md S1 to S3" "default architecture run after split L1"; sed -n 1,12p $R/run.md'
expect allow $'R=.scratchpads/runs/2026-10-23-ledger-wiki && printf \'%s\\n\' "3" "plan gate fix check: 10 of 10 pass; gate closed" "Item 6 took flock in place of rename (probe P4). Item 2 raises the class to bundle, risk no: each landing runs make check and the DMG build, and the run leaves the light path. Accepted: the classifier is decision 0028 and the push check must run the new tests. Reverse: drop the HOOK_TESTS lines and run the tests by hand." "review-plan-1.md Fix check; check-x exit 0" "pass" > $R/rowfc.txt && .claude/skills/deliver/scripts/log-decision.sh $R --from $R/rowfc.txt; sed -n 1,30p $R/run.md'
expect allow $'rg -n -i -B2 -A8 \'architecture\' docs/workflow/release-cycle.md | head -50; sed -n 1,15p .scratchpads/runs/2026-10-15-architecture-audit/run.md; rg -n \'^- \\[.\\]\' .scratchpads/runs/2026-10-15-architecture-audit/run.md'
expect allow $'git fetch -q origin && git log --oneline -1 origin/main; ls .scratchpads/runs | tail -8; echo \'---\'; R=.scratchpads/runs/2026-10-16-timeline-clarity; sed -n \'1,40p\' $R/run.md; echo \'...\'; tail -60 $R/run.md'
expect allow $'cat ~/.claude/usage/limits.json | python3 -I -c \'import json,sys; d=json.load(sys.stdin); print([(r["kind"],r["percentUsed"]) for r in d["rate_limits"]])\'; R=/repo/.scratchpads/runs/2026-10-15-workflow-upkeep-3; wc -w $R/plan.md $R/analysis.md; rg -n \'^## |^### |^- \\*\\*(T|D)[0-9]\' $R/plan.md | cut -c1-200 | head -30'
expect_message 'can write it' 'rm plan.md'
expect_message 'change it with the Edit tool' 'mv x run.md'
# A variable that the command assigns twice, or assigns a quoted value with a space, still reads
# (the guard needs no second search of the assignment). A write through it blocks.
expect allow $'F=x; F=.scratchpads/runs/r/run.md; cat "$F"'
expect allow $'F="a b/run.md"; cat "$F"'
expect block $'F=x; F=.scratchpads/runs/r/run.md; echo x >> "$F"'
expect block $'F="a b/run.md"; echo x >> "$F"'
# The read that the block message recommends passes when its pattern is a write word.
expect allow $'rg -n tee .scratchpads/runs/x/run.md'
expect allow $'rg -c truncate .scratchpads/runs/x/analysis.md'
expect allow $'rg -n "rm" plan.md'
expect block $'echo x | tee -a run.md'
expect block $'time rm run.md'
# A prefix word takes its options before the command word.
expect block $'env -i rm .scratchpads/runs/x/run.md'
expect block $'env -u X rm run.md'
expect block $'sudo -n tee .scratchpads/runs/x/run.md'
expect block $'sudo -u root rm plan.md'
expect block $'command -p rm run.md'
expect block $'nice rm run.md'
expect block $'nice -n 5 rm run.md'
expect block $'xargs -0 rm run.md'
expect block $'xargs -I{} rm .scratchpads/runs/x/run.md'
expect block $'xargs -I {} rm .scratchpads/runs/x/run.md'
expect allow $'xargs -n 1 rg -n tee .scratchpads/runs/x/run.md'
expect allow $'nice -n 5 rg -n rm .scratchpads/runs/x/run.md'
expect block $'for f in a; do rm plan.md; done'
expect block "X=1 make x; $ld"
expect block "time make x; $ld"
expect block "(make x); $ld"
# A group, a negation, a shell keyword, env, and bash also start a command.
expect block "{ make x; }; $ld"
expect block "! make x; $ld"
expect block "if make x; then $ld; fi"
expect block "while make x; do $ld; done"
expect block "for i in 1; do make x; $ld; done"
expect block "if true; then :; else make x; $ld; fi"
expect block "if true; then make x; $ld; fi"
expect block "env X=1 make x; $ld"
expect block "bash scripts/with-lock.sh make x; $ld"

# A chain rule must hold for each join form, not only for the forms that a gate found one at a time
# (run 2026-10-08-upkeep-batch-4). Each chain rule calls this helper: one block case for each join
# of <first> and <second>, and one allow case for &&.
expect_each_join() {
  local first="$1" second="$2" join
  for join in '; ' $'\n' ' | ' ' & ' ' > log 2>&1 & ' $'\t;\t' ';  '; do
    expect block "$first$join$second"
  done
  expect allow "$first && $second"
}
for commit in 'git commit -m x' 'git -C /x/wt commit -m x' "git -C '/x y/wt' commit -m x" 'git -C "/x y/wt" commit -m x'; do
  expect_each_join 'make check' "$commit"
done
for first in 'git commit -F .scratchpads/commit-msg.txt' 'git -C /x/wt commit -m x' 'make test-filter FILTER=X' 'swift test' \
  'scripts/with-lock.sh make test-filter FILTER=X' 'scripts/with-lock.sh swift test' \
  'scripts/with-lock.sh scripts/probe.sh f swift build' "scripts/with-lock.sh scripts/probe.sh '/x y/f' swift build"; do
  expect_each_join "$first" "$ld"
done

# A repo hook or script test runs through scripts/with-lock.sh (AGENTS.md, Commands): a bare bash run
# of a .test.sh file ran beside three push checks (DLV-157/flake). Each run form after the prefix
# words blocks: a shell word with flags other than -n, or the bare path.
for run in 'bash scripts/with-lock.test.sh' 'bash a.test.sh & bash b.test.sh' 'bash a.test.sh; bash b.test.sh' \
  'cd ../wt && bash scripts/land.test.sh' 'scripts/land.test.sh' './scripts/land.test.sh' '../wt/scripts/land.test.sh' \
  'sh scripts/land.test.sh' '/bin/bash scripts/land.test.sh' '/bin/sh scripts/land.test.sh' 'bash -x scripts/land.test.sh' \
  'bash -ex scripts/land.test.sh' 'VAR=1 bash scripts/land.test.sh' 'time bash scripts/land.test.sh' \
  '(bash scripts/land.test.sh)' '{ bash scripts/land.test.sh; }' 'for t in a; do bash scripts/land.test.sh; done' \
  'if true; then bash scripts/land.test.sh; fi' 'scripts/probe.sh f bash scripts/land.test.sh' \
  'bash scripts/land.test.sh > log 2>&1' 'bash scripts/land.test.sh 2>&1 | tail -3' 'bash "scripts/land.test.sh"' \
  'bash .claude/hooks/git-guardrails.test.sh; bash scripts/land.test.sh' $'echo x\nbash scripts/land.test.sh' \
  'env X=1 scripts/land.test.sh' 'bash   scripts/land.test.sh'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
for run in "scripts/with-lock.sh make test-hooks HOOK_TESTS='scripts/land.test.sh'" 'scripts/with-lock.sh bash scripts/land.test.sh' \
  'WITH_LOCK_MAX_WAIT=5 scripts/with-lock.sh bash scripts/land.test.sh' 'scripts/with-lock.sh scripts/probe.sh f bash scripts/land.test.sh' \
  'scripts/with-lock.sh scripts/land.test.sh' 'bash -n scripts/land.test.sh' 'sh -n scripts/land.test.sh' 'bash -nx scripts/land.test.sh' \
  'rg -n case scripts/land.test.sh' 'sed -n 1,5p scripts/land.test.sh' 'echo bash scripts/land.test.sh' \
  'git add scripts/land.test.sh && git commit -F .scratchpads/commit-msg.txt' 'chmod +x scripts/land.test.sh' \
  'bash .scratchpads/run-tests.sh' 'bash .scratchpads/x/land.test.sh' 'bash scripts/land.sh' \
  $'cat > notes.txt <<\'EOF\'\nbash scripts/land.test.sh\nEOF'; do
  expect allow "$run"
done

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
mkdir -p "$tmp/p/scripts"
cp "$(dirname "$0")/../../scripts/check-sizes.sh" "$(dirname "$0")/../../scripts/check-waits.sh" "$tmp/p/scripts/" \
  || pre_fail 'no scripts/check-sizes.sh or scripts/check-waits.sh'
: > "$tmp/p/scripts/check-sizes.allow"
: > "$tmp/p/scripts/check-waits.allow"
git -C "$tmp/p" add .githooks scripts
gc "$tmp/p" -m hook || pre_fail 'the commit of the hook failed'
git -C "$tmp/p" worktree add -q "$tmp/pw" 2>/dev/null || pre_fail 'git worktree add failed'
git -C "$tmp/p" config core.hooksPath "$tmp/p/.githooks"
gc "$tmp/pw" -m absolute 2>"$tmp/err" && pre_fail 'a commit with an absolute hooks path passed'
grep -q 'make setup' "$tmp/err" || pre_fail 'the refusal does not name make setup'
git -C "$tmp/p" config core.hooksPath .githooks
gc "$tmp/pw" -m relative 2>"$tmp/err" && pre_fail 'a commit with no Makefile passed'
grep -q lint "$tmp/err" || pre_fail 'the hook of the worktree did not run make lint'
grep -q 'make setup' "$tmp/err" && pre_fail 'the hook names make setup with the .githooks path'
# A stamped make check-changed run marks its tree with the pid of run-checks.sh and its start time,
# and a commit during the run makes its pass stamp useless. A live mark refuses the commit and names
# the pid and its command. A pid whose start time differs (a reused pid), a dead pid, and a mark of
# another tree do not refuse. $$ of this shell is the live pid.
marks="$(git -C "$tmp/pw" rev-parse --path-format=absolute --git-dir)/dirigible-check-running"
mkdir -p "$marks" && ps -o lstart= -p $$ > "$marks/$$"
gc "$tmp/pw" -m marked 2>"$tmp/err" && pre_fail 'a commit during a check-changed run passed'
grep -q "make check-changed run (pid $$: .*bash" "$tmp/err" || pre_fail "the refusal does not name the pid and its command: $(cat "$tmp/err")"
gc "$tmp/p" -m other 2>"$tmp/err"
grep -q 'check-changed run' "$tmp/err" && pre_fail 'a mark of the worktree refused a commit in the main tree'
echo 'Mon Jan  1 00:00:00 2001' > "$marks/$$"
gc "$tmp/pw" -m reused 2>"$tmp/err"
grep -q lint "$tmp/err" || pre_fail "a reused pid did not reach make lint: $(cat "$tmp/err")"
rm "$marks/$$"
dead="$(bash -c 'echo $$')"
echo 'Mon Jan  1 00:00:00 2001' > "$marks/$dead"
gc "$tmp/pw" -m dead 2>"$tmp/err"
grep -q lint "$tmp/err" || pre_fail "a dead pid did not reach make lint: $(cat "$tmp/err")"
# Before make lint, the hook runs scripts/check-sizes.sh and scripts/check-waits.sh on the working
# tree. A Swift file of 401 lines under Sources/, or a raw .wait(timeout: under Tests/, with no
# allow entry, refuses the commit before make lint. 400 lines, and a raw wait under Sources/, pass.
mkdir -p "$tmp/pw/Sources/M" "$tmp/pw/Tests/T"
seq 401 | sed 's|^|// |' > "$tmp/pw/Sources/M/Big.swift"
gc "$tmp/pw" -m big 2>"$tmp/err" && pre_fail 'a commit with a Swift file of 401 lines passed'
grep -q '^check-sizes: Sources/M/Big.swift: 401 lines, over 400' "$tmp/err" || pre_fail "a file of 401 lines gave no check-sizes line: $(cat "$tmp/err")"
grep -q lint "$tmp/err" && pre_fail 'make lint ran before the size gate'
seq 400 | sed 's|^|// |' > "$tmp/pw/Sources/M/Big.swift"
gc "$tmp/pw" -m fits 2>"$tmp/err"
grep -q check-sizes "$tmp/err" && pre_fail 'a Swift file of 400 lines failed the size gate'
grep -q lint "$tmp/err" || pre_fail "a Swift file of 400 lines did not reach make lint: $(cat "$tmp/err")"
rm "$tmp/pw/Sources/M/Big.swift"
echo 'group.wait(timeout: .now() + 1)' > "$tmp/pw/Tests/T/W.swift"
gc "$tmp/pw" -m wait 2>"$tmp/err" && pre_fail 'a commit with a raw wait under Tests/ passed'
grep -qF 'check-waits: Tests/T/W.swift:1: a raw .wait(timeout: with no allow entry' "$tmp/err" || pre_fail "a raw wait under Tests/ gave no check-waits line: $(cat "$tmp/err")"
grep -q lint "$tmp/err" && pre_fail 'make lint ran before the wait gate'
mv "$tmp/pw/Tests/T/W.swift" "$tmp/pw/Sources/M/W.swift"
gc "$tmp/pw" -m source-wait 2>"$tmp/err"
grep -q check-waits "$tmp/err" && pre_fail 'a raw wait under Sources/ failed the wait gate'
grep -q lint "$tmp/err" || pre_fail "a raw wait under Sources/ did not reach make lint: $(cat "$tmp/err")"

# The shipped commit-msg hook has no word pair check: a message with a pair that no staged file shows commits.
msg_fail() { echo "FAIL: commit-msg: $1"; failures=$((failures + 1)); }
m="$tmp/m"
git init -q "$m"
mkdir -p "$m/.githooks"
cp "$(dirname "$0")/../../.githooks/commit-msg" "$m/.githooks/" || msg_fail 'no .githooks/commit-msg'
git -C "$m" config core.hooksPath .githooks
echo x > "$m/other.txt"
git -C "$m" add other.txt
gc "$m" -m 'x: 10 before, 11 after' || msg_fail 'a word pair that no staged file shows was refused'

# The commit-msg hook refuses a staged change that cuts graded eval key text (evals-for.sh
# --staged): a key term that the staged file holds fewer times than the file at HEAD, or a 5-word
# run of the key points that the file at HEAD holds and the staged file does not. An insertion next
# to kept key text, a key that changes in the same commit, and a body line `Eval keys: <IDs>` pass.
k="$tmp/k" deliver=.claude/skills/deliver/SKILL.md
git init -q "$k"
mkdir -p "$k/.githooks" "$k/scripts" "$k/docs/workflow" "$k/.claude/skills/deliver"
cp "$(dirname "$0")/../../.githooks/commit-msg" "$k/.githooks/"
cp "$(dirname "$0")/../../scripts/evals-for.sh" "$k/scripts/"
git -C "$k" config core.hooksPath .githooks
cat > "$k/docs/workflow/evals.md" <<'EOF'
# Evals

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E2 | policy | s | q | (c) Before the push: `make check-changed BASE=origin/main`, which picks `check-docs`. | `.claude/skills/deliver/SKILL.md` | - | - |
| E37 | policy | s | q | (b) Run the same command again with `run_in_background`. | `AGENTS.md` | - | - |
EOF
printf 'Then run the push check `make check-changed BASE=origin/main` with `run_in_background`.\nCommit nothing until it ends.\n' > "$k/$deliver"
printf 'When the call stops, run the same command again with `run_in_background`; a subagent waits.\n' > "$k/AGENTS.md"
git -C "$k" add -A
gc "$k" -m base || msg_fail 'the first commit of the eval key fixture was refused'
key_refused() {
  gc "$k" "$@" 2>"$tmp/err" && msg_fail "a cut of eval key text passed: $*"
  grep -q "$want_id" "$tmp/err" || msg_fail "the refusal names no $want_id: $(cat "$tmp/err")"
}
printf 'Commit nothing until it ends.\n' > "$k/$deliver"
git -C "$k" add -A
want_id=E2 key_refused -m 'cut the push check'
printf 'Then run the push check `make check-changed BASE=origin/main` with `run_in_background`.\nCommit no file until it ends.\n' > "$k/$deliver"
git -C "$k" add -A
gc "$k" -m 'keep the key line' 2>"$tmp/err" || msg_fail "a change that keeps the key text was refused: $(cat "$tmp/err")"
printf 'When the call stops, run the same command again with `run_in_background` and a Bash `timeout` of 7200000; a subagent waits.\n' > "$k/AGENTS.md"
git -C "$k" add -A
gc "$k" -m 'insert a timeout' 2>"$tmp/err" || msg_fail "an insertion next to kept key text was refused: $(cat "$tmp/err")"
sed -i '' 's|BASE=origin/main`, which|BASE=<base>`, which|' "$k/docs/workflow/evals.md"
sed -i '' 's|BASE=origin/main|BASE=<base>|' "$k/$deliver"
git -C "$k" add -A
gc "$k" -m 'a rule and its key' 2>"$tmp/err" || msg_fail "a rule and its key change in one commit was refused: $(cat "$tmp/err")"
printf 'A subagent waits.\n' > "$k/AGENTS.md"
git -C "$k" add -A
want_id=E37 key_refused -m 'cut the rerun'
gc "$k" -m $'cut the rerun\n\nEval keys: E37' 2>"$tmp/err" || msg_fail "a cut with an Eval keys line was refused: $(cat "$tmp/err")"

# The second hook, agent-guard.sh, refuses an Agent call with worktree isolation: such a worktree does
# not fit the run layout, and its creation can set the hooks path of the shared git config. It also
# refuses a brief of Agent, SendMessage, or delegate_task with a wrong commit message path.
agent_hook="$(dirname "$0")/agent-guard.sh"
expect_agent() {
  local want="$1" json="$2" got
  printf '%s' "$json" | "$agent_hook" 2>"$tmp/agent-err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: agent-guard: expected $want, got $got: $json"; failures=$((failures + 1)); }
}
expect_agent block '{"tool_input":{"description":"d","prompt":"p","isolation":"worktree"}}'
grep -q 'git worktree add' "$tmp/agent-err" ||
  { echo "FAIL: the agent-guard block message does not name git worktree add: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
expect_agent allow '{"tool_input":{"description":"d","prompt":"p"}}'
python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
ok = any(e.get("matcher") == "Agent|SendMessage|mcp__t3-code__delegate_task"
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/agent-guard.sh") for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$settings" 2>/dev/null || { echo "FAIL: .claude/settings.json does not register agent-guard.sh for Agent, SendMessage, and delegate_task"; failures=$((failures + 1)); }

# A brief with a git commit -F or --file path of a commit-msg.txt or a .scratchpads/ file other
# than .scratchpads/commit-msg.txt blocks, in the field of each tool. A placeholder, another file
# name, and the correct path in backticks or before a ; or . pass.
# expect_brief <want> <tool name, or - for none> <field> <text> [isolation]
expect_brief() {
  local want="$1" got
  plutil -create xml1 "$input"
  [[ "$2" == - ]] || plutil -insert tool_name -string "$2" "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert "tool_input.$3" -string "$4" "$input"
  [[ -z "${5:-}" ]] || plutil -insert tool_input.isolation -string "$5" "$input"
  plutil -convert json "$input"
  "$agent_hook" < "$input" 2>"$tmp/agent-err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: agent-guard: expected $want, got $got: $2 $3: $4"; failures=$((failures + 1)); }
}
expect_brief block Agent prompt $'Commit:\nrun git commit -F .scratchpads/runs/x/commit-msg.txt'
grep -qF 'git commit -F .scratchpads/commit-msg.txt' "$tmp/agent-err" && grep -qF 'put the text in a file in the run folder' "$tmp/agent-err" ||
  { echo "FAIL: the agent-guard brief message does not name the path and the data route: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
for text in 'git commit -F /abs/.scratchpads/commit-msg.txt' 'git commit --file=.scratchpads/runs/x/commit-msg.txt' \
  'git commit -q --no-verify -F .scratchpads/runs/x/commit-msg.txt' 'Run `git commit -F .scratchpads/runs/x/commit-msg.txt` at the end.'; do
  expect_brief block Agent prompt "$text"
done
expect_brief block SendMessage message 'Then git commit -F .scratchpads/runs/x/commit-msg.txt.'
expect_brief block Agent prompt 'Commit with git commit -F ../main/.scratchpads/commit-msg.txt, then rg -F foo bar'
expect_brief block Agent prompt 'git commit -F ../other/.scratchpads/commit-msg.txt then git commit -F .scratchpads/commit-msg.txt'
expect_brief allow Agent prompt 'git commit -F .scratchpads/commit-msg.txt, and find the row with rg -F .scratchpads/runs/x/rows .gitignore'
expect_brief allow Agent prompt 'Commit with git commit -m fix, then find the row with rg -F .scratchpads/runs/x/rows .gitignore'
expect_brief allow Agent prompt 'Commit with git commit -m fix. Then find the row with rg -F .scratchpads/runs/x/rows .gitignore'
expect_brief allow Agent prompt 'Run git commit -m fix && rg -F .scratchpads/runs/x/rows .gitignore'
# A separator inside the quoted message does not end the commit.
expect_brief block Agent prompt 'Run git commit -m "fix; thing" -F ../main/.scratchpads/commit-msg.txt'
expect_brief block mcp__t3-code__delegate_task task 'git commit -F /abs/.scratchpads/commit-msg.txt'
expect_brief block - prompt 'git commit -F .scratchpads/runs/x/commit-msg.txt'
for text in 'git commit -F .scratchpads/commit-msg.txt' 'git commit --file=.scratchpads/commit-msg.txt' \
  'Run `git commit -F .scratchpads/commit-msg.txt`; never commit a .scratchpads file.' \
  'Commit with `git commit -F .scratchpads/commit-msg.txt`.' 'Use `git commit -F` with the message file.' \
  'git commit -F <file>' 'git commit -F <file in the run folder>' 'git commit -F <msgfile>' 'git commit -F RUN/msg-3a.txt' \
  'git commit -F msg.txt' 'git commit --file=msg.txt' 'Read run.md and continue at S6.'; do
  expect_brief allow Agent prompt "$text"
done
expect_brief allow SendMessage message 'git commit -F .scratchpads/commit-msg.txt, then hand back.'
expect_brief allow mcp__t3-code__delegate_task task 'Fix the tests and commit.' worktree

# The third hook, usage-hook.sh, gives the usage mode as context at an agent start. It denies nothing
# and always exits 0. The fixture clock and limits file give each mode.
usage_hook="$(dirname "$0")/usage-hook.sh"
usage_now=1792000000
usage_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# expect_usage <mode> <five_hour percent> <minutes to the reset>
expect_usage() {
  local mode="$1" out code
  printf '{"written_at":%s,"rate_limits":[{"kind":"five_hour","percentUsed":%s,"resetsAt":"%s"}]}\n' \
    $((usage_now * 1000)) "$2" "$(usage_iso $((usage_now + $3 * 60)))" > "$tmp/usage-limits.json"
  out="$(printf '{"tool_input":{}}' | USAGE_LIMITS_FILE="$tmp/usage-limits.json" USAGE_MODE_NOW=$usage_now "$usage_hook" 2>/dev/null)"
  code=$?
  [[ $code -eq 0 ]] || { echo "FAIL: usage-hook $mode: exit $code"; failures=$((failures + 1)); }
  printf '%s' "$out" | python3 -c '
import json, sys
mode = sys.argv[1]
out = json.load(sys.stdin)
assert list(out) == ["hookSpecificOutput"], "one hookSpecificOutput object"
h = out["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse", "event name"
assert "Usage mode: " + mode + "." in h["additionalContext"], "context names the mode"
assert "permissionDecision" not in h and "permissionDecisionReason" not in h, "no deny"
if mode == "stop":
    assert "Stop at a safe point" in h["additionalContext"], "stop text"
    assert "except a free-model job, the reflect agent," in h["additionalContext"], "stop text names the free-job exception"
' "$mode" 2>"$tmp/usage-err" || { echo "FAIL: usage-hook $mode: $(tail -n 1 "$tmp/usage-err") (output: $out)"; failures=$((failures + 1)); }
}
expect_usage normal 10 120
expect_usage save 76 120
expect_usage spend 10 30
expect_usage stop 85 120
# A broken usage-mode.sh (no jq, or a non-zero exit) gives the normal text and exit 0.
mkdir "$tmp/nojq"
for t in cat dirname date; do ln -s "$(command -v $t)" "$tmp/nojq/$t"; done
out="$(printf '{}' | PATH="$tmp/nojq" /bin/bash "$usage_hook" 2>/dev/null)"
[[ $? -eq 0 && "$out" == *"Usage mode: normal."* ]] ||
  { echo "FAIL: usage-hook with no jq did not give the normal text and exit 0: $out"; failures=$((failures + 1)); }

# The settings register usage-hook.sh for each tool that starts an agent job. The matcher is a
# regex that must match the whole tool name.
# matcher_covers <settings file> <tool name>
matcher_covers() {
  python3 -c '
import json, re, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
ok = any(re.fullmatch(e.get("matcher", ""), sys.argv[2])
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/usage-hook.sh") for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$1" "$2" 2>/dev/null
}
printf '{"hooks":{"PreToolUse":[{"matcher":"Agent|Workflow","hooks":[{"type":"command","command":"x/.claude/hooks/usage-hook.sh"}]}]}}' > "$tmp/old-settings.json"
for tool in Agent Workflow SendMessage mcp__t3-code__delegate_task; do
  matcher_covers "$settings" "$tool" || { echo "FAIL: .claude/settings.json does not register usage-hook.sh for $tool"; failures=$((failures + 1)); }
done
for tool in SendMessage mcp__t3-code__delegate_task; do
  matcher_covers "$tmp/old-settings.json" "$tool" && { echo "FAIL: the matcher check passed a settings file with no $tool"; failures=$((failures + 1)); }
done

# The fourth hook, handback-guard.sh, refuses a SubagentHandback call while a background task of the
# agent runs. It reads the transcript of the subagent: <dir>/s.jsonl is the session file and
# <dir>/s/subagents/agent-a1.jsonl is the agent file. Timestamps come from the clock of this test.
guard_hook="$(dirname "$0")/handback-guard.sh"
hb_now="$(date +%s)"
hb_iso() { date -u -r $((hb_now - $1 * 60)) +%Y-%m-%dT%H:%M:%S.000Z; }
# hb_line <role> <minutes ago> <content JSON>: one line of a transcript
hb_line() { printf '{"type":"%s","timestamp":"%s","message":{"role":"%s","content":%s}}\n' "$1" "$(hb_iso "$2")" "$1" "$3"; }
# hb_text <role> <minutes ago> <text>: an entry with a text content
hb_text() { local t="${3//\\/\\\\}"; hb_line "$1" "$2" "\"${t//\"/\\\"}\""; }
# hb_use <minutes ago> <use id> <tool> <input JSON>: an assistant tool call
hb_use() { hb_line assistant "$1" "[{\"type\":\"tool_use\",\"id\":\"$2\",\"name\":\"$3\",\"input\":$4}]"; }
# hb_result <minutes ago> <use id> <text>: the result of a tool call
hb_result() { hb_line user "$1" "[{\"type\":\"tool_result\",\"tool_use_id\":\"$2\",\"content\":\"$3\"}]"; }
# hb_session <name>: write stdin as the agent transcript, and name its folder in hb_dir
hb_session() { hb_dir="$tmp/$1"; mkdir -p "$hb_dir/s/subagents"; : > "$hb_dir/s.jsonl"; cat > "$hb_dir/s/subagents/agent-a1.jsonl"; }
# hb_in <tool> [<tool_input JSON>]: the hook input of agent a1
hb_in() {
  local ti="${2-}"
  [[ -n "$ti" ]] || ti='{}'
  printf '{"transcript_path":"%s/s.jsonl","agent_id":"a1","tool_name":"%s","tool_input":%s}' "$hb_dir" "$1" "$ti"
}
# hb_expect <hook> <want exit> <label> <hook input>; the stderr stays in $tmp/hb-err
hb_expect() {
  local code
  printf '%s' "$4" | "$1" 2>"$tmp/hb-err"
  code=$?
  [[ $code -eq $2 ]] || { echo "FAIL: $(basename "$1") $3: expected exit $2, got $code"; failures=$((failures + 1)); }
}
hb_err_has() {
  grep -qF -- "$2" "$tmp/hb-err" || { echo "FAIL: $1: stderr has no '$2': $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
}
hb_bg_start() {
  hb_use 12 u1 Bash '{"command":"sleep 300","run_in_background":true}'
  hb_result 12 u1 'Command running in background with ID: b1. Output is being written to: /x'
}
hb_mon_start() {
  hb_use "$1" u3 Monitor '{"command":"x"}'
  hb_result "$1" u3 'Monitor started (task m1, expires in 30m. Output is being written to: /x'
}

hb_session running < <(hb_bg_start)
hb_expect "$guard_hook" 2 'a running background Bash' "$(hb_in SubagentHandback)"
hb_err_has 'a running background Bash' 'b1 (shell)'
hb_err_has 'a running background Bash' 'TaskStop b1'
hb_err_has 'a running background Bash' 'handback-guard.sh'
hb_err="$(cat "$tmp/hb-err")"
[[ "${hb_err%%TaskStop b1*}" != *[Ww]ait* ]] ||
  { echo "FAIL: the hand-back refusal says wait before it names TaskStop b1: $hb_err"; failures=$((failures + 1)); }
[[ "$(sed 's/Never stop a task with pkill -f\.//' "$tmp/hb-err")" != *pkill* ]] ||
  { echo "FAIL: the hand-back refusal names pkill other than in a never rule: $hb_err"; failures=$((failures + 1)); }
running_dir="$hb_dir"

for status in completed failed killed; do
  hb_session "end-$status" < <(hb_bg_start; hb_text user 3 "<task-notification><task-id>b1</task-id><status>$status</status></task-notification>")
  hb_expect "$guard_hook" 0 "a $status notification ends the task" "$(hb_in SubagentHandback)"
done
hb_session taskstop < <(hb_bg_start; hb_use 3 u2 TaskStop '{"task_id":"b1"}'; hb_result 3 u2 'Error: No task found with ID: b1')
hb_expect "$guard_hook" 0 'a TaskStop call ends the task' "$(hb_in SubagentHandback)"
hb_session mon-expired < <(hb_mon_start 20; hb_text user 2 '<task-notification><task-id>m1</task-id><summary>s</summary><event>[Monitor expired after 30m, stopped]</event></task-notification>')
hb_expect "$guard_hook" 0 'a Monitor expiry event ends the monitor' "$(hb_in SubagentHandback)"
hb_session mon-old < <(hb_mon_start 31)
hb_expect "$guard_hook" 0 'a Monitor older than its expiry time ends' "$(hb_in SubagentHandback)"
hb_session child < <(
  hb_use 9 u4 Agent '{"prompt":"p"}'
  hb_line user 9 '[{"type":"tool_result","tool_use_id":"u4","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: c1 (internal)"}]}]'
  hb_text user 2 '<agent-message from="c1"> [Subagent hand-back] done'
)
hb_expect "$guard_hook" 0 'a child hand-back message ends the agent task' "$(hb_in SubagentHandback)"

hb_session mon-event < <(hb_mon_start 5; hb_text user 2 '<task-notification><task-id>m1</task-id><summary>s</summary><event>a line</event></task-notification>')
hb_expect "$guard_hook" 2 'a Monitor event with no status does not end the monitor' "$(hb_in SubagentHandback)"
hb_err_has 'a Monitor event with no status' 'm1 (monitor)'
hb_session quoted < <(hb_bg_start; hb_line assistant 3 '[{"type":"text","text":"<task-notification><task-id>b1</task-id><status>completed</status></task-notification>"}]')
hb_expect "$guard_hook" 2 'an assistant text that quotes a notification does not end the task' "$(hb_in SubagentHandback)"
hb_session mon-new < <(hb_mon_start 10)
hb_expect "$guard_hook" 2 'a Monitor before its expiry time still runs' "$(hb_in SubagentHandback)"

# The guard fails open: a refusal with no way out loses the report.
hb_dir="$running_dir"
hb_expect "$guard_hook" 0 'no agent_id (the lead)' "$(printf '{"transcript_path":"%s/s.jsonl","tool_name":"SubagentHandback"}' "$hb_dir")"
hb_expect "$guard_hook" 0 'another tool' "$(hb_in Bash '{"command":"ls"}')"
hb_expect "$guard_hook" 0 'no transcript file' "$(printf '{"transcript_path":"%s/none/s.jsonl","agent_id":"a1","tool_name":"SubagentHandback"}' "$tmp")"
hb_expect "$guard_hook" 0 'input that is not JSON' 'not json'

# hook_registered <settings file> <hook script> <tool name>: a PreToolUse entry runs the script for the tool
hook_registered() {
  python3 -c '
import json, re, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
def covers(matcher):
    return matcher in (None, "", "*") or re.fullmatch(matcher, sys.argv[3]) is not None
ok = any(covers(e.get("matcher"))
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/" + sys.argv[2]) for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$1" "$2" "$3" 2>/dev/null
}
hook_registered "$settings" handback-guard.sh SubagentHandback ||
  { echo "FAIL: .claude/settings.json does not register handback-guard.sh for SubagentHandback"; failures=$((failures + 1)); }
hook_registered "$tmp/old-settings.json" handback-guard.sh SubagentHandback &&
  { echo "FAIL: the registration check passed a settings file with no handback-guard.sh"; failures=$((failures + 1)); }

# The fifth hook, agent-clock.sh, refuses the tool calls of a subagent after 90 active minutes. A gap
# between two entries of the transcript counts at most 15 min.
clock_hook="$(dirname "$0")/agent-clock.sh"
# hb_span <from> <to>: one entry for each minute from <from> to <to> minutes ago
hb_span() { local m; for ((m = $1; m >= $2; m--)); do hb_text user "$m" x; done; }
# hb_bash <command>: the hook input of a Bash call of agent a1
hb_bash() { hb_in Bash "{\"command\":\"$1\"}"; }

hb_session over < <(hb_span 91 0)
hb_expect "$clock_hook" 2 'make build at 91 active minutes' "$(hb_bash 'make build')"
hb_err_has 'the clock refusal' '90'
hb_err_has 'the clock refusal' 'run.md'
hb_err_has 'the clock refusal' 'SubagentHandback'
hb_err_has 'the clock refusal' 'git add <paths> && git commit -F .scratchpads/commit-msg.txt'
hb_session under < <(hb_span 89 0)
hb_expect "$clock_hook" 0 'make build at 89 active minutes' "$(hb_bash 'make build')"
hb_session idle < <(hb_span 330 300; hb_span 30 0)
hb_expect "$clock_hook" 0 'a 5 h gap counts 15 min (75 active minutes)' "$(hb_bash 'make build')"
hb_session short < <(hb_span 11 0)
AGENT_CLOCK_MIN=10 hb_expect "$clock_hook" 2 'AGENT_CLOCK_MIN sets the limit' "$(hb_bash 'make build')"
hb_err_has 'AGENT_CLOCK_MIN' 'limit of 10'

hb_dir="$tmp/over"
for tool in Read ToolSearch TaskStop SubagentHandback; do
  hb_expect "$clock_hook" 0 "$tool past the limit" "$(hb_in "$tool")"
done
hb_expect "$clock_hook" 2 'Edit of a Sources/ path past the limit' "$(hb_in Edit '{"file_path":"/t/Sources/A/a.swift"}')"
hb_expect "$clock_hook" 2 'Write with no file_path past the limit' "$(hb_in Write)"
hb_expect "$clock_hook" 0 'Write of .scratchpads/commit-msg.txt past the limit' "$(hb_in Write '{"file_path":"/t/.scratchpads/commit-msg.txt"}')"
hb_expect "$clock_hook" 0 'Edit of run.md under .scratchpads past the limit' "$(hb_in Edit '{"file_path":"/t/.scratchpads/runs/r/run.md"}')"
for command in 'git status' 'git diff --stat' 'git log -1' 'git add -A' 'git commit -F x' \
  '.claude/skills/deliver/scripts/log-decision.sh run 4 d w e r' \
  'git commit -F x 2>&1' 'git -c core.pager=cat log -1' \
  'cd T && git commit -F x' 'git -C T status' 'cd T && R=x .claude/skills/deliver/scripts/log-decision.sh $R --from f'; do
  hb_expect "$clock_hook" 0 "Bash '$command' past the limit" "$(hb_bash "$command")"
done
for command in 'git push origin x' 'make test' 'cd T && git commit -F x && make test' 'git status && make test' \
  'git commit -F x; scripts/with-lock.sh make check-fast' 'git status $(make test)' 'git status & make test' \
  'bash x/log-decision.sh' 'x/log-decision.sh run 4 d w e r' 'git status `make test`' 'git diff <(make test)' \
  'git diff >(make test)'; do
  hb_expect "$clock_hook" 2 "Bash '$command' past the limit" "$(hb_bash "$command")"
done

# A check that started before the limit can finish and be read.
hb_session check < <(
  hb_span 91 81
  hb_use 80 u1 Bash '{"command":"make test","run_in_background":true}'
  hb_result 80 u1 'Command running in background with ID: b1. Output is being written to: /x'
  hb_span 79 0
)
for tool in Monitor TaskOutput; do
  hb_expect "$clock_hook" 0 "$tool with a running background task" "$(hb_in "$tool")"
done
hb_dir="$tmp/over"
hb_expect "$clock_hook" 2 'Monitor with no running background task' "$(hb_in Monitor)"

hb_expect "$clock_hook" 0 'no agent_id (the lead)' "$(printf '{"transcript_path":"%s/s.jsonl","tool_name":"Bash","tool_input":{"command":"make test"}}' "$hb_dir")"
hb_expect "$clock_hook" 0 'no transcript file' "$(printf '{"transcript_path":"%s/none/s.jsonl","agent_id":"a1","tool_name":"Bash","tool_input":{"command":"make test"}}' "$tmp")"
hb_expect "$clock_hook" 0 'input that is not JSON' 'not json'
for tool in Bash Read; do
  hook_registered "$settings" agent-clock.sh "$tool" ||
    { echo "FAIL: .claude/settings.json does not register agent-clock.sh for $tool"; failures=$((failures + 1)); }
done

# The sixth hook, write-guard.sh, refuses a Write over an existing run.md, plan.md, or analysis.md
# of a run folder: the Edit tool changes such a file. A new file and each other name pass.
write_hook="$(dirname "$0")/write-guard.sh"
wg_dir="$tmp/wg/.scratchpads/runs/r"
mkdir -p "$wg_dir" "$tmp/wg/docs"
for name in run.md plan.md analysis.md pr.md review-plan-1.md; do echo x > "$wg_dir/$name"; done
echo x > "$tmp/wg/docs/run.md"
# wg_expect <exit status> <path>: a Write input for the path gives the exit status.
wg_expect() {
  local code
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"y"}}' "$2" | "$write_hook" 2>"$tmp/write-err"
  code=$?
  [[ $code -eq $1 ]] || { echo "FAIL: write-guard: expected exit $1, got $code: $2"; failures=$((failures + 1)); }
}
for name in run.md plan.md analysis.md; do
  wg_expect 2 "$wg_dir/$name"
  grep -q 'with the Edit tool' "$tmp/write-err" ||
    { echo "FAIL: the write-guard message for $name does not name the Edit tool: $(cat "$tmp/write-err")"; failures=$((failures + 1)); }
done
wg_expect 0 "$wg_dir/pr.md"
wg_expect 0 "$wg_dir/review-plan-1.md"
wg_expect 0 "$tmp/wg/.scratchpads/runs/new/run.md"
wg_expect 0 "$tmp/wg/docs/run.md"
hook_registered "$settings" write-guard.sh Write ||
  { echo "FAIL: .claude/settings.json does not register write-guard.sh for Write"; failures=$((failures + 1)); }

# The seventh hook, stop-guard.sh, runs when the lead ends a turn. It never blocks: it appends a line to
# dirigible-stop-shadow.log in the git common dir. Rule A logs the stop while only background shells
# run (nothing wakes the loop when a shell ends). Rule B logs when no task runs, an open run has an
# unticked phase, and its run.md has no `waits: user` line.
stop_hook="$(dirname "$0")/stop-guard.sh"
# lead_session <name>: write stdin as the lead transcript, and name its folder in hb_dir
lead_session() { hb_dir="$tmp/$1"; mkdir -p "$hb_dir"; cat > "$hb_dir/s.jsonl"; }
# stop_in <stop_hook_active> [<cwd>]: the Stop hook input of the lead
stop_in() { printf '{"hook_event_name":"Stop","transcript_path":"%s/s.jsonl","stop_hook_active":%s,"cwd":"%s"}' "$hb_dir" "$1" "${2:-$tmp}"; }
hb_agent_start() {
  hb_use 8 u4 Agent '{"prompt":"x","run_in_background":true}'
  hb_result 8 u4 'Async agent launched successfully. agentId: a2 (internal ID)'
}
# stop_fixture <name>: a git checkout with no commit, and its stop-shadow log path in stop_log
stop_fixture() { stop_fx="$tmp/$1"; mkdir -p "$stop_fx/.scratchpads/runs"; git init -q "$stop_fx"; stop_log="$stop_fx/.git/dirigible-stop-shadow.log"; }
# stop_run <name> <status> [<extra run.md line>]: a run folder of the fixture with one unticked phase
stop_run() {
  mkdir -p "$stop_fx/.scratchpads/runs/$1"
  printf '# Run %s\n\n- Status: %s\n- Branch: chore/%s\n%s\n## Phases\n\n- [x] 0 Open\n- [ ] 1 Analyze\n' "$1" "$2" "$1" "${3-}" > "$stop_fx/.scratchpads/runs/$1/run.md"
  printf '2026-10-28T10:00\t0\tx\n' > "$stop_fx/.scratchpads/runs/$1/decisions.tsv"
}
stop_lines() { if [[ -f "$stop_log" ]]; then wc -l < "$stop_log" | tr -d ' '; else echo 0; fi; }
# stop_expect <case> <input>: the hook exits 0 and prints nothing on stdout or stderr (it never blocks)
stop_expect() {
  local out code
  out="$(printf '%s' "$2" | "$stop_hook" 2>"$tmp/hb-err")"
  code=$?
  [[ $code -eq 0 ]] || { echo "FAIL: stop-guard.sh $1: expected exit 0, got $code: $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
  [[ -z "$out" && ! -s "$tmp/hb-err" ]] ||
    { echo "FAIL: stop-guard.sh $1: it printed output, so it blocks or talks: $out $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
}

# Rule A: only background shells run. The hook logs one line with its reason and does not block.
stop_fixture fx-shell
lead_session stop-shell < <(hb_bg_start)
stop_expect 'only a background shell runs' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 1 && "$(< "$stop_log")" == *' would-block-shell b1: only background shells run, no Monitor' ]] ||
  { echo "FAIL: rule A logs one would-block-shell line with its reason: $(cat "$stop_log" 2>&1)"; failures=$((failures + 1)); }
stop_expect 'rule A, second call' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 2 ]] || { echo "FAIL: rule A adds a line for each stop: $(stop_lines)"; failures=$((failures + 1)); }
stop_expect 'stop_hook_active is true' "$(stop_in true "$stop_fx")"
[[ "$(stop_lines)" == 2 ]] || { echo "FAIL: a stop with stop_hook_active true adds a line: $(stop_lines)"; failures=$((failures + 1)); }
stop_expect 'rule A outside a git checkout' "$(stop_in false "$tmp")"

stop_fixture fx-shell-pass
lead_session stop-shell-monitor < <(hb_bg_start; hb_mon_start 5)
stop_expect 'a shell and a Monitor' "$(stop_in false "$stop_fx")"
lead_session stop-shell-agent < <(hb_bg_start; hb_agent_start)
stop_expect 'a shell and a running agent' "$(stop_in false "$stop_fx")"
lead_session stop-shell-ended < <(hb_bg_start; hb_text user 3 '<task-notification><task-id>b1</task-id><status>completed</status></task-notification>')
stop_expect 'the shell ended' "$(stop_in false "$stop_fx")"
stop_expect 'no transcript file' "$(printf '{"transcript_path":"%s/none/s.jsonl","stop_hook_active":false,"cwd":"%s"}' "$tmp" "$stop_fx")"
stop_expect 'input that is not JSON' 'not json'
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: a pass case of rule A adds a line: $(cat "$stop_log")"; failures=$((failures + 1)); }

# Rule B, with a fixture checkout that holds the runs of the lead. A run is open when its run.md has a
# `- Status: open` line; the lead in the main checkout gets the run whose folder holds cwd, else the
# open run with the newest decisions.tsv row.
lead_session stop-idle < <(hb_text user 3 x)

stop_fixture fx-open
stop_run r1 open
stop_expect 'rule B does not block' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 1 && "$(< "$stop_log")" == *' would-block r1 via newest row: - [ ] 1 Analyze' ]] ||
  { echo "FAIL: rule B logs one would-block line for the open run: $(cat "$stop_log" 2>&1)"; failures=$((failures + 1)); }
stop_expect 'rule B, second call' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 2 ]] || { echo "FAIL: rule B adds a line for each stop: $(stop_lines)"; failures=$((failures + 1)); }

stop_fixture fx-done
stop_run r1 done
stop_expect 'a run with status done' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: a done run adds a line to the stop log"; failures=$((failures + 1)); }

stop_fixture fx-waits
stop_run r1 open 'waits: user (the plan gate)'
stop_expect 'a run that waits for the user' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: a waits: user line adds a line to the stop log"; failures=$((failures + 1)); }

stop_fixture fx-task
stop_run r1 open
lead_session stop-task-monitor < <(hb_bg_start; hb_mon_start 5)
stop_expect 'a running Monitor' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: rule B logs while a Monitor runs"; failures=$((failures + 1)); }

stop_fixture fx-end20
stop_run r1 open
for i in $(seq 20); do echo "2026-10-28T10:00:0${i: -1}Z would-block r1 via newest row: - [ ] 1 Analyze" >> "$stop_log"; done
lead_session stop-end20 < <(hb_text user 3 x)
stop_expect 'a log with 20 would-block lines' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 && "$(tail -n 1 "$stop_log")" == *' done' ]] ||
  { echo "FAIL: 20 would-block lines end rule B with one done line: $(tail -n 2 "$stop_log")"; failures=$((failures + 1)); }
stop_expect 'a log with a done line' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 ]] || { echo "FAIL: a log with a done line gets a line"; failures=$((failures + 1)); }

stop_fixture fx-old
stop_run r1 open
echo "$(date -u -v-15d +%Y-%m-%dT%H:%M:%SZ) would-block r1 via newest row: - [ ] 1 Analyze" > "$stop_log"
stop_expect 'a log whose first line is 15 days old' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 2 && "$(tail -n 1 "$stop_log")" == *' done' ]] ||
  { echo "FAIL: a first line of 15 days ends rule B with one done line: $(tail -n 2 "$stop_log")"; failures=$((failures + 1)); }

stop_fixture fx-end20-shell
for i in $(seq 10); do echo "2026-10-28T10:00:0${i: -1}Z would-block-shell b1: only background shells run, no Monitor" >> "$stop_log"; done
for i in $(seq 10); do echo "2026-10-28T10:01:0${i: -1}Z would-block r1 via newest row: - [ ] 1 Analyze" >> "$stop_log"; done
lead_session stop-end20-shell < <(hb_bg_start)
stop_expect 'a log with 20 lines of both rules, a shell runs' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 && "$(tail -n 1 "$stop_log")" == *' done' ]] ||
  { echo "FAIL: 20 lines of both rules end rule A with one done line: $(tail -n 2 "$stop_log")"; failures=$((failures + 1)); }
stop_expect 'a log with a done line, a shell runs' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 ]] || { echo "FAIL: a log with a done line gets a rule A line"; failures=$((failures + 1)); }

# event_registered <settings file> <event> <hook script>: an entry of the event runs the script
event_registered() {
  python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get(sys.argv[2], [])
sys.exit(0 if any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/" + sys.argv[3]) for e in entries for h in e.get("hooks", [])) else 1)
' "$1" "$2" "$3" 2>/dev/null
}
event_registered "$settings" Stop stop-guard.sh || { echo "FAIL: .claude/settings.json does not register stop-guard.sh for Stop"; failures=$((failures + 1)); }
event_registered "$tmp/old-settings.json" Stop stop-guard.sh && { echo "FAIL: the Stop registration check passed a settings file with no stop-guard.sh"; failures=$((failures + 1)); }

# The eighth and ninth hooks keep the run state through a compaction. pre-compact.sh prints what the
# summary must keep (Claude Code adds the stdout of PreCompact to the compaction instructions). It
# names the open run of cwd, the branch, the worktree, the first unticked slice, and the running
# background tasks, in 120 words or fewer, and copies no message of the user. post-compact.sh appends
# one line to dirigible-compactions.log in the git common dir.
pre_hook="$(dirname "$0")/pre-compact.sh"
post_hook="$(dirname "$0")/post-compact.sh"
# pc_in <hook event> <cwd> [<summary>]: the hook input for the lead transcript in hb_dir
pc_in() {
  printf '{"hook_event_name":"%s","trigger":"auto","cwd":"%s","transcript_path":"%s/s.jsonl","compact_summary":"%s"}' "$1" "$2" "$hb_dir" "${3-}"
}
# pc_run <cwd>: run PreCompact; the output is in pc_out, the exit status must be 0
pc_run() {
  pc_out="$(pc_in PreCompact "$1" | "$pre_hook" 2>"$tmp/hb-err")"
  [[ $? -eq 0 && ! -s "$tmp/hb-err" ]] || { echo "FAIL: pre-compact.sh at $1: exit not 0 or stderr: $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
}
# pc_has <case> <text>: pc_out holds the text
pc_has() { [[ "$pc_out" == *"$2"* ]] || { echo "FAIL: pre-compact.sh $1: no '$2' in: $pc_out"; failures=$((failures + 1)); }; }
pc_lacks() { [[ "$pc_out" != *"$2"* ]] || { echo "FAIL: pre-compact.sh $1: '$2' in: $pc_out"; failures=$((failures + 1)); }; }
# pc_run_md <name> <status> <branch> <row time>: a run folder of the fixture with two slices, one ticked
pc_run_md() {
  mkdir -p "$stop_fx/.scratchpads/runs/$1"
  printf '# Run %s\n\n- Status: %s\n- Branch: %s\n\n## Phases\n\n- [x] 0 Open\n- [ ] 4 Implement\n\n## Slices\n\n- [x] S1 first slice\n- [ ] S2 the next slice of %s\n' "$1" "$2" "$3" "$1" > "$stop_fx/.scratchpads/runs/$1/run.md"
  printf '%s\t0\tx\n' "$4" > "$stop_fx/.scratchpads/runs/$1/decisions.tsv"
}

# A run worktree: the open run whose last Branch line names the branch of cwd.
stop_fixture pc-branch
git -C "$stop_fx" worktree add -q --orphan -b chore/x "$stop_fx-wt"
pc_main="$(cd -P "$stop_fx" && pwd)"
pc_wt="$(cd -P "$stop_fx-wt" && pwd)"
pc_run_md chore-x open chore/x 2026-10-28T10:00
pc_run_md other open chore/other 2026-10-28T12:00
lead_session pc-tasks < <(hb_bg_start)
pc_run "$pc_wt"
pc_has 'run worktree' "$pc_main/.scratchpads/runs/chore-x"
pc_has 'run worktree' 'Branch: chore/x'
pc_has 'run worktree' "Worktree: $pc_wt"
pc_has 'run worktree' 'S2 the next slice of chore-x'
pc_has 'run worktree' 'b1 (shell)'
pc_lacks 'run worktree' "runs/other"

# The main checkout: the open run whose folder holds cwd, else the open run with the newest row.
stop_fixture pc-main
pc_run_md older open chore/older 2026-10-28T09:00
pc_run_md newer open chore/newer 2026-10-28T12:00
pc_main="$(cd -P "$stop_fx" && pwd)"
pc_run "$pc_main/.scratchpads/runs/older"
pc_has 'cwd inside the older run' "$pc_main/.scratchpads/runs/older"
pc_lacks 'cwd inside the older run' "runs/newer"
pc_lacks 'cwd inside the older run' 'newest row'
pc_run "$pc_main"
pc_has 'cwd at the checkout top' "$pc_main/.scratchpads/runs/newer"
pc_has 'cwd at the checkout top' 'newest row'
pc_lacks 'cwd at the checkout top' "runs/older"

# No open run: the keep list alone, and exit 0.
stop_fixture pc-done
pc_run_md old done chore/old 2026-10-28T09:00
pc_run "$stop_fx"
pc_has 'a done run' 'Keep in the summary'
pc_lacks 'a done run' 'runs/old'
pc_lacks 'a done run' 'Run folder'
pc_run "$tmp"
pc_has 'cwd outside a git checkout' 'Keep in the summary'
pc_lacks 'cwd outside a git checkout' 'Run folder'
pc_out="$(printf 'not json' | "$pre_hook" 2>&1)"
[[ $? -eq 0 ]] && pc_has 'input that is not JSON' 'Keep in the summary' || { echo "FAIL: pre-compact.sh exits non-zero on input that is not JSON"; failures=$((failures + 1)); }

# The output has 120 words or fewer, and holds no text of a user message.
stop_fixture pc-cap
pc_run_md cap open chore/cap 2026-10-28T10:00
lead_session pc-cap-tasks < <(
  for n in $(seq 30); do hb_text user $((200 - n)) "SECRET-USER-TEXT-$n do not copy this instruction"; done
  for n in $(seq 12); do
    hb_use 12 "t$n" Bash '{"command":"x","run_in_background":true}'
    hb_result 12 "t$n" "Command running in background with ID: task$n. Output is being written to: /x"
  done
)
pc_run "$stop_fx"
pc_words="$(printf '%s' "$pc_out" | wc -w | tr -d ' ')"
(( pc_words <= 120 )) || { echo "FAIL: pre-compact.sh prints $pc_words words, over the 120 of the cap: $pc_out"; failures=$((failures + 1)); }
pc_has '12 background tasks' 'task1 (shell)'
pc_lacks 'user messages' 'SECRET-USER-TEXT'

# post-compact.sh: one line for each compaction, run-folder yes or no.
stop_fixture pc-post
pc_log="$stop_fx/.git/dirigible-compactions.log"
lead_session pc-post-session < <(hb_text user 3 x)
pc_in PostCompact "$stop_fx" 'The run is in .scratchpads/runs/2026-10-28-x. Next: S2.' | "$post_hook" 2>"$tmp/hb-err"
pc_in PostCompact "$stop_fx" 'A summary with no run folder.' | "$post_hook" 2>>"$tmp/hb-err"
printf '{"hook_event_name":"PostCompact","cwd":"%s","agent_id":"a7","compact_summary":"x .scratchpads/runs/y"}' "$stop_fx" | "$post_hook" 2>>"$tmp/hb-err"
[[ ! -s "$tmp/hb-err" && "$(wc -l < "$pc_log" 2>/dev/null | tr -d ' ')" == 3 ]] ||
  { echo "FAIL: post-compact.sh writes one line for each of 3 compactions: $(cat "$pc_log" 2>&1) $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
pc_lines="$(sed -E 's/^[0-9T:Z-]+ //' "$pc_log" 2>/dev/null)"
[[ "$pc_lines" == $'lead run-folder: yes\nlead run-folder: no\na7 run-folder: yes' ]] ||
  { echo "FAIL: post-compact.sh lines have the agent and the answer: $pc_lines"; failures=$((failures + 1)); }
[[ "$(head -n 1 "$pc_log" 2>/dev/null)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]] ||
  { echo "FAIL: post-compact.sh line does not start with a UTC time: $(head -n 1 "$pc_log" 2>&1)"; failures=$((failures + 1)); }
printf 'not json' | "$post_hook" 2>"$tmp/hb-err"
[[ $? -eq 0 && ! -s "$tmp/hb-err" && "$(wc -l < "$pc_log" | tr -d ' ')" == 3 ]] ||
  { echo "FAIL: post-compact.sh on input that is not JSON adds a line or fails"; failures=$((failures + 1)); }
pc_in PostCompact "$tmp" 'x' | "$post_hook" 2>"$tmp/hb-err"
[[ $? -eq 0 && ! -s "$tmp/hb-err" ]] || { echo "FAIL: post-compact.sh outside a git checkout fails"; failures=$((failures + 1)); }

event_registered "$settings" PreCompact pre-compact.sh || { echo "FAIL: .claude/settings.json does not register pre-compact.sh for PreCompact"; failures=$((failures + 1)); }
event_registered "$settings" PostCompact post-compact.sh || { echo "FAIL: .claude/settings.json does not register post-compact.sh for PostCompact"; failures=$((failures + 1)); }
event_registered "$tmp/old-settings.json" PreCompact pre-compact.sh && { echo "FAIL: the PreCompact registration check passed a settings file with no pre-compact.sh"; failures=$((failures + 1)); }

# Unreadable input fails closed.
printf 'not json' | "$hook" 2>/dev/null
[[ $? -eq 2 ]] || { echo "FAIL: unreadable input was allowed"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "git-guardrails: all cases pass" || exit 1
