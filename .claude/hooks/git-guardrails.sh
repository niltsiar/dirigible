#!/bin/bash
# PreToolUse hook for Bash: block git commands that discard work, skip checks, or bypass
# the pull request flow. Permission rules in settings.json match only command prefixes;
# this hook matches the flag anywhere in the command.
# Exit 2 blocks the command and shows the message to the agent.

block() {
  echo "BLOCKED by .claude/hooks/git-guardrails.sh: '$COMMAND' $1. This command can discard work or bypass the checks. Use the deliver flow: push the run branch and merge through a pull request." >&2
  exit 2
}

# plutil reads JSON and ships with every macOS; jq does not ship with macOS 14.
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat > "$input"
if ! COMMAND="$(plutil -extract tool_input.command raw -o - "$input" 2>/dev/null)"; then
  COMMAND="(unreadable hook input)"
  block "cannot be checked"
fi

# Drop git global options (-C <path>, -c <key=value>) so `git -C repo reset` reads as `git reset`.
NORMALIZED="$(sed -E 's/git( +-[Cc] +[^ ]+)+/git/g' <<< "$COMMAND")"
# Put each command of a chain (&&, ||, ;, |) on its own line. grep matches one line at a time,
# so a pattern cannot match a word of the next command, for example `--base main` of gh.
NORMALIZED="$(awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' <<< "$NORMALIZED")"

DANGEROUS_PATTERNS=(
  'git push( .*)? (--force|-[a-zA-Z]*f|\+)'
  'git push .*[ :/]main( |$)'
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

# The only allowed change to the hooks path is the one `make setup` makes.
if grep -qE 'core\.hooksPath' <<< "$COMMAND" \
  && ! grep -qE -- '--get' <<< "$COMMAND" \
  && ! grep -qE 'core\.hooksPath \.githooks( |;|&|$)' <<< "$COMMAND"; then
  block "changes core.hooksPath"
fi

# A commit in the same command as a make check must run only when the check passed, so only
# && may join them. After `;`, `||`, a pipe, or a new line, a red check still commits.
joined="${COMMAND//\\$'\n'/ }"
if [[ "$joined" =~ make\ check(.*)git\ commit ]] && [[ "${BASH_REMATCH[1]}" =~ [\;\|]|$'\n' ]]; then
  block "runs git commit after make check without && (a red check still commits)"
fi

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if grep -qE -- "$pattern" <<< "$NORMALIZED"; then
    block "matches '$pattern'"
  fi
done

exit 0
