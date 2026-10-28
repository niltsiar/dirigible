#!/bin/bash
# PreToolUse hook for the tools that brief an agent: Agent (field prompt), SendMessage (field
# message), and mcp__t3-code__delegate_task (field task). Exit 2 blocks the call and shows the
# message to the agent.
# - An Agent call with isolation "worktree" is refused. Such a worktree does not fit the file and
#   git layout of a deliver run, and its creation set the absolute hooks path of the main checkout
#   in the shared git config, so each commit in each worktree was refused until `make setup` ran
#   again. The isolation field of delegate_task is a T3 worktree, so it passes.
# - A brief whose text holds a git commit -F or --file path other than .scratchpads/commit-msg.txt
#   that names a commit-msg.txt or a .scratchpads/ file is refused: the agent would commit with the
#   message file of another work tree (git-guardrails.sh blocks that path in a Bash command). The
#   match and the word are those of git-guardrails.sh, line by line; then backticks, < and > go,
#   and the leading quotes and the trailing ) ; : . , and quotes. A placeholder (-F <file>) or
#   another file name passes. A git -C <dir> commit -F form stays out, as in git-guardrails.sh.

# plutil reads JSON and ships with every macOS; jq does not ship with macOS 14.
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat > "$input"
tool="$(plutil -extract tool_name raw -o - "$input" 2>/dev/null)"
case "$tool" in
  SendMessage) field=message ;;
  mcp__t3-code__delegate_task) field=task ;;
  *) field=prompt ;;
esac
isolation="$(plutil -extract tool_input.isolation raw -o - "$input" 2>/dev/null)"
if [[ "$tool" != mcp__t3-code__delegate_task && "$isolation" == worktree ]]; then
  echo "BLOCKED by .claude/hooks/agent-guard.sh: an Agent call with isolation \"worktree\". Make the worktree yourself with git worktree add -b <branch> ../<folder> <base>, give the agent that folder in its brief, and call the agent with no isolation." >&2
  exit 2
fi
text="$(plutil -extract "tool_input.$field" raw -o - "$input" 2>/dev/null)"
while IFS= read -r file; do
  file="$(sed -E "s/[\`<>]//g; s/^[\"']+//; s/[);:.,\"']+\$//" <<< "$file")"
  [[ -n "$file" ]] || continue
  if [[ "$file" == *commit-msg.txt || "$file" == *.scratchpads/* ]] && [[ "$file" != .scratchpads/commit-msg.txt ]]; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: the brief tells the agent to commit with git commit -F $file, which can be the message file of another work tree. Tell it to write .scratchpads/commit-msg.txt in its work tree and run git commit -F .scratchpads/commit-msg.txt. If the path is only quoted data, put the text in a file in the run folder and name that file in the brief." >&2
    exit 2
  fi
done < <(grep -oE "git commit( .*)? (-F ?|--file[= ])[^ ]+" <<< "$text" | sed -E 's/.*(-F ?|--file[= ])//')
exit 0
