#!/bin/bash
# PreToolUse hook for Bash: block git commands that discard work, skip checks, or bypass
# the pull request flow. Permission rules in settings.json match only command prefixes;
# this hook matches the flag anywhere in the command.
# Exit 2 blocks the command and shows the message to the agent.

COMMAND="$(jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "$COMMAND" ]] && exit 0

DANGEROUS_PATTERNS=(
  'git push .*(--force|-f( |$)|--force-with-lease| \+)'
  'git push( .*)? (origin )?(HEAD:)?main( |$)'
  'git reset --hard'
  'git clean -[a-z]*f'
  'git branch .*(-D|--delete --force|-d -f|-d --force|-f )'
  'git (checkout|restore) (-- )?\.( |$)'
  'git switch .*(--discard-changes|-f( |$)|--force)'
  'git stash (drop|clear)'
  '--no-verify'
  'git commit( .*)? -n( |$)'
  'gh pr merge .*--admin'
)

block() {
  echo "BLOCKED by .claude/hooks/git-guardrails.sh: '$COMMAND' $1. This command can discard work or bypass the checks. Use the deliver flow: push the run branch and merge through a pull request." >&2
  exit 2
}

# The only allowed change to the hooks path is the one `make setup` makes.
if grep -qE 'core\.hooksPath' <<< "$COMMAND" && ! grep -qE -- '--get' <<< "$COMMAND" && ! grep -qE 'core\.hooksPath \.githooks( |;|&|$)' <<< "$COMMAND"; then
  block "changes core.hooksPath"
fi

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if grep -qE -- "$pattern" <<< "$COMMAND"; then
    block "matches '$pattern'"
  fi
done

exit 0
