#!/bin/bash
# PreToolUse hook for the Agent tool: refuse a call with isolation "worktree". Such a worktree does
# not fit the file and git layout of a deliver run, and its creation set the absolute hooks path of
# the main checkout in the shared git config, so each commit in each worktree was refused until
# `make setup` ran again. Exit 2 blocks the call and shows the message to the agent.

# plutil reads JSON and ships with every macOS; jq does not ship with macOS 14.
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat > "$input"
isolation="$(plutil -extract tool_input.isolation raw -o - "$input" 2>/dev/null)"
if [[ "$isolation" == worktree ]]; then
  echo "BLOCKED by .claude/hooks/agent-guard.sh: an Agent call with isolation \"worktree\". Make the worktree yourself with git worktree add -b <branch> ../<folder> <base>, give the agent that folder in its brief, and call the agent with no isolation." >&2
  exit 2
fi
exit 0
