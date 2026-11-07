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
#   land, or make dmg) holds the build lock or waits first for it, or a stress lane
#   (scripts/test-stress.sh) holds the build lock, because the agent would wait for the lock on its
#   90 min clock. A lock step is
#   with-lock.sh, a make target that takes the lock, a script that takes the lock itself, or swift
#   build, test, or run (AGENTS.md, Commands). The
#   state comes from scripts/with-lock.sh --release-holder, and an exit other than 0 or 1 of that
#   query lets the brief pass. A line that starts with Build lock: none (after spaces and one -, *,
#   or > marker) passes a brief of an agent that runs no with-lock.sh step.
# - A delegate_task whose target providerInstanceId or model equals the name of a line of
#   dirigible-provider-limits in the git common dir is refused while now is before the reset of that
#   line. A line is <name><TAB><reset UTC, YYYY-MM-DDTHH:MM>, and scripts/provider-limit.sh writes
#   it. The reset is the start of that minute. PROVIDER_LIMIT_NOW (epoch seconds) sets now. A line
#   that is not in that form, and a missing file, let the call pass; the hook prints a note for the
#   line.
# - A brief that names a review-plan-<n>.md or review-diff-<n>.md file of the open run of the hook
#   cwd (open_run of open-run.py) is refused while scripts/check-plan.sh <run folder> exits 1, so no
#   fixer starts on review items with no Invariant or Siblings field. Each exit 1 of check-plan.sh
#   blocks, whatever rule it names; the block text prints each `check-plan:` line (the whole output
#   when none). The lead writes the review fields itself, so a repair brief is refused too. The folder of a name is its path (absolute, or
#   relative to the cwd); a bare name takes each .scratchpads/runs/<slug> folder of the same text. An
#   exit other than 0 or 1 of check-plan.sh lets the brief pass, with a note. This hook holds the plan
#   gate; at the code gate, log-decision.sh refuses the phase 6 row until check-plan.sh exits 0.
# - An Agent or SendMessage brief that this hook passes and that names a lock step, with no Build
#   lock: none line, gets a record file in dirigible-lock-agents of the git common dir (or
#   $DIRIGIBLE_LOCK_AGENTS). Its name is the tool_use_id (<epoch>-<pid> when that is empty or holds
#   another character than a letter, a digit, _, or -), and its one line is <epoch> <tool> <key>
#   <transcript_path> <description>, tab-separated: the key is the tool_use_id of an Agent call or the
#   to of a SendMessage. Each write removes the record files over 24 h old. The release-wait rule of
#   git-guardrails.sh (AGT-152) reads them.

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
if grep -qE 'review-(plan|diff)-[0-9]+\.md' <<< "$text"; then
  # Prints "<open run folder><TAB><name>" for the first review file name of the text in the open run.
  named="$(python3 -I -c '
import importlib.util, os, re, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("open_run", os.path.join(sys.argv[1], "open-run.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cwd = sys.argv[2]
found = module.open_run(cwd) if cwd else None
if not found:
    sys.exit(0)
run = os.path.realpath(found[0])
text = sys.stdin.read()
word = r"[^\s`\x27\"()<>\[\]]"
folders = [f.rstrip(".,;:") for f in re.findall(word + r"*\.scratchpads/runs/[^\s/`\x27\"()<>\[\]]+", text)]
for name in re.finditer(r"(?<!" + word + r")((?:" + word + r"*/)?)(review-(?:plan|diff)-[0-9]+\.md)(?![A-Za-z0-9_-])", text):
    for folder in [name.group(1)] if name.group(1) else folders:
        if os.path.realpath(os.path.join(cwd, folder)) == run:
            print(run + "\t" + name.group(0))
            sys.exit(0)
' "$(dirname "$0")" "$(plutil -extract cwd raw -o - "$input" 2>/dev/null)" <<< "$text")"
  if [[ -n "$named" ]]; then
    folder="${named%%$'\t'*}"
    out="$("$(dirname "$0")/../../scripts/check-plan.sh" "$folder" 2>&1)"
    code=$?
    if [[ $code -eq 1 ]]; then
      { echo "BLOCKED by .claude/hooks/agent-guard.sh: the brief names ${named#*$'\t'} of the open run $folder, and scripts/check-plan.sh $folder exits 1:"
        grep '^check-plan:' <<< "$out" || echo "$out"
        echo "Fix what scripts/check-plan.sh names (the lead writes review fields itself, with no agent), then start the agent."; } >&2
      exit 2
    fi
    [[ $code -eq 0 ]] || echo "agent-guard.sh: scripts/check-plan.sh $folder exited $code, so the hook does not check the review fields of the brief." >&2
  fi
fi
# The lock-step lists are in scripts/lock-words.sh, which git-guardrails.sh reads too. They equal
# the Makefile .PHONY line minus the four targets that take no lock and the scripts that AGENTS.md
# says take the lock themselves; git-guardrails.test.sh keeps them equal.
. "$(dirname "$0")/../../scripts/lock-words.sh"
steps="$(sed -E 's/with-lock\.sh +--(builders|release-holder)//g' <<< "$text")"
lock_re="with-lock\.sh|(^|[^A-Za-z0-9_-])make([[:space:]]+($lock_make_opt|$lock_make_set|($lock_free_targets)))*[[:space:]]+($lock_targets)([^A-Za-z0-9_-]|\$)|(^|[^A-Za-z0-9_-])($lock_scripts)\.sh|(^|[^A-Za-z0-9_-])swift +($lock_swift)([^A-Za-z0-9_-]|\$)"
lock_brief=""
if grep -qE "$lock_re" <<< "$steps" && ! grep -qE '^[[:space:]]*([-*>][[:space:]]+)?Build lock: none' <<< "$text"; then
  lock_brief=1
  if holder="$("$(dirname "$0")/../../scripts/with-lock.sh" --release-holder 2>/dev/null)"; then
    echo "BLOCKED by .claude/hooks/agent-guard.sh: a release call (a push check, the hooks pass, a land, or make dmg) holds the build lock or waits first for it, or a stress lane holds it ($holder), and the brief names a lock step. The agent would wait for the lock on its 90 min clock. Start it after that call ends (scripts/with-lock.sh --builders shows the holder). If the agent runs no with-lock.sh step (a plan, a review, PR text), add the line Build lock: none to the brief, on a line of its own. A with-lock.sh call that prints no lock also waits while this call holds the lock." >&2
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
if [[ -n "$lock_brief" && ( "$tool" == Agent || "$tool" == SendMessage ) ]]; then
  if [[ -n "${DIRIGIBLE_LOCK_AGENTS:-}" ]]; then rec_dir="$DIRIGIBLE_LOCK_AGENTS"
  else rec_dir="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/dirigible-lock-agents"; fi
  id="$(plutil -extract tool_use_id raw -o - "$input" 2>/dev/null)" || id=""
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || id="$(date +%s)-$$"
  if [[ "$tool" == Agent ]]; then key="$id" desc="$(plutil -extract tool_input.description raw -o - "$input" 2>/dev/null)"
  else key="$(plutil -extract tool_input.to raw -o - "$input" 2>/dev/null)" desc="resume $key"; fi
  path="$(plutil -extract transcript_path raw -o - "$input" 2>/dev/null)"
  mkdir -p "$rec_dir" && find "$rec_dir" -type f -mmin +1439 -delete 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$tool" "${key//[$'\t\n']/ }" "$path" "${desc//[$'\t\n']/ }" > "$rec_dir/.$id.tmp" && mv "$rec_dir/.$id.tmp" "$rec_dir/$id"
fi
exit 0
