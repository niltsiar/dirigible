#!/bin/bash
# PreToolUse hook for the Write tool: refuse a Write over an existing run.md, plan.md, or
# analysis.md under .scratchpads/runs/. AGENTS.md (Run ledger) says to change an existing
# .scratchpads/ file with the Edit tool, and git-guardrails.sh guards the same three names against
# a Bash write. A new file and each other file (the pr.md of the light-path lead, a --from file)
# pass. Exit 2 blocks the call and shows the message to the agent.

# plutil reads JSON and ships with every macOS; jq does not ship with macOS 14.
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat > "$input"
path="$(plutil -extract tool_input.file_path raw -o - "$input" 2>/dev/null)" || exit 0
case "$path" in
  */.scratchpads/runs/*/run.md | */.scratchpads/runs/*/plan.md | */.scratchpads/runs/*/analysis.md) ;;
  *) exit 0 ;;
esac
[[ -e "$path" ]] || exit 0
echo "BLOCKED by .claude/hooks/write-guard.sh: $path exists, and a Write replaces all of it. Read it, then change it with the Edit tool (AGENTS.md, Run ledger)." >&2
exit 2
