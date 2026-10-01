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
expect block 'make check && git push origin main'
expect block 'git status; git reset --hard'
expect block 'env X=1 git push -f origin feat/x'
expect block 'bash -c "git push -f origin feat/x"'
expect block 'git commit -n -m x | cat'

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

# A quoted main is the same push to main.
expect block "git push origin 'main'"
expect block 'git push origin "main"'
expect block "git push origin HEAD:'refs/heads/main'"
expect block 'git push origin "feat/x:main"'
expect allow "git push -u origin 'feat/main-feature'"
expect allow 'git push -u origin "main-feature"'

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

# Unreadable input fails closed.
printf 'not json' | "$hook" 2>/dev/null
[[ $? -eq 2 ]] || { echo "FAIL: unreadable input was allowed"; failures=$((failures + 1)); }

[[ $failures -eq 0 ]] && echo "git-guardrails: all cases pass" || exit 1
