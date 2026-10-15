#!/bin/bash
# PreToolUse hook for Bash: block git commands that discard work, skip checks, or bypass
# the pull request flow. Permission rules in settings.json match only command prefixes;
# this hook matches the flag anywhere in the whole command text, quoted text too. A quoted
# rule is still a rule, so the message tells the agent how to write text that is only data.
# Exit 2 blocks the command and shows the message to the agent.

# block <reason> [<way>]: with no way, the message names the deliver flow.
block() {
  echo "BLOCKED by .claude/hooks/git-guardrails.sh: '$COMMAND' $1. ${2:-This command can discard work or bypass the checks. Use the deliver flow: push the run branch and merge through a pull request.}" >&2
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
UNSPLIT="$NORMALIZED"
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
  'git worktree remove .*(--force|-f( |$))'
  '--no-verify'
  'git commit( .*)? -n( |$)'
  'gh pr merge .*--admin'
)

# The only allowed change to the hooks path is the one `make setup` makes. A read with no value
# (`git [-C <dir>] config [get] [--local] [--get] core.hooksPath`, flags in any order) is allowed
# too, only as a whole command: `xargs git config core.hooksPath` is a write. The key matches in
# any case. Each command of a chain or a substitution is one line; a line that is not one of the
# two forms and names the key is a change. A direct write of .git/config is not checked.
hooks_rest="$(sed -E 's/[Cc][Oo][Rr][Ee]\.[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]/core.hookspath/g' <<< "$joined" |
  tr -s '\t ' '  ' | awk '{ gsub(/&&|\|\||[;&|()`]/, "\n"); print }' |
  grep -vE '^ *git( +-C +[^ ]+)* +config( +get)?( +--(local|get))* +core\.hookspath *$' |
  grep -vE '^ *git( +-C +[^ ]+)* +config( +--local)? +core\.hookspath +\.githooks *$')"
if grep -q 'core\.hookspath' <<< "$hooks_rest"; then
  block "changes core.hooksPath"
fi

# The joined text with one space for each run of tabs and spaces, the git global options removed,
# and the new lines kept, so `git -C <path>  commit` reads as `git commit` in the two chain rules.
chained="$(tr -s '\t ' '  ' <<< "$joined" | sed -E "s/git( +-[Cc] +('[^']*'|\"[^\"]*\"|[^ ]+))+/git/g")"

# Put $1 without && and the redirects (2>&1, &>, >&), which are not background jobs, in $stripped.
# A variable, not $(...): a command substitution drops a new line at the end.
drop_safe_joins() {
  stripped="${1//&&/}"
  stripped="${stripped//[0-9]>&[0-9]/}"
  stripped="${stripped//&>/}"
  stripped="${stripped//>&/}"
}

# A commit in the same command as a make check must run only when the check passed, so only
# && may join them. After `;`, `||`, a pipe, a background `&`, or a new line, a red check still commits.
if [[ "$chained" =~ make\ check(.*)git\ commit ]]; then
  drop_safe_joins "${BASH_REMATCH[1]}"
  if [[ "$stripped" =~ [\;\|\&]|$'\n' ]]; then
    block "runs git commit after make check without && (a red check still commits)"
  fi
fi

# A decisions.tsv row after a commit or a build must come after its status is read. After `;`, a
# new line, a pipe (no pipefail), or a background `&`, the row is written before that. && and ||
# pass the status, and a redirect (2>&1, &>, >&) is not a background job.
# [[:space:]] and not $: in [[ =~ ]], $ is the end of the text, not the end of a line.
# The rule matches git commit, make, or swift only at a command start: the text start, or after
# `;`, `|`, `&`, `(`, or a new line, then the prefix words `{`, `!`, if, then, do, else, while,
# NAME=value, time, env, bash, with-lock.sh, and probe.sh <folder>, in any order. So the word make
# in row text is data. Limits: in quoted data, git commit, make, or swift after `;`, `|`, `&`, `(`,
# or a new line still blocks: write the row file with the Write tool and log it with
# log-decision.sh --from <file>. A command after another wrapper word (nice, nohup, caffeinate,
# xcrun) or after a quote character is not blocked.
word="('[^']*'|\"[^\"]*\"|[^[:space:]]+)"
start="(^|[;|&(]|"$'\n'") ?(\{ |! |if |then |do |else |while |[A-Za-z_][A-Za-z0-9_]*=$word |time |env |bash |[^[:space:]]*with-lock\.sh |[^[:space:]]*probe\.sh $word )*"
if [[ "$chained" =~ $start(git\ commit|make|swift)([[:space:]]|$)(.*)log-decision\.sh ]]; then
  middle="${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
  drop_safe_joins "${middle//||/}"
  if [[ "$stripped" =~ [\;\|\&]|$'\n' ]]; then
    block "logs a decisions.tsv row after git commit, make, or swift joined by ;, a new line, a pipe, or & (the row can come before the status). Run log-decision.sh in its own command after you read the status"
  fi
fi

# Only the check-changed recipe of the Makefile writes the pass stamp that land.sh reuses, so a
# direct write cannot skip the land check. A command that names the stamp file is blocked too.
if grep -qE 'dirigible-check-stamp|check-stamp\.sh write' <<< "$NORMALIZED"; then
  block "names the pass stamp or writes it (only make check-changed writes it; read it with scripts/check-stamp.sh read origin/main)"
fi
# Only a passing make test-slow or test-slow-push writes the slow-run date that
# scripts/check-changed.sh reads, so a direct write cannot skip the daily slow run. A command that
# names the date file is blocked too.
if grep -qE 'dirigible-slow-date' <<< "$NORMALIZED"; then
  block "names the slow-run date file (only a passing make test-slow or make test-slow-push writes it)"
fi
# reads_only <name>: each simple command that names the file <name> is a read. A \| (an
# alternation in a grep pattern) does not split the command. Its first word is cat, grep, head,
# tail, wc, ls, stat, test, [, rg, awk, sort (no -o), sed (with -n and no -i), or git grep; and
# no redirect path runs up to the name (quotes and a $(...) part are part of the path, and the
# path stops at `*` and `[`, so a grep whose quoted pattern holds `>` is a read). An allowlist,
# because a list of write forms missed sed -i, dd of=, and a variable. A path that starts with ../
# or / and has no .git in it is a folder of that name (a worktree), not the file.
reads_only() {
  local line token first second named redirect=">[>|]?[[:space:]]*[\"']?(\\\$\\([^)]*\\))?[^;&|[:space:]*[]*$1"
  while IFS= read -r line; do
    named=0
    while IFS= read -r token; do
      token="${token#[\"\']}"
      [[ -n "$token" && "$token" =~ ^(\.\./|/) && "$token" != *.git* ]] || named=1
    done < <(grep -oE "[^[:space:]]*$1([^A-Za-z0-9_.-]|\$)" <<< "$line")
    [[ $named -eq 1 ]] || continue
    read -r first second _ <<< "$line"
    case "$first" in
      cat | grep | head | tail | wc | ls | stat | test | '[' | rg | awk) ;;
      sort) grep -qE '(^|[[:space:]])-[a-zA-Z]*o' <<< "$line" && return 1 ;;
      sed) grep -qE '(^|[[:space:]])-[a-zA-Z]*i' <<< "$line" && return 1
        grep -qE '(^|[[:space:]])-[a-zA-Z]*n' <<< "$line" || return 1 ;;
      git) [[ "$second" == grep ]] || return 1 ;;
      *) return 1 ;;
    esac
    grep -qE "$redirect" <<< "$line" && return 1
  done < <(sed -E 's/\\\|/ /g' <<< "$UNSPLIT" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')
  return 0
}
# Only scripts/run-checks.sh appends to dirigible-flakes, and only scripts/land.sh removes its
# lines after it writes their flake rows, so a direct change cannot erase a flake row. A read is
# allowed.
if ! reads_only dirigible-flakes; then
  block "names the flakes file in a command that is not a read: cat, grep, head, tail, wc, ls, stat, or test, with no -i and no redirect into it (only scripts/run-checks.sh appends to it; scripts/land.sh writes a flake row for each line; read it with scripts/run-checks.sh --flakes)"
fi
# Only scripts/run-checks.sh appends to dirigible-check-partial, so a hand-written line cannot
# narrow a push check to a rerun of chosen tests. A read is allowed.
if ! reads_only dirigible-check-partial; then
  block "names the partial stamp file in a command that is not a read (only scripts/run-checks.sh appends to it after a check whose only red targets are tests; read it with cat or grep)"
fi
# Only scripts/run-checks.sh writes and removes the run marks that .githooks/pre-commit reads, so
# a direct write, move, or remove cannot clear a mark to commit during a check. A read is allowed.
if ! reads_only dirigible-check-running; then
  block "names the run marks of make check-changed in a command that is not a read (only scripts/run-checks.sh writes them; the pre-commit hook skips a stale mark; read them with ls or cat)"
fi
# Only scripts/with-lock.sh takes and removes the build lock, and only after its own take, so a
# hand-written mkdir and rmdir chain cannot remove the lock of another agent. A read is allowed.
if ! reads_only dirigible-build.lock; then
  block "names the build lock in a command that is not a read (run the build or test through scripts/with-lock.sh, which takes the lock and removes only a lock that it took; read the lock with ls or cat)"
fi
# Only scripts/test-hooks.sh appends to the hooks pass stamp, after a pass of the whole list, so a
# Bash command cannot write it to skip the hook tests. A read is allowed. This rule covers only the
# Bash tool, not the Edit and Write tools.
if ! reads_only dirigible-hooks-stamp; then
  block "names the hooks pass stamp in a command that is not a read (only scripts/test-hooks.sh appends to it after a pass; read it with cat or grep)"
fi
# Only with-lock.sh, bench.sh, bench-pairs.sh, and sanitize.sh set the lock reuse values: a value
# set by hand runs a build beside the holder of the lock.
if grep -qE 'DIRIGIBLE_(BUILD_LOCK|LOCKED_SCRIPT)=' <<< "$NORMALIZED"; then
  block "sets a lock reuse value by hand (DIRIGIBLE_BUILD_LOCK or DIRIGIBLE_LOCKED_SCRIPT); run the command through scripts/with-lock.sh and wait for the lock"
fi

# A new Finder window opens as a tab of the window group of the user, so a bounds, position, or
# size change of a Finder window moves the windows of the user. The rule reads the whole command
# with each new line as a space and in lower case, so a heredoc, a multi-line -e, and the three -e
# form match too. A clause starts at each tell app, tell application, tell process, or osascript
# word, and runs to the next one (not to an end tell, which can close a nested tell). It blocks a
# clause with (a) a set of bounds, position, or size in a tell of app "Finder" (or id
# "com.apple.finder", or process or application process "Finder" in System Events, quotes plain
# or escaped); or (b) a set of bounds, position, or size
# "of ... process "Finder"" with no quote in the gap. A set after the end tell of a Finder tell
# also blocks: the safe side. A text rule does not see a script file (osascript <file>), JXA, or
# a window name with quotes before 'of process "Finder"' in rule (b).
if grep -qi osascript <<< "$COMMAND" && tr '\n\t' '  ' <<< "$COMMAND" | tr -s ' ' | tr '[:upper:]' '[:lower:]' |
  awk '{ gsub(/osascript|tell (app|application|process) /, "\n&"); print }' | awk '
  /set (the )?(bounds|position|size) of [^"\047]*process \\?"finder/ { found = 1 }
  /^tell (app|application|(application )?process) (id )?\\?"(com\.apple\.)?finder\\?"/ && /set (the )?(bounds|position|size)([^a-z0-9_]|$)/ { found = 1 }
  END { exit !found }'; then
  block "changes the bounds, position, or size of a Finder window (a new Finder window opens as a tab of the window group of the user, so the change moves the windows of the user)" \
    "Read where the Finder window is through System Events (get position of window 1 of process \"Finder\"), and move only the window of the verify copy."
fi

# An Apple Event to an app other than System Events makes macOS show an Automation prompt for the
# terminal app: the call waits until it times out (-1712), and an agent that answers the prompt
# changes a privacy setting of the user. The rule reads the command as the Finder rule does, and
# blocks each app or application "<name>" (or id "<id>") that is not System Events, with a verb
# (tell, quit, activate, run) or as a reference (window 1 of application "Finder"). An
# application process "<name>" in System Events does not match. A text rule does not see a script
# file (osascript <file>), JXA, or an app name that is not a string. A data string with "app" and
# then a space and a quote (display dialog "Quit the app " & x) also blocks: the safe side; such a
# script goes in a file.
if grep -qi osascript <<< "$COMMAND" && tr '\n\t' '  ' <<< "$COMMAND" | tr -s ' ' | tr '[:upper:]' '[:lower:]' | awk '
  { s = $0
    while (match(s, /(^|[^a-z0-9_.-])(app|application) (id )?\\?"[^"\\]*/)) {
      name = substr(s, RSTART, RLENGTH)
      sub(/^[^"]*"/, "", name)
      if (name != "system events" && name != "com.apple.systemevents") found = 1
      s = substr(s, RSTART + RLENGTH)
    } }
  END { exit !found }'; then
  block "sends an Apple Event to an app other than System Events (macOS shows an Automation prompt for the terminal app, and the call waits until it times out)" \
    "Drive another app through System Events (tell process). An Automation prompt is the user's: leave it, and name it in the report."
fi

# A quit by name (killall, pkill -x) also quits the copy of the user, with its unsaved work
# (AGT-120). A bare pkill -f (the mutation stop of deliver Phase 7) stays allowed. A text rule does
# not see a quit in a script file.
if grep -qE '(^|[^[:alnum:]_.-])(killall( |$)|pkill( +-[^ ]+)* +-[a-zA-Z]*x)' <<< "$NORMALIZED"; then
  block "quits each process with a name (killall, pkill -x), so it also quits the copy of the user, with its unsaved work" \
    "Find the PID with pgrep, record the PID of the process that the probe started, and quit only that PID (kill <pid>)."
fi

# A message path other than .scratchpads/commit-msg.txt (absolute, relative, ~, or $HOME) can name
# the file of another work tree, so a commit takes the message of another agent. git -C changes
# the directory first, so the relative path is per tree.
while IFS= read -r file; do
  file="${file#[\'\"]}"
  file="${file%[\'\"]}"
  if [[ "$file" == *commit-msg.txt || "$file" == *.scratchpads/* ]] && [[ "$file" != .scratchpads/commit-msg.txt ]]; then
    block "reads a commit message file that can be the file of another work tree; write .scratchpads/commit-msg.txt in the work tree that commits and pass that relative path"
  fi
done < <(grep -oE "git commit( .*)? (-F ?|--file[= ])[^ ]+" <<< "$NORMALIZED" | sed -E 's/.*(-F ?|--file[= ])//')

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if grep -qE -- "$pattern" <<< "$NORMALIZED"; then
    block "matches '$pattern'"
  fi
done

# A release tag comes only from scripts/tag-release.sh, which checks the version order against the
# tags of origin and removes its own stale local tag. A git tag command at a command start with an
# argument blocks, unless it lists the tags (-l, --list, --points-at, --contains, --merged) and
# makes, deletes, or moves none. A push of --tags, refs/tags/, or a v<digit> name blocks.
tag_way="Tag a release with scripts/tag-release.sh <version> <commit> <message>: only the tags of origin decide a refusal, and the script removes its own stale local tag."
while IFS= read -r line; do
  if [[ "$line" =~ (^|[ \(])git\ tag(\ |$)(.*) ]]; then
    rest="${BASH_REMATCH[3]}"
    if [[ -n "${rest// /}" ]] && ! { grep -qE '(^| )(-l|--list|--points-at|--contains|--no-contains|--merged|--no-merged)( |=|$)' <<< "$rest" &&
      ! grep -qE '(^| )(-[a-zA-Z]*[adsfmF][a-zA-Z]*|--delete|--annotate|--sign|--force|--message|--file)( |=|$)' <<< "$rest"; }; then
      block "makes, deletes, or moves a tag by hand" "$tag_way"
    fi
  fi
  if grep -qE "(^|[ (])git push( .*)? (--tags|[^ ]*refs/tags/|[\"']?v[0-9])" <<< "$line"; then
    block "pushes a tag by hand" "$tag_way"
  fi
done <<< "$NORMALIZED"

exit 0
