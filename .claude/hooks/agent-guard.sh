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
#   placeholder (-F <file>). The match is that of git-guardrails.sh: the message-file option after
#   each git commit of a line (-F in a short-option cluster that ends in F, such as -aF, or --fil or
#   --file with = or a space), so a later -F of another command does not count; git -C <dir> and
#   -c <key=value> go first. A commit with more than one such option is refused, because git reads
#   the last one. Then backticks, < and > go. An empty value or a lone quote (the end of a quoted
#   text, or `git commit -F` in backticks) passes. The leading quotes and the trailing ) ; : . , and
#   quotes go before the comparison, so -F "" is refused.

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
# commit_files: the value of the message-file option after each "git commit" of the input lines, up
# to the first ; & | , or sentence end outside quotes; one \001 line for a commit with more than one
# such option (git-guardrails.sh has the same function). A quote after a space opens the value.
commit_files() {
  awk '{
    s = $0
    while ((i = index(s, "git commit")) > 0) {
      s = substr(s, i + 10)
      chunk = s
      if ((j = index(s, "git commit")) > 0) chunk = substr(s, 1, j - 1)
      q = ""
      for (k = 1; k <= length(chunk); k++) {
        c = substr(chunk, k, 1)
        if (q != "") { if (c == q) q = "" }
        else if (c == "\"" || c == "\047") q = c
        else if (c ~ /[;&|,]/ || (c == "." && substr(chunk, k + 1, 1) == " ")) { chunk = substr(chunk, 1, k - 1); break }
      }
      n = 0; rest = chunk
      while (match(rest, /(^| )(-[a-zA-EG-Z]*F ?|--fil(e)?[= ])[^ ]+/)) {
        t = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        v = t
        sub(/^ ?(-[a-zA-EG-Z]*F ?|--fil(e)?[= ])/, "", v)
        if ((v == "\"" || v == "\047") && substr(t, length(t) - 1, 1) == " " && (e = index(rest, v)) > 0) {
          v = v substr(rest, 1, e)
          rest = substr(rest, e + 1)
        }
        if (++n == 1) first = v
      }
      if (n > 1) print "\001"
      else if (n == 1) print first
    }
  }'
}
# Drop git -C <dir> and -c <key=value> as git-guardrails.sh does, so git -C wt commit reads as git commit.
text="$(sed -E 's/git( +-[Cc] +[^ ]+)+/git/g' <<< "$text")"
while IFS= read -r file; do
  if [[ "$file" == $'\001' ]]; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: the brief tells the agent to commit with more than one message file option, and git reads the last one. Tell it to write .scratchpads/commit-msg.txt in its work tree and run git commit -F .scratchpads/commit-msg.txt." >&2
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
