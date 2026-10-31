#!/bin/bash
# PreToolUse hook for the tools that brief an agent: Agent (field prompt), SendMessage (field
# message), and mcp__t3-code__delegate_task (field task). Exit 2 blocks the call and shows the
# message to the agent.
# - An Agent call with isolation "worktree" is refused. Such a worktree does not fit the file and
#   git layout of a deliver run, and its creation set the absolute hooks path of the main checkout
#   in the shared git config, so each commit in each worktree was refused until `make setup` ran
#   again. The isolation field of delegate_task is a T3 worktree, so it passes.
# - A brief whose text holds a git commit -F or --file path other than .scratchpads/commit-msg.txt
#   or - (stdin) is refused: the agent would commit with the message file of another work tree
#   (git-guardrails.sh blocks that path in a Bash command), also a file of the run folder or a
#   placeholder (-F <file>). The match is that of git-guardrails.sh (commit-files.awk, which has the
#   rules): the message-file option after each git commit of a line (-F in a short-option cluster
#   that ends in F, such as -aF, or --fil or --file with = or a space), so a later -F of another
#   command does not count, and text inside a quoted string is data; git -C <dir> and -c <key=value>
#   go first. A commit with more than one such option is refused, because git reads the last one,
#   and so is -F - with a < file or a pipe on its left. Then backticks, < and > go. An empty value
#   or a lone quote (`git commit -F` in backticks) passes. The leading quotes and the trailing
#   ) ; : . , and quotes go before the comparison, so -F "" is refused.

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
commit_files() {
  awk -v brief=1 -f "$(dirname "$0")/commit-files.awk"
}
# Drop git -C <dir> and -c <key=value> as git-guardrails.sh does, so git -C wt commit reads as git commit.
text="$(sed -E 's/git( +-[Cc] +[^ ]+)+/git/g' <<< "$text")"
while IFS= read -r file; do
  if [[ "$file" == $'\001' ]]; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: the brief tells the agent to commit with more than one message file option, and git reads the last one. Tell it to write .scratchpads/commit-msg.txt in its work tree and run git commit -F .scratchpads/commit-msg.txt." >&2
    exit 2
  fi
  if [[ "$file" == $'\002' ]]; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: the brief tells the agent to commit with git commit -F - and a < file or a pipe on stdin, and the file can belong to another work tree. Tell it to write .scratchpads/commit-msg.txt in its work tree and run git commit -F .scratchpads/commit-msg.txt, or to pass the text in a heredoc." >&2
    exit 2
  fi
  file="$(sed -E "s/[\`<>]//g" <<< "$file")"
  [[ -z "$file" || "$file" == "'" || "$file" == '"' ]] && continue
  file="$(sed -E "s/^[\"']+//; s/[);:.,\"']+\$//" <<< "$file")"
  if [[ "$file" != .scratchpads/commit-msg.txt && "$file" != - ]]; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: the brief tells the agent to commit with git commit -F $file, which can be the message file of another work tree. Tell it to write .scratchpads/commit-msg.txt in its work tree and run git commit -F .scratchpads/commit-msg.txt (or git commit -F - with a heredoc). If the path is only quoted data, put the text in a file in the run folder and name that file in the brief." >&2
    exit 2
  fi
done < <(commit_files <<< "$text")
exit 0
