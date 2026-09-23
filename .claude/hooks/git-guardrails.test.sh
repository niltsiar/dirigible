#!/bin/bash
# Check that git-guardrails.sh blocks and allows the right commands. Run by `make check`.
set -uo pipefail
hook="$(dirname "$0")/git-guardrails.sh"
failures=0

# Build the hook input with plutil, the same tool the hook reads it with (no jq on macOS 14).
input="$(mktemp)"
trap 'rm -f "$input"' EXIT

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

# Unreadable input fails closed.
printf 'not json' | "$hook" 2>/dev/null
[[ $? -eq 2 ]] || { echo "FAIL: unreadable input was allowed"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "git-guardrails: all cases pass" || exit 1
