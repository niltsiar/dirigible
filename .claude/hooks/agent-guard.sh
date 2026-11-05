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
# - A brief that names a lock step is refused while a release call (a push check, the hooks pass, a
#   land, or make dmg) or a stress lane (scripts/test-stress.sh) holds the build lock or waits first
#   for it, because the agent would wait for
#   the lock on its 90 min clock. A lock step is with-lock.sh, a make target that takes the lock, a
#   script that takes the lock itself, or swift build, test, or run (AGENTS.md, Commands). The
#   state comes from scripts/with-lock.sh --release-holder, and an exit other than 0 or 1 of that
#   query lets the brief pass. A line that starts with Build lock: none (after spaces and one -, *,
#   or > marker) passes a brief of an agent that runs no with-lock.sh step.
# - A delegate_task whose target providerInstanceId or model equals the name of a line of
#   dirigible-provider-limits in the git common dir is refused while now is before the reset of that
#   line. A line is <name><TAB><reset UTC, YYYY-MM-DDTHH:MM>, and scripts/provider-limit.sh writes
#   it. The reset is the start of that minute. PROVIDER_LIMIT_NOW (epoch seconds) sets now. A line
#   that is not in that form, and a missing file, let the call pass; the hook prints a note for the
#   line.

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
if [[ "$tool" == mcp__t3-code__delegate_task ]] \
  && common="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  && limits="$common/dirigible-provider-limits" && [[ -f "$limits" ]]; then
  provider="$(plutil -extract tool_input.target.providerInstanceId raw -o - "$input" 2>/dev/null)"
  model="$(plutil -extract tool_input.target.model raw -o - "$input" 2>/dev/null)"
  now="${PROVIDER_LIMIT_NOW:-$(date +%s)}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    name="${line%%$'\t'*}"
    [[ -n "$name" && ( "$name" == "$provider" || "$name" == "$model" ) ]] || continue
    reset="${line#*$'\t'}"
    if [[ "$line" == *$'\t'* && "$reset" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$ ]] \
      && reset_at="$(date -j -u -f %Y-%m-%dT%H:%M:%S "$reset:00" +%s 2>/dev/null)" \
      && [[ "$(date -u -r "$reset_at" +%Y-%m-%dT%H:%M)" == "$reset" ]]; then
      if (( now < reset_at )); then
        echo "BLOCKED by .claude/hooks/agent-guard.sh: the provider $name hit a rate limit, and its reset is at $reset UTC ($limits). This job has no result: log a decisions.tsv row with the result skipped: rate limit, and do not wait." >&2
        exit 2
      fi
    else
      echo "agent-guard.sh: $limits has a line for $name that is not <name><TAB><YYYY-MM-DDTHH:MM> of a real UTC time. The hook ignores it." >&2
    fi
  done < "$limits"
fi
text="$(plutil -extract "tool_input.$field" raw -o - "$input" 2>/dev/null)"
# The lock-step lists are in scripts/lock-words.sh, which git-guardrails.sh reads too. They equal
# the Makefile .PHONY line minus the four targets that take no lock and the scripts that AGENTS.md
# says take the lock themselves; git-guardrails.test.sh keeps them equal.
. "$(dirname "$0")/../../scripts/lock-words.sh"
steps="$(sed -E 's/with-lock\.sh +--(builders|release-holder)//g' <<< "$text")"
lock_re="with-lock\.sh|(^|[^A-Za-z0-9_-])make([[:space:]]+($lock_make_opt|$lock_make_set|($lock_free_targets)))*[[:space:]]+($lock_targets)([^A-Za-z0-9_-]|\$)|(^|[^A-Za-z0-9_-])($lock_scripts)\.sh|(^|[^A-Za-z0-9_-])swift +($lock_swift)([^A-Za-z0-9_-]|\$)"
if grep -qE "$lock_re" <<< "$steps" && ! grep -qE '^[[:space:]]*([-*>][[:space:]]+)?Build lock: none' <<< "$text"; then
  if holder="$("$(dirname "$0")/../../scripts/with-lock.sh" --release-holder 2>/dev/null)"; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: a release call (a push check, the hooks pass, a land, or make dmg) or a stress lane holds the build lock or waits first for it ($holder), and the brief names a lock step. The agent would wait for the lock on its 90 min clock. Start it after that call ends (scripts/with-lock.sh --builders shows the holder). If the agent runs no with-lock.sh step (a plan, a review, PR text), add the line Build lock: none to the brief, on a line of its own. A with-lock.sh call that prints no lock also waits while this call holds the lock." >&2
    exit 2
  fi
fi
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
