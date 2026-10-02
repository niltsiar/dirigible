#!/bin/bash
# PreToolUse hook for Bash: block git commands that discard work, skip checks, or bypass
# the pull request flow. Permission rules in settings.json match only command prefixes;
# this hook matches the flag anywhere in the whole command text, quoted text too. A quoted
# rule is still a rule, so the message tells the agent how to write text that is only data.
# Exit 2 blocks the command and shows the message to the agent.

block() {
  echo "BLOCKED by .claude/hooks/git-guardrails.sh: '$COMMAND' $1. This command can discard work or bypass the checks. Use the deliver flow: push the run branch and merge through a pull request." >&2
  echo "If the matched text is only data, write it with the Write tool, a decisions.tsv row with log-decision.sh --from <file>, or a commit message with git commit -F <file>." >&2
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

# Join backslash-newline continuations, as the shell does. Make each run of tabs and spaces
# one space, so the patterns match `git<TAB>push` and `git  push` too.
joined="${COMMAND//\\$'\n'/ }"
NORMALIZED="$(tr -s '\t ' '  ' <<< "$joined")"
# Drop git global options (-C <path>, -c <key=value>) so `git -C repo reset` reads as `git reset`.
NORMALIZED="$(sed -E 's/git( +-[Cc] +[^ ]+)+/git/g' <<< "$NORMALIZED")"
# Put each command of a chain (&&, ||, ;, |) on its own line. grep matches one line at a time,
# so a pattern cannot match a word of the next command, for example `--base main` of gh.
NORMALIZED="$(awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' <<< "$NORMALIZED")"

DANGEROUS_PATTERNS=(
  'git push( .*)? (--force|-[a-zA-Z]*f|\+)'
  "git push .*[ :/'\"]main([^[:alnum:]_./-]|\$)"
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
if [[ "$joined" =~ make\ check(.*)git\ commit ]] && [[ "${BASH_REMATCH[1]}" =~ [\;\|]|$'\n' ]]; then
  block "runs git commit after make check without && (a red check still commits)"
fi

# Only the check-changed recipe of the Makefile writes the pass stamp that land.sh reuses, so a
# direct write cannot skip the land check. A command that names the stamp file is blocked too.
if grep -qE 'dirigible-check-stamp|check-stamp\.sh write' <<< "$NORMALIZED"; then
  block "names the pass stamp or writes it (only make check-changed writes it; read it with scripts/check-stamp.sh read origin/main)"
fi
# Only a passing make test-slow writes the slow-run date that scripts/check-changed.sh reads, so a
# direct write cannot skip the daily slow run. A command that names the date file is blocked too.
if grep -qE 'dirigible-slow-date' <<< "$NORMALIZED"; then
  block "names the slow-run date file (only a passing make test-slow writes it)"
fi

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if grep -qE -- "$pattern" <<< "$NORMALIZED"; then
    block "matches '$pattern'"
  fi
done

exit 0
