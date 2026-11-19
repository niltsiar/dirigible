#!/bin/bash
# Check that git-guardrails.sh blocks and allows the right commands, and that the post-commit hook
# of .githooks deletes the commit message file. It also checks agent-guard.sh, the hook of the tools
# that brief an agent, usage-hook.sh, the hook that gives the usage mode at an agent start,
# handback-guard.sh, the hook that refuses a hand-back while a background task runs, agent-clock.sh,
# the hook that stops a subagent after 90 active minutes or after a commit at 60, and write-guard.sh,
# the hook that refuses a Write over an existing run file. Run by `make check`.
# Each rule kind has one helper that runs its cases over a shared list of forms. Add a form to the
# list, not a lone case:
#   chain rule (a command after a command): expect_each_join <first> <second>
#   AppleScript rule: expect_each_form <want> <line>...
#   guarded file: expect_each_write <path> (block forms) and expect_each_read <path> (allow forms)
#   command guard (a command in a shell context): expect_each_context <want> <command>
#   commit message file (an option value): expect_each_value <want> <path> <command with @V@>
#   lock-free make words (a with-lock.sh make test-hooks call): expect_each_lock [--live <dir>] <want> <command>...
#   release call while a lock-step agent runs: expect_each_release <want> <records dir> (release_forms)
# Before the red run of a new refusal rule, add the real forms of its target command from transcripts,
# decisions.tsv files, or run logs to allowed-commands.txt. The corpus block expects allow for each line.
# HOOK_CASES=<label pattern> runs only the case blocks whose label matches the whole value, with no
# anchors: HOOK_CASES=agent-clock, HOOK_CASES='agent-clock|write-guard'. The `labels` array lists
# them. Each block is an `if case_block <label>; then` segment; the helpers stay outside.
set -uo pipefail
hook="$(dirname "$0")/git-guardrails.sh"
failures=0

# Build the hook input with plutil, the same tool the hook reads it with (no jq on macOS 14).
input="$(mktemp)"
tmp="$(mktemp -d)"
trap 'rm -f "$input"; rm -rf "$tmp"' EXIT
# The release-wait rule reads the records of live lock-step agents: the hooks pass and the push check run
# this file, so the records of a real agent must not change a case.
export DIRIGIBLE_LOCK_AGENTS="$tmp/lock-agents"
mkdir -p "$DIRIGIBLE_LOCK_AGENTS"

# expect <want> <command> [<run_in_background> [<timeout> [<cwd>]]]: the optional values (true or
# false, and milliseconds) go to tool_input as the Bash tool gives them; the cwd goes to the top level
# of the input, as the harness gives it.
expect() {
  local want="$1" command="$2" background="${3:-}" limit="${4:-}" cwd="${5:-}" got
  plutil -create xml1 "$input"
  [[ -z "$cwd" ]] || plutil -insert cwd -string "$cwd" "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert tool_input.command -string "$command" "$input"
  [[ -z "$background" ]] || plutil -insert tool_input.run_in_background -bool "$background" "$input"
  [[ -z "$limit" ]] || plutil -insert tool_input.timeout -integer "$limit" "$input"
  plutil -convert json "$input"
  "$hook" < "$input" 2>/dev/null
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $command"; failures=$((failures + 1)); }
}

# expect_agent <want> <command> [<run_in_background> [<timeout>]]: as expect, with agent_id in the
# input, as in the input of a subagent. The message of a block goes to $tmp/agent.err.
expect_agent() {
  local want="$1" command="$2" background="${3:-}" limit="${4:-}" got
  plutil -create xml1 "$input"
  plutil -insert agent_id -string a1 "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert tool_input.command -string "$command" "$input"
  [[ -z "$background" ]] || plutil -insert tool_input.run_in_background -bool "$background" "$input"
  [[ -z "$limit" ]] || plutil -insert tool_input.timeout -integer "$limit" "$input"
  plutil -convert json "$input"
  "$hook" < "$input" 2>"$tmp/agent.err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: subagent expected $want, got $got: $command"; failures=$((failures + 1)); }
}

# The forms of a commit message file option and its value, for expect_each_value: @P@ is the path.
# The hook does not decode an ANSI-C string ($'...'), so it fails closed on that form of any path.
value_forms=(
  '-F @P@' "-F '@P@'" '-F "@P@"' "-F \$'@P@'" '-F@P@' '--file=@P@' '--file @P@' '-aF @P@' '-qF @P@'
  '--fil=@P@' '-F @P@ 2>&1' '-F @P@ >&2' '-F @P@ &>/dev/null' '2>&1 -F @P@' '>&2 -F @P@'
  '&>/dev/null -F @P@' $'<<MARK -F @P@\nbody\nMARK' "-m \$'it\\'s' -F @P@" "-m \$'it\\'s -F x' -F @P@"
  "-m 'a -F b' -F @P@" $'-F @P@ <<MARK\nbody\nMARK' $'-F @P@ <<-MARK\n\tbody\n\tMARK'
  $'-F @P@ <<A <<B\na\nA\nb\nB'
)
# expect_each_value <want> <path> <command with @V@> [plain]: @V@ becomes each form in value_forms.
# With plain, the command holds the forms as data (an interpreter body), so the fail-closed ANSI-C
# form needs no block.
expect_each_value() {
  local form want
  for form in "${value_forms[@]}"; do
    want="$1"
    [[ "$form" == *"\$'@P@'"* && -z "${4:-}" ]] && want=block
    expect "$want" "${3//@V@/${form//@P@/$2}}"
  done
}

# expect_message <reason> <command>: a block whose message holds the reason and tells how to write data (the hook
# matches quoted text too).
expect_message() {
  local reason="$1" msg
  expect block "$2"
  msg="$("$hook" < "$input" 2>&1)"
  [[ "$msg" == *"$reason"* && "$msg" == *"If the matched text is only data, write it with the Write tool"* ]] \
    || { echo "FAIL: no reason or no data hint in the message: $2"; failures=$((failures + 1)); }
}

# expect_each_lock <want> <command>...: the hook verdict of a with-lock.sh make test-hooks spelling, and the
# class that scripts/lock-words.sh gives the words that with-lock.sh would get from it. The spelling runs
# through eval with a stub for scripts/with-lock.sh ($lock_stub, made by the test-rule segment) that prints
# free, release, or lock. A free or release call is allowed, a lock call blocks. want agree: the hook
# verdict is the verdict of the class. want allow or block: both hold that verdict. One FAIL line a spelling.
# With --live <records dir>, a folder with a live lock-step agent (AGT-152), a release call blocks too.
expect_each_lock() {
  local live="$DIRIGIBLE_LOCK_AGENTS" release=allow want form class verdict got
  [[ "$1" == --live ]] && { live="$2" release=block; shift 2; }
  want="$1"
  shift
  for form in "$@"; do
    class="$( (unset BASE MAKEFLAGS DIRIGIBLE_HOOKS_ALL; eval "${form//scripts\/with-lock.sh/$lock_stub}") 2>/dev/null | tail -n 1)"
    case "$class" in free) verdict=allow ;; release) verdict="$release" ;; *) verdict=block ;; esac
    plutil -create xml1 "$input"
    plutil -insert tool_input -dictionary "$input"
    plutil -insert tool_input.command -string "$form" "$input"
    plutil -convert json "$input"
    DIRIGIBLE_LOCK_AGENTS="$live" "$hook" < "$input" > /dev/null 2>&1
    [[ $? -eq 2 ]] && got=block || got=allow
    [[ "$class" =~ ^(free|release|lock)$ && "$got" == "$verdict" && ( "$want" == agree || "$want" == "$verdict" ) ]] ||
      { echo "FAIL: lock class '$class' (want $want), hook $got: $form"; failures=$((failures + 1)); }
  done
}

# A command guard must hold in each shell context, not only in the contexts that a gate found one at a
# time (the DLV-210 guard failed open in five review rounds). expect_each_context <block|allow>
# <command> runs <command> in one shared list: a block context runs it as code (a group, a redirect, a
# comment line with an apostrophe around it, a shell heredoc, a $(...), a cd prefix), and an allow
# context holds it as data (quotes, a commit message heredoc, a cat heredoc). @C@ is the command.
# The two optional values after <command> go to each case (see expect).
context_block=(
  '( @C@ )' '{ @C@; }' '@C@ >log' '@C@>log'
  $'# it\'s here\n@C@\n# that\'s all'
  $'bash <<\'EOF\'\n@C@\nEOF'
  'x=$(@C@)' 'echo "$(@C@)"'
  'cd /x/wt && @C@' "cd '/x y/wt' && @C@"
)
context_allow=(
  "echo '@C@'" 'echo "@C@"'
  $'git commit -F - <<\'EOF\'\n@C@\nEOF'
  $'cat <<\'EOF\'\n@C@\nEOF'
  $'python3 - <<\'EOF\'\n@C@\nEOF'
)
expect_each_context() {
  local want="$1" cmd="$2" ctx
  local -a forms=("${context_block[@]}")
  [[ "$want" == block ]] || forms=("${context_allow[@]}")
  for ctx in "${forms[@]}"; do expect "$want" "${ctx//@C@/$cmd}" "${@:3}"; done
}

# The release-wait rule (AGT-152) reads a records folder per case, with a fake session under $tmp. Each
# age counts back from the time of the helper call, so a slow run does not move a case over a limit.
rw_sess="$tmp/rw-s/sess.jsonl" rw_sub="$tmp/rw-s/sess/subagents"
mkdir -p "$rw_sub"
rw_stamp() { date -r "$1" +%Y%m%d%H%M.%S; }
# rw_rec <dir> <id> <age s> <tool> <key> [<description>]: a record file as agent-guard.sh writes it.
rw_rec() {
  local t=$(($(date +%s) - $3))
  mkdir -p "$1"
  printf '%s\t%s\t%s\t%s\t%s\n' "$t" "$4" "$5" "$rw_sess" "${6:-d $2}" > "$1/$2"
  touch -t "$(rw_stamp "$t")" "$1/$2"
}
# rw_meta <agent id> <toolUseId> <true|none> <mtime age s>: the meta file of an agent of the session.
rw_meta() {
  local f="$rw_sub/agent-$1.meta.json"
  if [[ "$3" == true ]]; then printf '{"agentType":"run-agent","description":"d","toolUseId":"%s","finished":true}' "$2" > "$f"
  else printf '{"agentType":"run-agent","description":"d","toolUseId":"%s"}' "$2" > "$f"; fi
  touch -t "$(rw_stamp $(($(date +%s) - $4)))" "$f"
}
# expect_release <want> <records dir> <command> [<cwd>] [<agent id>] [bg]: the hook verdict with that records
# folder; bg sets run_in_background true and the timeout 7200000. Stdout goes to $tmp/release.out and the
# message to $tmp/release.err.
expect_release() {
  local want="$1" got
  plutil -create xml1 "$input"
  [[ -z "${5:-}" ]] || plutil -insert agent_id -string "$5" "$input"
  [[ -z "${4:-}" ]] || plutil -insert cwd -string "$4" "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert tool_input.command -string "$3" "$input"
  if [[ "${6:-}" == bg ]]; then
    plutil -insert tool_input.run_in_background -bool true "$input"
    plutil -insert tool_input.timeout -integer 7200000 "$input"
  fi
  plutil -convert json "$input"
  DIRIGIBLE_LOCK_AGENTS="$2" "$hook" < "$input" > "$tmp/release.out" 2> "$tmp/release.err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: release-wait expected $want, got $got: ${3//$'\n'/\\n}"; failures=$((failures + 1)); }
}
# release_has <text>: the message of the last expect_release holds the text.
release_has() {
  grep -qF -- "$1" "$tmp/release.err" || { echo "FAIL: release-wait message lacks: $1"; failures=$((failures + 1)); }
}
# release_out <text>: the stdout of the last expect_release holds the text; with "", it is empty.
release_out() {
  if [[ -z "$1" ]]; then [[ ! -s "$tmp/release.out" ]] || { echo "FAIL: release-wait stdout is not empty: $(cat "$tmp/release.out")"; failures=$((failures + 1)); }
  else grep -qF -- "$1" "$tmp/release.out" || { echo "FAIL: release-wait stdout lacks: $1"; failures=$((failures + 1)); }; fi
}
# The release call forms of the lead, with neutral paths: the nohup bash -c transcript form of the push
# check, the hooks pass, the land, both in one body, and make dmg; then nice, nohup nice, shell -c bodies,
# the plain forms, an export of BASE, and a quoted with-lock.sh word.
release_forms=(
  'cd /x/wt && R=/x/run && (nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main > $R/logs/push-check.log 2>&1; echo \"exit \$?\" > $R/logs/push-check.done" > /dev/null 2>&1 < /dev/null &)'
  'cd /x/wt && R=/x/run; (nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1 > $R/logs/hooks-pass.log 2>&1; echo \"exit \$?\" > $R/logs/hooks-pass.done" > /dev/null 2>&1 < /dev/null &); sleep 3; head -3 $R/logs/hooks-pass.log'
  "cd /x/wt && git status --porcelain && R=/x/run && (nohup bash -c \"WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh 'Fix the hooks' \$R/pr.md > \$R/logs/land.log 2>&1; echo \\\"exit \\\$?\\\" > \$R/logs/land.done\" > /dev/null 2>&1 < /dev/null &)"
  'cd /x/wt && R=/x/run && (nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1 > $R/logs/hooks-pass.log 2>&1; if grep -q '"'"'exit 0'"'"' $R/logs/hooks-pass.done; then WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main > $R/logs/push-check.log 2>&1; fi" > /dev/null 2>&1 < /dev/null &)'
  'cd /x/wt && R=/x/run; (nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make dmg > $R/logs/dmg.log 2>&1; echo \"exit \$?\" > $R/logs/dmg.done" > /dev/null 2>&1 < /dev/null &); echo started'
  'nice -n 10 scripts/with-lock.sh make check-changed BASE=origin/main'
  'nohup nice -n 5 scripts/with-lock.sh make dmg > x.log 2>&1 &'
  'bash -c "cd /x/wt && WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make dmg"'
  "sh -c 'cd /x; scripts/with-lock.sh make dmg'"
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main > logs/push-check.log 2>&1'
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1'
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh "t" x/pr.md'
  'scripts/land.sh "t" x/pr.md'
  'scripts/with-lock.sh make dmg'
  'BASE=origin/main scripts/with-lock.sh make check-changed'
  'export BASE=origin/main; scripts/with-lock.sh make check-changed'
  'cd /x/wt && WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main'
  'cd /x/wt && "scripts/with-lock.sh" make dmg'
  'scripts/with-lock.sh make check-changed BASE="origin/main"'
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE="$(git merge-base HEAD origin/main)"'
  'scripts/with-lock.sh make "check-changed" BASE=origin/main'
  'scripts/with-lock.sh make "dmg"'
  "scripts/with-lock.sh make 'check-changed' BASE='origin/main'"
  'scripts/with-lock.sh bash scripts/land.sh t b.md'
  'bash scripts/land.sh t b.md'
  'sh -x scripts/land.sh t b.md'
)
# expect_each_release <want> <records dir>: expect_release on each form of release_forms.
expect_each_release() {
  local form
  for form in "${release_forms[@]}"; do expect_release "$1" "$2" "$form"; done
}

settings="$(dirname "$0")/../settings.json"
printf '{"hooks":{"PreToolUse":[{"matcher":"Agent|Workflow","hooks":[{"type":"command","command":"x/.claude/hooks/usage-hook.sh"}]}]}}' > "$tmp/old-settings.json"

# HOOK_CASES=<ERE> runs only the case blocks whose label matches the whole value. The test wraps the
# value as ^(<value>)$, so write it with no anchors: make drops a trailing $. A block prints its
# label when it starts. A value that matches no label exits 1.
labels=(guardrails guardrails-tag guardrails-rules test-rule release-wait corpus post-commit pre-commit commit-msg agent-guard usage-hook
  handback-guard agent-clock write-guard holdout-keys stop-guard pre-compact hook-cases)
cases_pattern="^(${HOOK_CASES:-.*})\$"
cases_hit=0
for label in "${labels[@]}"; do [[ "$label" =~ $cases_pattern ]] && cases_hit=1; done
[[ $cases_hit -eq 1 ]] || { echo "git-guardrails: HOOK_CASES='${HOOK_CASES:-}' matches no case block. Labels: ${labels[*]}" >&2; exit 1; }
cases_printed=' '
case_block() { # <label>: true when the block of the label runs
  [[ "$1" =~ $cases_pattern ]] || return 1
  [[ "$cases_printed" == *" $1 "* ]] || { echo "$1"; cases_printed+="$1 "; }
}

# HOOK_CASES self-test. A copy of this folder, with a git-guardrails.sh stub that allows each
# command, runs filtered only. GUARDRAILS_TEST_COPY skips this block in a copy, so no copy starts a
# nested run. A guardrails label fails on the copy: its cases expect refusals.
if [[ -z "${GUARDRAILS_TEST_COPY:-}" ]] && case_block hook-cases; then
  # outside_cases <file>: each line that calls a case helper outside a case_block segment
  outside_cases() {
    awk '/^if .*case_block /{in_block=1; next} /^fi # /{in_block=0; next}
      !in_block && /^(expect[a-z_]*|hb_expect|hb_err_has|wg_expect|stop_expect|pc_run|pc_has|pc_lacks|hook_registered|matcher_covers|event_registered|event_timeout) / {print FILENAME ":" FNR ": " $0}' "$1"
  }
  printf "expect allow 'x'\nif case_block a; then\nexpect allow 'y'\nfi # a\nexpect allow 'z'\n" > "$tmp/stray.sh"
  [[ "$(outside_cases "$tmp/stray.sh" | wc -l | tr -d ' ')" == 2 ]] ||
    { echo "FAIL: the outside_cases check misses a case call outside a segment"; failures=$((failures + 1)); }
  outside="$(outside_cases "$0")"
  [[ -z "$outside" ]] || { echo "FAIL: a case call is outside a case_block segment: $(head -n 3 <<< "$outside")"; failures=$((failures + 1)); }
  [[ "$(grep -oE '^if .*case_block [a-z-]+' "$0" | awk '{print $NF}' | sort -u)" == "$(printf '%s\n' "${labels[@]}" | sort)" ]] ||
    { echo "FAIL: the labels array and the case_block segments name other labels"; failures=$((failures + 1)); }

  # An expect_each_* helper that a case block calls must be defined outside every segment, or in the
  # same segment: a filtered run (HOOK_CASES) skips the other segments, and bash 3.2 has no
  # command_not_found_handle, so a missing helper would print "command not found" and pass.
  stray_helpers="$(awk '
    /^if .*case_block /{blk=$0; sub(/.*case_block /, "", blk); sub(/;.*/, "", blk); next}
    /^fi # /{blk=""; next}
    /^expect_each_[a-z_]+\(\) *\{/{n=$1; sub(/\(\).*/, "", n); if (blk == "") shared[n] = 1; else def[n] = blk; next}
    blk != "" && !/^[ \t]*#/ && match($0, /expect_each_[a-z_]+/) {calls[++k] = substr($0, RSTART, RLENGTH) " " blk}
    END {for (i = 1; i <= k; i++) {split(calls[i], c, " "); if (!(c[1] in shared) && def[c[1]] != c[2]) print c[1] " in " c[2]}}' "$0" | sort -u)"
  [[ -z "$stray_helpers" ]] || { echo "FAIL: a helper is not defined for the segment that calls it: $(head -n 3 <<< "$stray_helpers")"; failures=$((failures + 1)); }

  copy="$tmp/copy"
  mkdir -p "$copy/.claude"
  cp -R "$(dirname "$0")" "$copy/.claude/hooks"
  cp "$settings" "$copy/.claude/settings.json"
  printf '#!/bin/bash\nexit 0\n' > "$copy/.claude/hooks/git-guardrails.sh"
  copy_cases=('agent-clock' 'agent-clock|write-guard' 'guardrails-tag' 'agent' 'no-such-block')
  for i in "${!copy_cases[@]}"; do
    (
      GUARDRAILS_TEST_COPY=1 HOOK_CASES="${copy_cases[$i]}" perl -e 'alarm 300; exec @ARGV' "$copy/.claude/hooks/git-guardrails.test.sh" > "$tmp/copy-$i.out" 2>&1
      echo $? > "$tmp/copy-$i.code"
    ) &
  done
  wait
  # copy_is <index> <exit status> <output pattern>: the copy ended with the status, and its output matches
  copy_is() {
    [[ "$(cat "$tmp/copy-$1.code")" == "$2" && "$(cat "$tmp/copy-$1.out")" == $3 ]] ||
      { echo "FAIL: HOOK_CASES=${copy_cases[$1]}: exit $(cat "$tmp/copy-$1.code"), output: $(head -c 300 "$tmp/copy-$1.out")"; failures=$((failures + 1)); }
  }
  copy_is 0 0 'agent-clock'
  copy_is 1 0 $'agent-clock\nwrite-guard'
  copy_is 2 1 $'guardrails-tag\n*FAIL*'
  copy_is 3 1 '*HOOK_CASES*guardrails-tag*'
  copy_is 4 1 '*HOOK_CASES*guardrails-tag*'
fi # hook-cases

if case_block guardrails; then
expect block 'git push --force origin feat/x'
expect block 'git push -f origin feat/x'
expect block 'git push origin +feat/x'
expect block 'git push origin main'
expect block 'git push origin HEAD:main'
expect block 'git reset --hard HEAD~1'
expect block 'git clean -fd'
expect block 'git branch -D feat/x'
expect block 'git branch -d -f feat/x'
expect block 'git checkout .'
expect block 'git restore .'
expect block 'git switch feat/x --discard-changes'
expect block 'git switch -f main'
expect block 'git stash drop'
# A forced worktree remove deletes the uncommitted work of the tree.
expect block 'git worktree remove --force ../wt'
expect block 'git worktree remove -f ../wt'
expect block 'git -C /repo worktree remove ../wt --force'
expect allow 'git worktree remove ../wt'
expect block 'git commit -m "x" --no-verify'
expect block 'git commit -n -m "x"'
expect block 'git config --local core.hooksPath /dev/null'
expect block 'git config --local --unset core.hooksPath'
expect block 'gh pr merge 3 --rebase --admin'
expect block 'git -C . reset --hard'
expect block 'git -C /repo push -f origin feat/x'
expect block 'git -c core.hooksPath=/dev/null commit -m x'
expect block 'git push origin feat/x:main'
expect block 'git push origin HEAD:refs/heads/main'
expect block 'git push -uf origin feat/x'
expect block 'make check && git push origin main'
expect block 'git status; git reset --hard'
expect block 'env X=1 git push -f origin feat/x'
expect block 'bash -c "git push -f origin feat/x"'
expect block 'git commit -n -m x | cat'
# The message path is an allow list: only .scratchpads/commit-msg.txt and - (stdin) pass, in each
# form of the option and with a -C, a cd, or no prefix. A path in the run folder, the temp folder,
# or the tree of another run blocks (AGT-058, run flakes-2).
expect_each_value allow .scratchpads/commit-msg.txt 'git commit @V@'
expect_each_value allow .scratchpads/commit-msg.txt 'git -C /Users/x/wt commit @V@'
expect_each_value allow .scratchpads/commit-msg.txt 'cd /x && git commit @V@'
expect_each_value block msg.txt 'git commit @V@'
expect_each_value block /Users/x/repo/.scratchpads/commit-msg.txt 'git commit @V@'
expect_each_value block ../repo/.scratchpads/commit-msg.txt 'git commit @V@'
expect_each_value block '~/repo/.scratchpads/commit-msg.txt' 'git commit @V@'
expect_each_value block /tmp/commit-msg.txt 'git commit @V@'
expect_each_value block .scratchpads/runs/x/msg.txt 'git commit @V@'
expect_each_value block ./.scratchpads/commit-msg.txt 'git commit @V@'
expect_each_value block msg.txt 'git -C ../tree commit -q @V@'
# An absolute message path can name the file of another work tree (run flakes-2).
expect block 'git -C /Users/x/wt commit -F /Users/x/repo/.scratchpads/commit-msg.txt'
# Only that relative path: a relative, ~, or $HOME path can name another tree too (code gate 1).
expect block 'git commit -F "$HOME/repo/.scratchpads/commit-msg.txt"'
expect block 'git commit --file ../wt/.scratchpads/notes.txt'
expect allow 'git commit -m "read .scratchpads/commit-msg.txt"'
expect block 'git commit -F "/tmp/release notes.txt"'
expect block 'git commit -q -F $R/logs/s4-msg.txt'
expect block 'git commit --file=notes/msg.txt'
expect block 'git -C ../tree commit -F msg.txt'
expect block 'git commit -F ""'
expect block 'git commit -F " msg.txt"'
expect allow $'git commit -F - <<\'EOF\'\nfix: a thing\nEOF'
# A grep for the text "git commit -F" runs no commit: the text is inside quotes.
expect allow "rg -n 'git commit -F' .claude"
expect allow 'rg -n "git commit -F" .claude'
expect allow "rg -n 'git commit -F <file>' docs"
# Text inside a quoted string or a heredoc body is data, not an option of the commit. A real option
# after the quoted text still counts.
expect allow 'git commit -m "test: rg -F case"'
expect allow "git commit -m 'allow --file=x'"
expect allow $'git commit -m "fix: a thing\n\ngit commit -F msg.txt is blocked."'
expect allow $'git commit -F - <<\'EOF\'\nfix: a thing\n\ngit commit -F msg.txt is blocked.\nEOF'
expect block 'git commit -m "a -F b" -F msg.txt'
# In an ANSI-C string ($'...') a backslash escapes the apostrophe, so the string goes on to the next
# apostrophe.
expect block "git commit -m \$'it\\'s' -F /tmp/o/m"
expect allow "git commit -m \$'it\\'s -F x'"
# A - message comes from a heredoc on the commit. A < file, a pipe, or no heredoc can take the message
# file of another work tree.
expect block 'git commit -F - < /tmp/other/.scratchpads/commit-msg.txt'
expect block 'git commit -F - </tmp/other/msg.txt'
expect block 'cat /tmp/other/.scratchpads/commit-msg.txt | git commit -F -'
expect block $'cat <<\'EOF\' | git commit -q -F -\nfix: a thing\nEOF'
expect block 'git commit -F -'
expect allow $'git commit -F - <<EOF\nfix: a thing\nEOF'
# An & that is part of a redirect (2>&1, >&2, &>, &>>) does not end the commit; && and a trailing & do.
expect allow $'git commit -F - 2>&1 <<\'EOF\'\nfix: a thing\nEOF'
expect allow $'git commit -F - >&2 <<\'EOF\'\nfix: a thing\nEOF'
expect allow $'git commit -q -F - &>/dev/null <<\'EOF\'\nfix: a thing\nEOF'
# The body of a heredoc that the hook keeps as code (an interpreter body) can hold an apostrophe: the
# quote state ends at the end line, so a later commit with a wrong path still blocks.
expect block $'python3 - <<\'EOF\'\n# don\'t mind\nprint(1)\nEOF\ngit commit -F /tmp/o/m'
expect block $'cat <<EOF > /tmp/x\nit\'s $(date)\nEOF\ngit commit -F /tmp/o/m'
# git reads the last message-file option, so a commit with two blocks.
expect block 'git commit -F .scratchpads/commit-msg.txt -F msg.txt'
expect block 'git commit -F .scratchpads/commit-msg.txt --file=msg.txt'
# The word then is no separator, so a later -F is a second option of the commit. A real separator
# ends the commit (below).
expect block 'git commit -F ../main/.scratchpads/commit-msg.txt then rg -F foo bar'
expect block 'git commit -F .scratchpads/commit-msg.txt then rg -F .scratchpads/runs/x/rows .gitignore'
expect block 'git commit -F ../other/.scratchpads/commit-msg.txt then git commit -F .scratchpads/commit-msg.txt'
# The commit ends at the first command separator, so a commit with no -F does not take the -F of a
# later command.
expect allow 'git commit -m fix && rg -F .scratchpads/runs/x/rows .gitignore'
expect allow 'git commit -m fix; rg -F .scratchpads/runs/x/rows .gitignore'
expect allow 'git commit -m fix | rg -F .scratchpads/runs/x/rows'
expect allow 'git commit -m fix & rg -F .scratchpads/runs/x/rows .gitignore'

expect allow 'git push -u origin feat/multitrack-capture'
expect allow 'git push origin chore/refine-setup'
expect allow 'git branch -d feat/x'
expect allow 'git switch main'
expect allow 'git switch -c feat/x'
expect allow 'git commit -m "feat(capture): record two devices"'
expect allow 'git config --local core.hooksPath .githooks'
expect allow 'git config --local --get core.hooksPath'
# A read of the hooks path with no value is allowed (user decision of the retro, option A). A write
# chained after a read, and each other config action, stays blocked.
expect allow 'git config core.hooksPath'
expect allow 'git config --local core.hooksPath'
expect allow 'echo "$(git config core.hooksPath)"'
expect block 'git config core.hooksPath x; ls'
expect block 'git config core.hooksPath; git -c core.hooksPath=/dev/null commit -m x'
expect block 'git config --unset-all core.hooksPath'
expect block 'git config --replace-all core.hooksPath x'
expect block 'git config --add core.hooksPath x'
# The key matches in any case. The read form must start a command, and its flags come in any order
# (code gate item B).
expect block 'git config core.hookspath x'
expect block 'git config CORE.HOOKSPATH /dev/null'
expect block 'git -c core.hookspath=/x commit -m x'
expect block 'xargs git config core.hooksPath'
expect block 'echo x | xargs git config core.hooksPath'
expect allow 'git config core.hookspath'
expect allow 'git config --get --local core.hooksPath'
expect allow 'git -C /repo config --local --get core.hooksPath'
expect allow 'git config get core.hooksPath'
expect allow 'git config get --local core.hooksPath'
expect allow 'git config core.hooksPath; git config --get core.hooksPath'
expect allow 'git config core.hooksPath && git status'
# Each read form is allowed: --get, --get-all, --show-origin, --worktree, --local, a stderr redirect
# to /dev/null, and a chain member. A value, --unset, --add, and --replace-all stay blocked.
expect allow 'git config --get-all core.hooksPath'
expect allow 'git config --show-origin --get-all core.hooksPath'
expect allow 'git config --worktree --get core.hooksPath'
expect allow 'git config --local core.hooksPath 2>/dev/null'
expect allow 'git config --get core.hooksPath 2>/dev/null; git status'
expect allow 'echo "hooks: $(git config --get core.hooksPath 2>/dev/null)"'
expect block 'git config --worktree core.hooksPath x'
expect block 'git config --get-all core.hooksPath x'
expect block 'git config --show-origin --unset core.hooksPath'
expect block 'git config --get core.hooksPath 2>/dev/null; git config --add core.hooksPath x'
expect block 'gh pr merge 3 --rebase --delete-branch'
expect allow 'git stash push -m wip'
# AGT-154: all worktrees share one stash list, so pop, apply, and branch (it applies and drops the
# entry) block in each context, data too.
for stash in 'git stash pop' 'git stash pop -q' 'git stash apply' 'git stash apply stash@{1}' 'git -C /x/wt stash pop' \
  'git stash branch tmp' 'git stash branch tmp stash@{0}' 'git -c x=y stash branch tmp'; do
  expect_each_context block "$stash"
done
expect block "echo 'git stash pop'"
expect block "echo 'git stash branch tmp'"
expect_message 'applies a stash entry, and all worktrees share one stash list' 'git stash branch tmp'
expect allow 'git stash list'
expect allow 'git stash show -p stash@{0}'
expect allow 'git stash'
expect allow 'git stash push -m pop'
expect_message 'applies a stash entry, and all worktrees share one stash list' 'git stash pop'
expect_message 'with git diff <path> > <run>/x.patch, restore with git checkout <path>, and apply it with git apply' 'git stash apply'
expect allow 'scripts/with-lock.sh make check'
expect allow 'git -C /repo status'
expect allow 'git push -u origin feat/main-window'
expect allow 'git push --follow-tags origin feat/x'
# A branch switch in a main checkout (INT-071): a local branch other than main, `-`, a create option,
# and a detach block; a file restore, main, a linked worktree, and no known tree pass.
sw_main="$tmp/sw-main"
sw_wt="$tmp/sw-wt"
git init -q -b main "$sw_main"
git -C "$sw_main" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$sw_main" branch feat/x
git -C "$sw_main" worktree add -q -b wt "$sw_wt"
mkdir "$sw_main/sub"
# A branch that only a remote has (git checkout.guess makes the local branch), a tag, and a commit.
git -C "$sw_main" branch remote-only
git clone -q --bare "$sw_main" "$tmp/sw-origin.git"
git -C "$sw_main" branch -q -d remote-only
git -C "$sw_main" remote add origin "$tmp/sw-origin.git"
git -C "$sw_main" fetch -q origin
git -C "$sw_main" tag sw-tag
git -C "$sw_main" checkout -q feat/x && git -C "$sw_main" checkout -q main # a previous branch for @{-1}
sw_sha="$(git -C "$sw_main" rev-parse HEAD)"
expect block 'git checkout -q feat/x' '' '' "$sw_main"
expect block 'git switch feat/x' '' '' "$sw_main"
expect block 'git switch feat/x' '' '' "$sw_main/sub"
expect block 'git switch "feat/x"' '' '' "$sw_main"
expect block $'git switch\tfeat/x 2>&1' '' '' "$sw_main"
expect block 'git switch -c y' '' '' "$sw_main"
expect block 'git switch -C y' '' '' "$sw_main"
expect block 'git checkout -b y' '' '' "$sw_main"
expect block 'git checkout -B y origin/main' '' '' "$sw_main"
expect block 'git checkout --orphan z' '' '' "$sw_main"
expect block 'git switch --detach origin/main' '' '' "$sw_main"
expect block 'git switch -d main' '' '' "$sw_main"
expect block 'git checkout -' '' '' "$sw_main"
expect block 'git switch -' '' '' "$sw_main"
expect block "cd $sw_main && git switch feat/x" '' '' "$sw_wt"
expect block "git -C $sw_main switch feat/x" '' '' "$sw_wt"
expect block 'cd sw-main && git switch feat/x' '' '' "$tmp"
expect block 'git -C sw-main switch feat/x' '' '' "$tmp"
expect block 'git status; git switch feat/x' '' '' "$sw_main"
expect block 'git checkout remote-only' '' '' "$sw_main"
expect block 'git switch remote-only' '' '' "$sw_main"
expect block 'git checkout -t origin/remote-only' '' '' "$sw_main"
expect block 'git checkout --track origin/remote-only' '' '' "$sw_main"
expect block 'git switch -t origin/remote-only' '' '' "$sw_main"
expect block 'git switch --track origin/remote-only' '' '' "$sw_main"
expect block 'git checkout origin/remote-only' '' '' "$sw_main"
expect block 'git checkout origin/main' '' '' "$sw_main"
expect block 'git checkout sw-tag' '' '' "$sw_main"
expect block "git checkout $sw_sha" '' '' "$sw_main"
expect block "git checkout ${sw_sha:0:7}" '' '' "$sw_main"
expect block 'git checkout HEAD~0' '' '' "$sw_main"
expect block 'git checkout @{-1}' '' '' "$sw_main"
expect block 'gh pr checkout 12' '' '' "$sw_main"
expect block 'gh co 12' '' '' "$sw_main"
expect block 'gh pr checkout' '' '' "$sw_main"
expect block 'gh pr checkout 12 --detach' '' '' "$sw_main"
expect block 'gh pr checkout 12 -b fix' '' '' "$sw_main"
expect block 'gh -R o/r pr checkout 12' '' '' "$sw_main"
expect block 'gh pr checkout -R o/r 12' '' '' "$sw_main"
expect block 'GH_DEBUG=1 gh pr checkout 12' '' '' "$sw_main"
expect block 'gh pr view 12 && gh pr checkout 12' '' '' "$sw_main"
expect block 'sleep 1 & gh pr checkout 12' '' '' "$sw_main"
expect block "cd $sw_main && gh pr checkout 12" '' '' "$sw_wt"
expect allow 'git checkout -- README.md' '' '' "$sw_main"
expect allow 'git checkout main' '' '' "$sw_main"
expect allow 'git switch main' '' '' "$sw_main"
expect allow 'git checkout feat-file.txt' '' '' "$sw_main"
expect allow 'git checkout feat/x -- README.md' '' '' "$sw_main"
expect allow 'git checkout feat/x README.md' '' '' "$sw_main"
expect allow 'git worktree add -b y ../w main' '' '' "$sw_main"
expect allow 'git checkout --no-guess remote-only' '' '' "$sw_main"
expect allow 'git switch --no-guess remote-only' '' '' "$sw_main"
expect allow 'git checkout HEAD' '' '' "$sw_main"
expect allow 'git checkout @' '' '' "$sw_main"
expect allow "git checkout $sw_sha -- README.md" '' '' "$sw_main"
expect allow 'git checkout origin/main README.md' '' '' "$sw_main"
expect allow 'git switch origin/main' '' '' "$sw_main"
expect allow 'gh pr checkout 12' '' '' "$sw_wt"
expect allow 'gh pr checkout 12'
expect allow 'gh pr view 12' '' '' "$sw_main"
expect allow 'gh pr list --state open' '' '' "$sw_main"
expect allow 'gh pr checks 12' '' '' "$sw_main"
expect allow 'gh pr diff 12' '' '' "$sw_main"
expect allow 'gh co' '' '' "$sw_wt"
expect allow 'git commit -m "docs: gh pr checkout is refused"' '' '' "$sw_main"
expect allow "rg 'gh pr checkout' docs" '' '' "$sw_main"
expect allow "(cd $sw_wt && gh pr checkout 12)" '' '' "$sw_main"
expect allow 'git switch feat/x' '' '' "$sw_wt"
expect allow 'git switch -c y' '' '' "$sw_wt"
expect allow "git -C $sw_wt switch feat/x" '' '' "$sw_main"
expect allow "cd $sw_wt && git switch feat/x" '' '' "$sw_main"
expect allow "(cd $sw_main && git log -1); git switch feat/x" '' '' "$sw_wt"
expect allow 'git switch feat/x'
expect allow 'git -C ../nowhere switch feat/x' '' '' "$sw_main"
expect allow 'git commit -m "docs: git switch feat/x is refused"' '' '' "$sw_main"
expect allow "rg 'git switch feat/x' docs" '' '' "$sw_main"
fi # guardrails
if case_block guardrails-tag; then
# A release tag comes only from scripts/tag-release.sh: a hand tag, a tag delete, or a tag push
# blocks, and the message names the script. A list of the tags passes.
expect block 'git tag -a v0.3.10 -m x'
expect block 'git tag v0.3.10 abc123'
expect block 'git -C ../wt tag -d v0.3.10'
expect block 'git push origin v0.3.10'
expect block 'git push --tags'
expect block 'git push origin refs/tags/v1'
expect block 'cd x && git tag -f v1'
expect allow 'git tag'
expect allow "git tag -l 'v0.3.*'"
expect allow 'git tag --list'
expect allow 'git tag --points-at HEAD'
# Every read form passes: a note list, a sort, a format, a column, and a verify. --sort, --format,
# and --column make a tag when a name follows and no list flag does, so a name blocks them.
expect allow 'git tag -n'
expect allow 'git tag -n5 v0.3.10'
expect allow 'git tag -ln'
expect allow 'git tag --sort=-v:refname | head -3'
expect allow "git tag --sort=-creatordate --format='%(refname) %(creatordate)'"
expect allow 'git tag --format=%(refname)'
expect allow 'git tag --column'
expect allow 'git tag -v v0.3.10'
expect allow 'git tag --verify v0.3.10'
expect allow "git tag -l 'v0.3.*' --sort=-v:refname"
expect block 'git tag --sort=-v:refname v1'
expect block "git tag --format='%(refname)' 'v1'"
expect block 'git tag --column v1'
expect block 'git tag -n -a v1 -m x'
expect allow 'scripts/tag-release.sh 0.3.10 abc123 run'
expect allow 'git push origin chore/x'
expect allow "rg -n 'git tag -d' scripts"
got="$(printf '{"tool_input":{"command":"git tag -d v0.3.10"}}' | "$hook" 2>&1)"
[[ "$got" == *scripts/tag-release.sh* ]] ||
  { echo "FAIL: the tag block message does not name scripts/tag-release.sh: $got"; failures=$((failures + 1)); }
fi # guardrails-tag
if case_block guardrails-rules; then
# A pull request merges only through scripts/land.sh: each merge form in the Bash command text
# blocks, and the block message names that script. The reads and the land command pass.
expect block 'gh pr merge --auto --rebase 3'
expect block 'cd x && gh pr merge 3'
expect block 'gh pr merge'
expect block 'gh api -X PUT repos/o/r/pulls/3/merge'
expect block 'gh api repos/o/r/pulls/3/merge --method PUT'
expect block 'gh api repos/o/r/pulls/3/merge --method=PUT'
expect block 'gh api repos/o/r/pulls/3/merge -XPUT -f merge_method=squash'
expect block 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block 'gh api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }" | cat; echo done'
expect block $'gh api graphql -f query=\'mutation {\n  mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId }\n}\''
expect block "gh alias set m 'pr merge'"
expect allow 'gh pr view 3 --json state'
expect allow 'gh api repos/o/r/pulls/3'
expect allow 'gh api repos/o/r/pulls/3/merge'
expect allow 'gh api repos/o/r/pulls/3/merge --jq .merged'
expect allow 'gh pr list --state merged'
expect allow 'gh alias set v "pr view"'
expect allow 'scripts/land.sh "t" pr.md'
# The route itself never blocks: a land title or a commit message may hold merge words. A command
# after the route in the chain, and a substitution in the text, still block.
expect allow 'scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow './scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow 'cd x && scripts/land.sh "fix(land): retry gh pr merge after a 502" pr.md'
expect allow 'scripts/land.sh "docs: gh api mergePullRequest" pr.md'
# A repo flag of gh (-R, --repo) before or after the command word still runs the same merge.
expect block 'gh pr -R o/r merge 3'
expect block 'gh pr -Ro/r merge 3'
expect block 'gh -R o/r pr merge 3'
expect block 'gh --repo=o/r pr merge 3'
expect block 'gh --repo o/r pr merge --auto --rebase 3'
expect block 'gh pr --repo o/r merge'
expect block 'gh -R o/r pr --repo=o/r merge 3'
expect block 'cd x && gh -R o/r pr merge 3'
expect block 'gh -R o/r api repos/o/r/pulls/3/merge -X PUT'
expect block 'gh --repo o/r api repos/o/r/pulls/3/merge --method PUT'
expect block 'gh -R o/r api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block 'gh --repo=o/r api graphql -f query="mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
expect block "gh -R o/r alias set m 'pr merge'"
expect allow 'gh pr list --search merge'
expect allow 'gh -R o/r pr list --search merge'
expect allow 'gh pr -R o/r view 3'
expect allow 'gh --repo o/r api repos/o/r/pulls/3/merge'
expect allow 'git commit -m "fix(land): retry gh pr merge after a 502"'
expect allow 'git -C ../wt commit -m "docs: gh alias set m pr merge"'
expect block 'scripts/land.sh "t" pr.md && gh pr merge 3'
expect block 'git commit -m x; gh pr merge 3'
expect block 'gh pr merge 3 && scripts/land.sh "t" pr.md'
expect block 'scripts/land.sh "$(gh pr merge 3)" pr.md'
expect block 'git commit -m "`gh pr merge 3`"'
expect allow 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh "t" .scratchpads/runs/r/pr.md'
got="$(printf '{"tool_input":{"command":"gh pr merge 3 --rebase"}}' | "$hook" 2>&1)"
[[ "$got" == *scripts/land.sh* ]] ||
  { echo "FAIL: the merge block message does not name scripts/land.sh: $got"; failures=$((failures + 1)); }
[[ "$got" != *'Write tool'* ]] ||
  { echo "FAIL: the merge block message talks about the Write tool: $got"; failures=$((failures + 1)); }
got="$(printf '{"tool_input":{"command":"git reset --hard"}}' | "$hook" 2>&1)"
[[ "$got" == *'Write tool'* ]] ||
  { echo "FAIL: another block message lost its Write tool line: $got"; failures=$((failures + 1)); }
# One segment of a chained command must not match a pattern with a word of the next segment.
expect allow 'git push -u origin feat/x && gh pr create --base main --title x'
expect allow 'git commit -F .scratchpads/commit-msg.txt; sed -n 1p file'
expect allow 'git commit -F .scratchpads/commit-msg.txt && sed -n 1p file'
expect allow 'git push -u origin feat/x || gh pr view --json baseRefName | grep main'

# A commit in one command with make check runs only after a green check: only && joins them.
expect block 'make check > log 2>&1; echo "exit $?"; git commit -m "x"'
expect block 'make check || true && git commit -m "x"'
expect block 'make check | tail -3 && git commit -m "x"'
expect block $'make check\ngit commit -m "x"'
expect allow 'scripts/with-lock.sh make check && git commit -m "x"'
expect allow 'git add a && scripts/with-lock.sh make check > log 2>&1 && grep -c ok log && git commit -F .scratchpads/commit-msg.txt'
expect allow $'scripts/with-lock.sh make check > log 2>&1 \\\n  && git commit -m "x"'
# The regex matches make check as a prefix, so make check-changed gets the same rule.
expect block 'make check-changed; git commit -m "x"'
expect allow 'scripts/with-lock.sh make check-changed > log 2>&1 && git commit -m "x"'
# The inner-commit check of a slice: FILTER is test names with spaces between them.
expect allow "scripts/with-lock.sh make check-changed FILTER='ClipTests TrackTests' > log 2>&1 && git commit -F .scratchpads/commit-msg.txt"
# Only the check-changed recipe writes the pass stamp. A direct write skips the land check.
expect block 'echo abc >> .git/dirigible-check-stamp'
expect block 'cp x "$(git rev-parse --git-path dirigible-check-stamp)"'
expect block 'scripts/check-stamp.sh write abc clean def check'
expect block 'bash scripts/check-stamp.sh  write abc clean def check'
expect allow 'scripts/check-stamp.sh read origin/main'
expect allow 'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/check-stamp.test.sh'
# Only a passing make test-slow or test-slow-push writes the slow-run date. A direct write skips the daily slow run.
expect block 'date +%F > .git/dirigible-slow-date'
expect block 'echo 2026-01-01 > "$(git rev-parse --git-common-dir)/dirigible-slow-date"'
expect allow 'scripts/with-lock.sh make test-slow'
expect allow 'scripts/with-lock.sh make test-slow-push'
# expect_each_write <path>: each form of one shared list of writes blocks on <path>. A rule that
# guards a file allows a list of read forms and blocks all other forms (a list of write forms
# missed sed -i, dd of=, and a variable), so a new write form goes in this list once and runs for
# each guarded file. @P@ is the path.
write_forms=(
  'rm @P@' 'rm -r @P@' 'mv @P@ /tmp/x' 'cp x @P@' 'truncate -s 0 @P@' 'touch @P@' 'ln -sf x @P@'
  ': > @P@' 'echo x > @P@' 'echo x >> @P@' 'echo x>>@P@' 'echo x 2>> @P@' 'echo x >| @P@'
  'echo x | tee @P@' 'echo x | tee -a @P@' 'printf x >"@P@"' "printf x > '@P@'" 'cat x > @P@'
  "sed -i '' 1d @P@" 'sed 1d @P@' "sed -n -i '' 1d @P@" "perl -i -pe 's/1/2/' @P@"
  'dd if=/dev/null of=@P@' 'sort -o @P@ x' "awk '{ print > \"@P@\" }' x" 'f=@P@; : > "$f"'
  "python3 -c 'open(\"@P@\", \"w\")'"
)
# A command that names a guarded path must hold only reads: a variable or a pipe must not carry
# the path to a segment that writes or runs a program.
write_forms+=(
  'f=@P@; rmdir "$f"' 'f=@P@; mkdir "$f"' 'f=@P@; rm -rf "$f"' 'f=@P@; mv "$f" /tmp/x'
  'f=@P@; g=$f; rm "$g"' 'f=@P@; for x in "$f"/*; do rm "$x"; done'
  'f=@P@; for x in "$f"/*; do echo y > "$x"; done' "f=@P@ bash -c 'rmdir \"\$f\"'"
  'f=$(rm -rf @P@); echo "$f"' "f=@P@; printf '%s\n' \"\$f\" | xargs rmdir"
  'ls -d @P@ | xargs rmdir' 'cat @P@/pid | xargs kill' 'ls @P@ & rmdir @P@'
  'cat $(rmdir @P@)/x' 'cat `rmdir @P@`/x'
  'f=@P@; for x in "$f"/*; do echo "$x"; done; rmdir "$x"' 'f=@P@; X=f; rmdir "${!X}"'
  "f=@P@; export f; python3 -c 'import os; os.rmdir(os.environ[\"f\"])'"
  "f=@P@; declare -x f; python3 -c 'import os; os.rmdir(os.environ[\"f\"])'"
  'ls @P@ && make test'
  'cd /x && rmdir @P@' 'cd /x > f && ls @P@' 'cd /x /y && ls @P@' 'cd /x && N=$(rmdir @P@) && ls @P@'
  'PATH=/tmp/x && ls @P@' 'N=1 rmdir @P@'
  'path=/tmp/x && ls @P@' 'cdpath=/x && ls @P@' 'ld_library_path=/x && ls @P@'
)
read_forms=(
  'ls @P@ | wc -l' 'cat @P@/* | grep pid' 'ls @P@ 2>/dev/null | head -3' 'ls @P@ 2>&1 | tail -2'
  'cat @P@ && echo ok' 'f=@P@; [ -d "$f" ] && echo present || echo absent'
  'f=@P@; test -d "$f" && cat "$f"/pid' 'for x in @P@/*; do cat "$x"; done'
  'f=@P@; for x in "$f"/*; do echo "$x: $(cat $x)"; done'
  'cd /x && ls @P@' 'cd /x && cat @P@/tree' 'N=1 && ls @P@' 'cd /x && N=a/b.c:1 && ls @P@ | wc -l'
)
expect_each_write() {
  local form
  for form in "${write_forms[@]}"; do expect block "${form//@P@/$1}"; done
}
expect_each_read() {
  local form
  for form in "${read_forms[@]}"; do expect allow "${form//@P@/$1}"; done
}

# Only run-checks.sh appends to the flakes file and only land.sh removes its lines, so a flake row
# cannot be erased between the push check and the land.
expect block 'rm "$(git rev-parse --git-common-dir)/dirigible-flakes"'
expect allow 'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/run-checks.test.sh'
expect allow 'scripts/run-checks.sh --flakes'
# Each simple command that names the flakes file must be a read: a read tool first, no -i, and no
# redirect into the name (quotes and a $(...) path too). A grep whose quoted pattern holds a > is
# a read (the path of a redirect stops at * and [). All else blocks.
expect_each_write .git/dirigible-flakes
# More read tools: git grep, rg, sort (no -o), grep -i, sed -n (no -i), awk (no redirect). A \|
# in a quoted grep pattern does not split the command.
expect allow 'git grep -n dirigible-flakes'
expect allow 'rg dirigible-flakes scripts'
expect allow 'sort .git/dirigible-flakes'
expect allow 'grep -i x .git/dirigible-flakes'
expect allow 'sed -n 1p .git/dirigible-flakes'
expect allow "awk '{ print \$1 }' .git/dirigible-flakes"
expect allow "grep -n 'land\\|dirigible-flakes' scripts/run-checks.sh"
# A folder path with no .git in it (a worktree named dirigible-flakes) is not the file: the past
# commands of probe-u1/commands.txt stay allowed.
expect allow 'git worktree add -b fix/flakes-and-upkeep ../dirigible-flakes main 2>&1 | tail -1'
expect allow 'cd /Users/x/projects/dirigible-flakes && git status --porcelain'
expect allow 'git -C ../dirigible-flakes status --porcelain && git worktree remove ../dirigible-flakes'
expect allow "R=.scratchpads/runs/2026-10-05-flakes-2/run.md && sed -n 1p \$R"
expect allow 'cd /Users/x/projects/dirigible-flakes2 && git status --porcelain'
expect allow 'git -C ../dirigible-flakes2 status --porcelain && git worktree remove ../dirigible-flakes2'
expect block ': > "$(git rev-parse --git-common-dir)/dirigible-flakes"'
expect block 'echo x >> "$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-flakes"'
expect block 'echo x >> "$d"/dirigible-flakes'
expect block 'printf x "$a">"$d/dirigible-flakes"'
expect allow 'grep -n dirigible-flakes .claude/hooks/git-guardrails.sh'
# Only run-checks.sh appends to the partial stamp file, so a hand-written line cannot narrow a
# push check to a rerun of chosen tests. A read is allowed.
expect_each_write .git/dirigible-check-partial
expect block 'echo abc base failed fast:a slow: >> "$(git rev-parse --git-common-dir)/dirigible-check-partial"'
expect allow 'cat .git/dirigible-check-partial'
expect allow 'grep -c failed .git/dirigible-check-partial'
expect allow 'cat .git/dirigible-flakes'
expect allow 'grep -c x .git/dirigible-flakes > /tmp/count.txt'
expect allow "grep -n '>.*dirigible-flakes' .claude/hooks/git-guardrails.sh"
expect allow 'grep -n ">.*dirigible-flakes" .claude/hooks/git-guardrails.sh'
expect allow "grep -n ' >.*dirigible-flakes' .claude/hooks/git-guardrails.sh"
# A quoted ; or & splits the command, so that grep blocks. The body of a cat sink is data.
expect block "grep -nE 'x >[[:space:]]*[^;&|]*dirigible-flakes' .claude/hooks/git-guardrails.sh"
expect allow $'cat >> scripts/run-checks.test.sh <<\'EOF\'\nflakes="$tmp/dirigible-flakes"\nEOF'
# Only run-checks.sh writes and removes the run marks that the pre-commit hook reads, so an agent
# cannot clear a mark to commit during a check. A read of the marks is allowed.
expect_each_write .git/dirigible-check-running/5
expect block 'rm -r .git/dirigible-check-running'
expect block 'mv .git/dirigible-check-running /tmp/x'
expect block ': > "$(git rev-parse --git-dir)/dirigible-check-running/5"'
expect block 'echo 1 >> "$(git rev-parse --path-format=absolute --git-dir)/dirigible-check-running/5"'
expect block 'echo 1 >> "$d"/dirigible-check-running/5'
expect block 'printf 1 "$a">"$d/dirigible-check-running/5"'
# A subagent never runs a lock wait with no limit: WITH_LOCK_MAX_WAIT=0, a land, a push check (a
# BASE= word, or BASE in the environment), the hooks pass, make dmg, or a mutation pass, also inside bash -c and
# sh -c. After a second exit 75 it writes the remaining locked steps as one bash file and returns
# its path to the lead. The lead runs the wait, so the input with no agent_id allows each form.
unlimited_forms=(
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed'
  'WITH_LOCK_MAX_WAIT=00 scripts/with-lock.sh make check-changed'
  'export WITH_LOCK_MAX_WAIT=0; scripts/with-lock.sh make x'
  'env WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make x'
  '(WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed) &'
  'scripts/with-lock.sh scripts/land.sh "feat: x" .scratchpads/body.md'
  'scripts/with-lock.sh make check-changed BASE=origin/main'
  'scripts/with-lock.sh make check-changed FILTER=ATests BASE=origin/main'
  'scripts/with-lock.sh make BASE=origin/main check-changed'
  'BASE=origin/main scripts/with-lock.sh make check-changed'
  'export BASE=origin/main; scripts/with-lock.sh make check-changed'
  'scripts/with-lock.sh make dmg'
  'cd /x && scripts/with-lock.sh make dmg'
  '(scripts/with-lock.sh make dmg) &'
  'scripts/with-lock.sh .claude/skills/deliver/scripts/mutation-pass.sh /tmp/tree /tmp/batch'
  '.claude/skills/deliver/scripts/mutation-pass.sh /tmp/tree /tmp/batch'
  'bash .claude/skills/deliver/scripts/mutation-pass.sh /tmp/tree /tmp/batch'
  "bash -c 'scripts/with-lock.sh make dmg'"
  "bash -lc 'scripts/with-lock.sh make check-changed BASE=origin/main'"
  'sh -c "scripts/with-lock.sh scripts/land.sh t b"'
  "sh -c 'cd /x; scripts/with-lock.sh make dmg'"
  "sh -c 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make x'"
  "/bin/bash -c 'export WITH_LOCK_MAX_WAIT=0; scripts/with-lock.sh make x'"
  "env bash -c 'scripts/with-lock.sh make dmg'"
  'scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1'
  'DIRIGIBLE_HOOKS_ALL=1 scripts/with-lock.sh make test-hooks'
  'scripts/with-lock.sh make check-changed BASE="origin/main"'
  "scripts/with-lock.sh make check-changed BASE='origin/main'"
  'scripts/with-lock.sh make check-changed BASE="$(git merge-base HEAD origin/main)"'
  'scripts/with-lock.sh make "check-changed" BASE=origin/main'
  'scripts/with-lock.sh make "dmg"'
  'scripts/with-lock.sh bash scripts/land.sh t b.md'
  'scripts/mutation-pass.sh; echo hi'
  'scripts/mutation-pass.sh|tee log'
  'scripts/mutation-pass.sh&'
  '(scripts/mutation-pass.sh)'
)
for form in "${unlimited_forms[@]}"; do
  expect_agent block "$form"
  grep -q 'return to the lead' "$tmp/agent.err" || { echo "FAIL: the subagent block says nothing of the lead: $form"; failures=$((failures + 1)); }
  grep -q 'one bash file' "$tmp/agent.err" && grep -qF 'WITH_LOCK_MAX_WAIT=0 bash' "$tmp/agent.err" \
    || { echo "FAIL: the subagent block names no bash file or no lead command: $form"; failures=$((failures + 1)); }
  expect allow "$form"
done
expect_agent allow 'WITH_LOCK_MAX_WAIT=120 scripts/with-lock.sh make x'
expect_agent allow 'scripts/with-lock.sh make check-changed'
expect_agent allow 'scripts/with-lock.sh make check-changed FILTER=ATests'
expect_agent allow 'scripts/with-lock.sh make test-filter FILTER=ATests'
expect_agent allow 'scripts/with-lock.sh make check-changed BASE='
expect_agent allow "bash -c 'scripts/with-lock.sh make check-changed'"
expect_agent allow "rg -n 'WITH_LOCK_MAX_WAIT=0' AGENTS.md"
expect_agent allow "rg -n 'with-lock.sh make dmg' AGENTS.md"
expect_agent allow "echo 'scripts/with-lock.sh make dmg'"
expect_agent allow 'git commit -m "docs: say scripts/with-lock.sh make dmg is for the lead"'
expect_agent allow 'scripts/land.sh --help'
expect_agent allow 'scripts/with-lock.sh make check-changed FILTER="a dmg"'
# The subagent rule reads release_segments on the masked text, so a release text in a quote is data.
expect_agent allow 'echo "(scripts/with-lock.sh make check-changed BASE=origin/main)"'
expect_agent allow "echo 'x; scripts/with-lock.sh make dmg'"
# Only scripts/with-lock.sh takes and removes the build lock, after its own take: a hand-written
# mkdir and rmdir chain removed the lock of another agent three times. A read is allowed.
expect_each_write .git/dirigible-build.lock
expect block 'mkdir .git/dirigible-build.lock && make test; rmdir .git/dirigible-build.lock'
expect block 'rmdir "$(git rev-parse --git-common-dir)/dirigible-build.lock"'
expect block 'rm -rf /Users/x/repo/.git/dirigible-build.lock'
expect allow 'ls .git/dirigible-build.lock'
expect allow 'cat .git/dirigible-build.lock/pid .git/dirigible-build.lock/command'
# Only scripts/with-lock.sh writes and removes the timing markers and the lock-free call files: a
# hand-written remove lets a lock-free call run during a timing. A read is allowed.
expect_each_write .git/dirigible-bench-marks/5
expect_each_write .git/dirigible-lock-free/5
expect block 'rm -rf "$(git rev-parse --git-common-dir)/dirigible-bench-marks"'
expect block 'rm -f /Users/x/repo/.git/dirigible-lock-free/*'
expect allow 'ls .git/dirigible-bench-marks'
expect allow 'cat .git/dirigible-lock-free/5'
# Only scripts/verify-copy.sh start takes the screen lock and stop removes it: a hand-written
# remove freed the screen for a second verify copy. A read is allowed.
expect_each_write .git/dirigible-screen
expect block 'rm -rf "$(git rev-parse --git-common-dir)/dirigible-screen"'
expect allow 'ls .git/dirigible-screen'
expect allow 'cat .git/dirigible-screen/root .git/dirigible-screen/pid'
# Only scripts/test-hooks.sh appends to the hooks pass stamp, after a pass of the whole list, so
# a Bash command cannot write it to skip the hook tests. A read is allowed.
expect_each_write .git/dirigible-hooks-stamp
expect block 'echo k >> "$(git rev-parse --git-common-dir)/dirigible-hooks-stamp"'
expect block 'rm .git/dirigible-hooks-stamp'
expect block "sed -i '' 1d .git/dirigible-hooks-stamp"
expect allow 'cat .git/dirigible-hooks-stamp'
expect allow 'grep -c . "$(git rev-parse --git-common-dir)/dirigible-hooks-stamp"'
# Each guarded path allows the read forms of one shared list.
for guarded in .git/dirigible-flakes .git/dirigible-check-partial .git/dirigible-check-running/5 \
  .git/dirigible-build.lock .git/dirigible-screen .git/dirigible-hooks-stamp \
  .git/dirigible-bench-marks/5 .git/dirigible-lock-free/5; do
  expect_each_read "$guarded"
done
# A plain assignment must not let a read tool run another program: these names block.
for name in PATH IFS ENV BASH_ENV CDPATH SHELLOPTS LD_PRELOAD DYLD_INSERT_LIBRARIES GIT_PAGER \
  RIPGREP_CONFIG_PATH HOME PAGER; do
  expect block "$name=x && ls .git/dirigible-build.lock"
done
# A loop over the lock files, a test of the lock, and a quoted pattern with a pipe are reads.
expect allow 'L=.git/dirigible-build.lock; [ -d "$L" ]'
expect allow 'L=.git/dirigible-build.lock; test -d "$L" && cat "$L"/pid'
expect allow 'L=$(git rev-parse --git-common-dir)/dirigible-build.lock; for f in "$L"/*; do echo "$f: $(cat $f)"; done'
expect allow 'for f in .git/dirigible-build.lock/*; do cat "$f"; done'
expect allow $'wc -l .claude/hooks/git-guardrails.sh .claude/hooks/git-guardrails.test.sh; rg -n -i \'heredoc|here-doc|<<|LOCKED_SCRIPT|hooksPath|reads_only|dirigible-build.lock|tccutil|screencapture|\\-F|--file|\\.index\\(|flakes|pass-stamp|commit-after|log-decision\' .claude/hooks/git-guardrails.sh | cut -c1-220'
# A hand-set reuse value would run a build beside the holder of the lock.
expect block 'DIRIGIBLE_BUILD_LOCK=123 scripts/with-lock.sh make test'
expect block 'DIRIGIBLE_LOCKED_SCRIPT=scripts/bench.sh scripts/bench.sh X'
expect allow 'scripts/with-lock.sh make test'
expect allow "grep -n '>.*dirigible-check-running' .claude/hooks/git-guardrails.sh"
expect allow 'ls .git/dirigible-check-running'
expect allow 'cat .git/dirigible-check-running/5'
expect allow 'grep -r x .git/dirigible-check-running'
# The block message of the flakes file names its read route.
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string 'echo x >> .git/dirigible-flakes' "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == *'read it with scripts/run-checks.sh --flakes'* ]] ||
  { echo "FAIL: the flakes block message names no read route: $message"; failures=$((failures + 1)); }
expect allow 'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/check-changed.test.sh'

# The body of a heredoc that goes to a file (cat or tee, a plain file) is data: no rule reads it. The
# marker ends the first line, or only a redirect to a plain file follows it, and an exact end line
# follows the body. All else keeps the body in the text: a pipe, bash, an inline text, a here-string.
sink_bodies=(
  'x=1 DIRIGIBLE_LOCKED_SCRIPT="$0" exec'
  $'make lint; echo\n.claude/skills/deliver/scripts/log-decision.sh r 4 a b c d'
  'git -c core.hooksPath=/dev/null commit -m x'
  'git push origin main'
  'rm .git/dirigible-flakes'
  'echo k >> .git/dirigible-check-stamp'
)
for body in "${sink_bodies[@]}"; do
  expect allow $'cat > f <<\'EOF\'\n'"$body"$'\nEOF'
  expect allow $'tee f <<\'EOF\'\n'"$body"$'\nEOF'
  expect allow $'cat <<\'EOF\' > f\n'"$body"$'\nEOF'
  expect block $'bash <<EOF\n'"$body"$'\nEOF'
done
expect allow $'cat >> f <<-EOF\n\tgit reset --hard\n\tEOF'
expect allow $'tee -a f <<\'EOF\'\ngit push origin main\nEOF'
expect allow $'cat <<\'EOF\' > f\ngit reset --hard\nEOF'
# An unquoted marker expands $(...) and backticks in the body, so the shell runs them.
expect block $'cat > f <<EOF\n$(git reset --hard)\nEOF'
expect block $'cat > f <<EOF\n`git reset --hard`\nEOF'
expect allow $'cat > f <<\'EOF\'\n$(git reset --hard)\nEOF'
# No sink: the body stays in the text.
expect block $'cat <<\'EOF\' | bash\ngit push --force origin main\nEOF'
expect block $'tee f <<EOF | sh\ngit reset --hard\nEOF'
expect block $'cat > f <<EOF; git reset --hard\nx\nEOF'
expect block $'cat > f <<EOF\nx\nEOF\ngit reset --hard'
expect block $'cat > f <<EOF\ngit reset --hard'
expect block $'cat > f <<A && bash <<B\nx\nA\ngit reset --hard\nB'
expect block $'cat > >(bash) <<EOF\ngit reset --hard\nEOF'
expect block $'tee >(sh) <<EOF\ngit reset --hard\nEOF'
expect block $'bash <<-EOF\n\tgit reset --hard\n\tEOF'
expect block $'bash <<< \'git reset --hard\''
expect block $'cat <<< \'git reset --hard\' | sh'
expect block $'cat <<EOF > f; git reset --hard\nx\nEOF'
expect block $'cat <<EOF > f | sh\ngit reset --hard\nEOF'
expect block $'cat <<EOF > >(sh)\ngit reset --hard\nEOF'
expect block $'cat > f <<EOF\ngit reset --hard\nEOF x'
# An interpreter heredoc is read as a program. The command-shape rules (lock-value, log-decision,
# commit after make check, push, commit message file, hook test run) skip its body when it names no
# process call. The hooks-path rule and the file-guard rules read it, so python3 can not remove the
# lock, write a stamp, or change the hooks path.
expect allow $'python3 - <<\'EOF\'\n'"${sink_bodies[0]}"$'\nEOF'
expect allow $'python3 <<\'EOF\'\n'"${sink_bodies[1]}"$'\nEOF'
expect allow $'python3 - <<\'EOF\'\n'"${sink_bodies[3]}"$'\nEOF'
for body in "${sink_bodies[2]}" "${sink_bodies[@]:4}"; do
  expect block $'python3 - <<\'EOF\'\n'"$body"$'\nEOF'
done
for name in dirigible-check-stamp dirigible-slow-date dirigible-flakes dirigible-check-partial \
  dirigible-check-running dirigible-build.lock dirigible-screen dirigible-hooks-stamp \
  dirigible-bench-marks/5 dirigible-lock-free/5; do
  expect block $'python3 - <<\'EOF\'\nimport os\nos.remove(".git/'"$name"$'")\nEOF'
done
expect block $'python3 - <<\'EOF\'\nimport os\nos.rmdir(".git/dirigible-build.lock")\nEOF'
expect block $'python3 - <<\'EOF\'\nopen(".git/dirigible-check-stamp", "a").write("x")\nEOF'
expect block $'python3 - <<\'EOF\'\nopen(".git/dirigible-flakes", "a").write("x")\nEOF'
expect block $'node - <<\'EOF\'\nrequire("fs").rmdirSync(".git/dirigible-build.lock")\nEOF'
expect block $'perl <<\'EOF\'\nrmdir ".git/dirigible-build.lock";\nEOF'
expect block $'ruby <<\'EOF\'\nDir.rmdir(".git/dirigible-build.lock")\nEOF'
expect block $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run("make check; git commit -m x", shell=True)\nEOF'
expect block $'bash <<EOF\nmake check; git commit -m x\nEOF'
expect block "python3 -c 'import os; os.rmdir(\".git/dirigible-build.lock\")'"
expect block "node -e 'require(\"fs\").rmdirSync(\".git/dirigible-build.lock\")'"
expect block "perl -e 'rmdir \".git/dirigible-build.lock\"'"
expect block "ruby -e 'Dir.rmdir(\".git/dirigible-build.lock\")'"
# After a prefix, a cat, tee, or python3 - body is data as without the prefix. The prefix is a run
# of segments, each ended by ; or &&: NAME=<word> assignments with no name PATH, cd <word>, or
# mkdir -p <word>.... A PATH assignment, export, mkdir with no -p, another command, a bash body, an
# unquoted marker with $( in the body, and a python3 body that pushes main block.
expect allow $'cd /x && cat > f.txt <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect allow $'cd /x && tee f.txt <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect allow $'cd /x && cat > f.txt <<\'EOF\'\ngit push origin main\nEOF'
expect allow $'cd /x && python3 - <<\'EOF\'\ns = \'DIRIGIBLE_LOCKED_SCRIPT="$0" exec\'\nEOF'
expect allow $'cd /x; cat > f.txt <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect allow $'L=x; python3 - <<\'EOF\'\ns = \'DIRIGIBLE_LOCKED_SCRIPT="$0" exec\'\nEOF'
expect allow $'L=x; cat > f.txt <<\'EOF\'\ngit push origin main\nEOF'
co=$'\ngit checkout .\nEOF'
for run in "L=x; cat > row-s1.txt <<'EOF'" "L=x && cat > row-s1.txt <<'EOF'" "mkdir -p rows && tee rows/a.txt <<'EOF'" \
  "mkdir -p a b && cd a && L=x; tee f.txt <<'EOF'" "L=x; cd \$(pwd)/a && cat > f.txt <<'EOF'" \
  "cd \$(pwd) && cat > f.txt <<'EOF'" "MYPATH=1; cat > f.txt <<'EOF'"; do
  expect allow "$run$co"
done
for run in "L=x; bash <<'EOF'" "PATH=stub:\$PATH; cat > f.txt <<'EOF'" "L=x PATH=stub:\$PATH; cat > f.txt <<'EOF'" \
  "L=x; PATH=stub; cat > f.txt <<'EOF'" "export L=x; cat > f.txt <<'EOF'" "mkdir stub; cat > stub/f.txt <<'EOF'" \
  "rm -rf x; cat > f.txt <<'EOF'" "path=stub; cat > f.txt <<'EOF'"; do
  expect_message "matches 'git (checkout|restore)" "$run$co"
done
expect_message "matches 'git (checkout|restore)" $'git checkout .; cat > f.txt <<\'EOF\'\nx\nEOF'
expect_message 'runs a repo hook test outside the key tree' $'L=x; cat > f.txt <<EOF\n$(bash scripts/land.test.sh)\nEOF'
expect_message "matches 'git push .*" $'L=x; python3 - <<\'EOF\'\nimport os; os.system(\'git push origin main\')\nEOF'
expect block $'cd /x && bash <<\'EOF\'\nDIRIGIBLE_LOCKED_SCRIPT="$0" exec\nEOF'
expect block $'cd /x && cat > f.txt <<EOF\nDIRIGIBLE_LOCKED_SCRIPT=$(date) exec\nEOF'
expect block $'cd /x && python3 - <<\'EOF\'\nimport os; os.system(\'git push origin main\')\nEOF'

# A text rule of osascript must hold for each shell form, not only for the forms that a gate found
# one at a time (run 2026-10-08-upkeep-batch-6). expect_each_form <want> <line>... runs one
# AppleScript body (one argument for each line) as: one -e for each line, all lines in one -e, a
# heredoc, one -e with escaped double quotes, the first form in upper case, and the first form
# with a tab and doubled spaces. A line must not hold a single quote.
expect_each_form() {
  local want="$1" line parts="" body=""
  shift
  for line in "$@"; do parts+=" -e '$line'"; body+="$line"$'\n'; done
  body="${body%$'\n'}"
  expect "$want" "osascript$parts"
  expect "$want" "osascript -e '$body'"
  expect "$want" "osascript <<EOF"$'\n'"$body"$'\n'"EOF"
  expect "$want" "osascript -e \"${body//\"/\\\"}\""
  expect "$want" "$(tr '[:lower:]' '[:upper:]' <<<"osascript$parts")"
  expect "$want" "osascript"$'\t'"$(sed 's/ /  /g' <<<"${parts# }")"
}

# A new Finder window opens as a tab of the window group of the user, so a bounds or position
# change of a Finder window moves the windows of the user. A read, and a move of another app, pass.
expect_each_form block 'tell application "Finder" to set bounds of window 1 to {0, 0, 800, 600}'
expect_each_form block 'tell application "System Events" to set position of window 1 of process "Finder" to {0, 0}'
expect_each_form block 'tell application "Finder"' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
expect_each_form block 'tell application id "com.apple.finder" to set position of window 1 to {0, 0}'
expect_each_form block 'tell app "Finder" to set bounds of window 1 to {0, 0, 9, 9}'
expect_each_form block 'tell application "System Events" to tell process "Finder" to set position of window 1 to {0, 0}'
# The System Events form of a process tell: through the Finder rule (a).
expect_each_form block 'tell application "System Events"' 'tell application process "Finder"' 'set position of window 1 to {0, 0}' 'end tell' 'end tell'
# A set after a nested end tell is still in the Finder clause; a size change moves the group too.
expect_each_form block 'tell application "Finder"' 'tell front window' 'get name' 'end tell' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
expect_each_form block 'tell application "System Events" to set size of window 1 of process "Finder" to {9, 9}'
expect_each_form block 'tell application "Finder" to set size of window 1 to {9, 9}'
# A read of the Finder window through System Events, then a move of the verify copy, passes.
expect allow "osascript -e 'tell application \"System Events\" to get name of window 1 of process \"Finder\"'; osascript -e 'tell application \"System Events\" to set position of window 1 of application process \"Dirigible\" to {0, 0}'"
expect_each_form allow 'tell application "System Events" to get position of window 1 of process "Finder"'
expect_each_form allow 'tell application "System Events" to set position of window 1 of process "Dirigible" to {900, 100}'
expect_each_form allow 'tell application "System Events"' 'set position of window 1 of process "Dirigible" to {900, 100}' 'get position of window 1 of process "Finder"' 'end tell'
expect_each_form allow 'tell application id "com.apple.systemevents" to get name of every process'
expect_each_form allow 'tell app "System Events"' 'tell application process "Dirigible"' 'get position of window 1' 'end tell' 'end tell'
expect_each_form allow 'display notification "done"'
expect allow "grep -n 'quit app \"QuickTime Player\"' notes.txt"

# An Apple Event to an app other than System Events (a tell, quit, activate, or launch) makes
# macOS show an Automation prompt for the terminal app, and the call waits until it times out.
expect_each_form block 'tell application "QuickTime Player" to get name of document 1'
expect_each_form block 'tell app "Google Chrome" to get URL of active tab of window 1'
expect_each_form block 'tell application id "com.google.Chrome" to get name of window 1'
expect_each_form block 'tell application "Finder" to get bounds of window 1'
expect_each_form block 'tell application "Finder" to set sizeKB to size of (POSIX file "/tmp/x" as alias)'
expect_each_form block 'quit app "QuickTime Player"'
expect_each_form block 'activate application "Google Chrome"'
expect_each_form block 'launch application id "com.google.Chrome"'
expect_each_form block 'tell application "System Events" to quit application "QuickTime Player"'
# A reference to another app with no tell verb sends the same Apple Event.
expect_each_form block 'set bounds of window 1 of application "Finder" to {0, 0, 9, 9}'
expect_each_form block 'run application "QuickTime Player"'
expect_each_form block 'get name of application id "com.google.Chrome"'
expect_each_form allow 'tell application "System Events" to get name of window 1 of application process "Finder"'
# The two Finder gaps that end a Finder clause early: a System Events line, and an osascript word.
expect_each_form block 'tell application "Finder"' 'tell application "System Events" to get name of every process' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
expect_each_form block 'tell application "Finder"' 'get name of file "osascript.txt" of desktop' 'set bounds of front window to {0, 0, 9, 9}' 'end tell'
# The block message names System Events and leaves the prompt to the user.
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string "osascript -e 'tell application \"QuickTime Player\" to get name of document 1'" "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == *'Automation prompt'* && "$message" == *'through System Events'* && "$message" == *'leave it'* ]] ||
  { echo "FAIL: the Apple Event block message: $message"; failures=$((failures + 1)); }
# The Finder block message gives the reason and the way, keeps the data hint, and has no git sentence.
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string "osascript -e 'tell app \"Finder\" to set bounds of window 1 to {0, 0, 9, 9}'" "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == 'BLOCKED by .claude/hooks/git-guardrails.sh: '* && "$message" == *'opens as a tab'* &&
  "$message" == *'move only the window of the verify copy'* && "$message" == *'through System Events'* &&
  "$message" == *'If the matched text is only data'* &&
  "$message" != *'deliver flow'* ]] ||
  { echo "FAIL: the Finder block message: $message"; failures=$((failures + 1)); }

# A quit by name also quits the copy of the user, with its unsaved work (AGT-120).
expect block 'killall Dirigible'
expect block 'killall -9 Dirigible'
expect block '/usr/bin/killall Dirigible'
expect block 'sudo killall Dirigible'
expect block 'make app && killall Dirigible'
expect block 'pgrep Dirigible | xargs killall'
expect block 'pkill -x Dirigible'
expect block 'pkill -9 -x Dirigible'
expect block 'pkill -ix dirigible'
expect block 'pkill -xf Dirigible'
expect block '/usr/bin/pkill -x Dirigible'
expect allow 'pkill -INT -f mutate.py'
expect allow 'pkill -TERM -f "mutation-pass.sh --run x"'
expect allow 'pkill -f "scripts/probe.sh .scratchpads/p -x"'
expect allow 'pgrep -x Dirigible'
expect allow 'kill 4242'
expect allow 'grep -n skillall notes.md'
plutil -create xml1 "$input"
plutil -insert tool_input -dictionary "$input"
plutil -insert tool_input.command -string 'killall Dirigible' "$input"
plutil -convert json "$input"
message="$("$hook" < "$input" 2>&1 >/dev/null)"
[[ "$message" == *'pgrep'* && "$message" == *'only that PID'* && "$message" != *'deliver flow'* ]] ||
  { echo "FAIL: the quit-by-name block message: $message"; failures=$((failures + 1)); }

# A privacy reset of the bundle ID of the user removes the grants of each build of the user. Only the
# ID of the verify copy (.verify-<hash>) may be reset.
expect block 'tccutil reset AudioCapture com.delineas.dirigible'
expect block 'tccutil reset All com.delineas.dirigible'
expect block 'make app && tccutil reset Microphone com.delineas.dirigible'
expect allow 'tccutil reset All com.delineas.dirigible.verify-1a2b3c4d'
expect allow 'tccutil reset Microphone com.example.other'
expect allow 'rg -n com.delineas.dirigible Package.swift'
expect allow $'cat > notes.md <<\'EOF\'\ntccutil reset All com.delineas.dirigible\nEOF'
# A reset with no bundle ID removes the grants of every app, and a bundle ID from a variable can
# name the ID of the user: both block.
expect block 'tccutil reset Microphone'
expect block 'tccutil reset All'
expect block 'tccutil reset All 2>&1'
expect block 'make app && tccutil reset Microphone && echo done'
expect block $'tccutil reset All\nls'
expect block $'id=com.delineas.dirigible; tccutil reset Microphone "$id"'
expect block 'tccutil reset Microphone "$(printf com.delineas.dirigible)"'
expect block 'tccutil reset Microphone `printf com.delineas.dirigible`'
expect allow 'tccutil reset All com.delineas.dirigible.verify-1a2b3c4d 2>&1'
expect allow $'cat > notes.md <<\'EOF\'\ntccutil reset All\nEOF'
message="$(printf '{"tool_input":{"command":"tccutil reset All"}}' | "$hook" 2>&1)"
[[ "$message" == *'scripts/verify-copy.sh'* && "$message" == *'no bundle ID'* ]] ||
  { echo "FAIL: the no-ID tccutil block message: $message"; failures=$((failures + 1)); }
message="$(printf '{"tool_input":{"command":"tccutil reset All com.delineas.dirigible"}}' | "$hook" 2>&1)"
[[ "$message" == *'scripts/verify-copy.sh'* && "$message" != *'deliver flow'* ]] ||
  { echo "FAIL: the tccutil block message names no verify copy route: $message"; failures=$((failures + 1)); }

# A quoted main is the same push to main.
expect block "git push origin 'main'"
expect block 'git push origin "main"'
expect block "git push origin HEAD:'refs/heads/main'"
expect block 'git push origin "feat/x:main"'
expect allow "git push -u origin 'feat/main-feature'"
expect allow 'git push -u origin "main-feature"'
# Any character that cannot be in a branch name ends main. Any white space separates the words.
expect block '(git push origin main)'
expect block 'git push origin main>log 2>&1'
expect block $'git push origin \\\nmain'
expect block $'git push\torigin main'
expect block $'git\tpush origin main'
expect block $'git -C\t/repo push origin main'
expect block 'git  push  origin  main'
expect block $'git push\t-f origin feat/x'
expect block 'git push origin "main":feat/x'
expect allow 'git push -u origin main-feature'
expect allow 'git push origin feat/x > main.log 2>&1'

expect_message "matches '--no-verify'" "git commit -m 'docs(agents): the hook blocks --no-verify'"
expect_message 'without &&' 'make check; git commit -m x'
# git -C <path> is the same commit for the make-check rule.
expect block 'make check-changed > log 2>&1; git -C /x/wt commit -F .scratchpads/commit-msg.txt'

# A decisions.tsv row joined after a commit or a build by ;, a newline, or a pipe can come before the
# status is read (run 2026-10-07-heap-corruption: a failed commit was logged with the old HEAD).
ld='.claude/skills/deliver/scripts/log-decision.sh r 4 a b c d'
expect block "git commit -F .scratchpads/commit-msg.txt; $ld"
expect block $'git commit -F .scratchpads/commit-msg.txt\n'"$ld"
expect block $'make\n'"$ld"
expect block "make test-filter FILTER=X > log 2>&1; $ld"
expect block "swift test; $ld"
expect block "git -C /x/wt commit -F .scratchpads/commit-msg.txt; $ld"
expect block "make test-filter FILTER=X | tail -3 && log-decision.sh r 4 a b c VERIFIED"
expect allow "git commit -F .scratchpads/commit-msg.txt && $ld"
expect allow "scripts/with-lock.sh make test-filter FILTER=X > log 2>&1 && $ld"
expect allow "scripts/with-lock.sh make test-filter FILTER=X > log 2>&1 || $ld"
expect allow "$ld"
# A background job: the row comes before make ends. A redirect with & is not a background job.
expect block "make test > log 2>&1 & $ld"
expect allow "scripts/with-lock.sh make test &> log && $ld"
expect allow "scripts/with-lock.sh make test >& log && $ld"
expect allow "$ld; make lint"
expect allow "remake; $ld"
expect allow $'make lint \\\n  && '"$ld"
# Each run of tabs and spaces is one space, as in the other rules.
expect block "git  commit -F .scratchpads/commit-msg.txt; $ld"
expect block $'make\tcheck; git commit -m x'
# A quoted path with a space after git -C.
expect block "git -C '/x y/wt' commit -F .scratchpads/commit-msg.txt; $ld"
expect block "git -C \"/x y/wt\" commit -F .scratchpads/commit-msg.txt; $ld"
expect_message 'in its own command' "swift build; $ld"
# The rule matches git commit, make, or swift only at a command start, after the prefix words
# NAME=value, time, with-lock.sh, and probe.sh <folder>. The word make in row text is data.
expect allow $'printf \'4\\twe make the row\\n\' > row.txt; .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect allow $'cat > row.txt <<\'EOF\'\n4\nwe make the row\nEOF\n.claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
# The rule fires only when log-decision.sh starts a command, so a read of the script passes.
expect allow 'git commit --amend --no-edit -q; cat .claude/skills/deliver/scripts/log-decision.sh | head -5'
expect allow 'git commit -q -m x; sed -n 1,5p .claude/skills/deliver/scripts/log-decision.sh'
expect allow 'make lint; head -3 .claude/skills/deliver/scripts/log-decision.sh'
expect block $'make check-docs\n.claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect block 'make check-docs | tee x.log; bash .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect block 'swift build & .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
expect allow 'git commit -q -m x && .claude/skills/deliver/scripts/log-decision.sh r --from row.txt'
# run.md, plan.md, and analysis.md change only with the Edit tool (AGENTS.md, Run ledger). A
# segment that names one of them and holds a write form blocks, with and without a runs path.
# A read, a -n copy or move, and the names in quoted data, a row file body, or another segment pass.
expect block $'cd .scratchpads/runs/r && sed -i \'\' \'s/a/b/\' run.md'
expect block $'python3 - <<\'EOF\'\nopen("run.md", "a").write("x")\nEOF'
expect block $'python3 - <<\'EOF\'\nopen(".scratchpads/runs/r/run.md", "a").write("x")\nEOF'
expect block $'python3 -c \'open("plan.md", "w")\''
expect block $'python3 -c \'open(".scratchpads/runs/r/plan.md", "w")\''
expect block $'node -e \'require("fs").writeFileSync("analysis.md", "x")\''
expect block $'perl -e \'open(F, ">", "analysis.md")\''
expect block $'ruby -e \'File.write("analysis.md", "x")\''
expect block $'ruby -e \'File.write(".scratchpads/runs/r/analysis.md", "x")\''
expect block $'cat >> $R/run.md <<\'EOF\'\nx\nEOF'
expect block $'cat >> run.md <<\'EOF\'\nx\nEOF'
expect block $'R=.scratchpads/runs/r/run.md; echo x >> $R'
expect block $'R=run.md; echo x >> $R'
expect block $'tee -a analysis.md < x'
expect block $'echo x | tee -a .scratchpads/runs/r/analysis.md'
expect block $'rm plan.md'
expect block $'rm -f .scratchpads/runs/r/plan.md'
expect block $'truncate -s 0 plan.md'
expect block $'dd if=x of=run.md'
expect block $'dd if=x of=.scratchpads/runs/r/run.md'
expect block $'mv x plan.md'
expect block $'mv x .scratchpads/runs/r/plan.md'
expect block $'cp x run.md'
expect block $'sed -i.bak \'s/a/b/\' run.md'
expect block $'sed --in-place \'s/a/b/\' run.md'
expect block $'sed -i \'\' \'s/a/b/\' .scratchpads/runs/r/run.md'
expect block $'echo x > analysis.md'
expect block $'perl -i -pe \'s/a/b/\' plan.md'
expect allow $'rg x run.md'
expect allow $'cat run.md'
expect allow $'head -5 plan.md'
expect allow $'tail analysis.md'
expect allow $'wc -l run.md'
expect allow $'sed -n 1,5p run.md'
expect allow $'awk \'{print}\' plan.md'
expect allow $'cp plan.md plan-0.md'
expect allow $'cp -n plan.md plan-0.md'
expect allow $'cp -n analysis.md analysis-l2-0.md'
expect allow $'mv -n analysis.txt analysis.md && test ! -e analysis.txt'
expect allow $'.claude/skills/deliver/scripts/log-decision.sh .scratchpads/runs/r 3 "plan.md changed; mv x plan.md" w e r'
expect allow $'printf \'%s\\n\' 4 "edit run.md > done" > row.txt'
expect allow $'echo "S5 changed run.md and plan.md" >> notes.txt'
expect allow $'cat > row.txt <<\'EOF\'\nanalysis.md > x; rm plan.md\nEOF'
expect allow $'python3 -I -c \'import json,sys; print(json.load(sys.stdin))\' < x.json; rg y .scratchpads/runs/r/run.md'
expect allow $'sed -i \'\' s/a/b/ notes.txt && rg x run.md'
expect allow $'rg x review-plan-1.md > out.txt'
expect allow $'echo x > plan-0.md'
expect allow $'rm run.md.bak'
expect allow $'sed -i \'\' s/a/b/ review-plan-1.md'
expect allow $'git diff --stat; rg -c x .scratchpads/runs/r/run.md'
# The first command of each section of the replay of past commands (run 2026-10-27-upkeep-fifth,
# plan gate 1): 9 block forms and 5 pass forms.
expect block $'cd /repo/.scratchpads/runs/2026-10-26-agent-transport && python3 - <<\'EOF\'\nimport pathlib\np=pathlib.Path("run.md"); t=p.read_text()\nfor a,b in [("- Requirements:\\n","- Requirements: R16 (an agent can play, stop, and locate in the running app); tester proposal wiki 0029 item 4 (user order 2026-10-18). Branch made at Phase 4 from origin/main.\\n"),\n            ("- [ ] 0 Open the run","- [x] 0 Open the run (2026-10-26 08:15; decisions.tsv phase 0 rows)")]:\n    assert t.count(a)==1; t=t.replace(a,b)\np.write_text(t)\nEOF\nls ../../tester-feedback-2026-10-16/ 2>/dev/null'
expect block $'cd /repo/.scratchpads && python3 -I - <<\'EOF\'\np="runs/2026-10-18-envelope-ducking/run.md"; s=open(p).read()\ns=s.replace("L2 and L3 wait for a lead decision with the limits read again)","L2 and L3 paused until the 7-day reset on 2026-10-21 16:00 CEST, row 16:00)",1)\ns=s.replace("## Handoff\\n\\n","## Handoff\\n\\n- Pause (2026-10-19 16:00): the 7-day use is 83 %, and L2 needs a UI panel and Opus slices, so it waits for the reset on 2026-10-21 16:00 CEST (row 16:00). Main is 81629836 with no run worktree open for this run. Next step: read `~/.claude/usage/limits.json`, then start L2 on `feat/envelope-ui` in a new worktree from main, with the plan gate rule of upkeep-3 (a review-plan file and a phase 3 row before the first phase 4 row).\\n\\n",1)\nopen(p,"w").write(s)\nEOF\nrg -n \'Pause \\(|paused until\' runs/2026-10-18-envelope-ducking/run.md | cut -c1-90\necho "2026-10-19 loop paused at 16:00: 7-day use 83 % (stop at 85 %); envelope L2 (UI panel, Opus) waits for the reset 2026-10-21 16:00 CEST. Beam-free bench done (runs/2026-10-16-agent-setup/bench/grades.md section 9); routing change is in backlog FREE LENS ROUTING." >> ledger.md'
expect block $'cd /repo/.scratchpads && python3 -I - <<\'EOF\'\np="backlog.md"; s=open(p).read().split("\\n"); k=s.index("## Later")\ns.insert(k+1,"- UPKEEP-3 GATE FOLLOW-UPS (code gate 2026-10-19, runs/2026-10-15-workflow-upkeep-3/review-diff-1.md): (a) an empty `review-plan-1.md` passes the phase 4 gate of check-x.sh; require content or an `## Act on` heading; (b) check-y.sh reads `- Branch:` from run.md (lines 170 and 182), so a missing or wrong line escapes the Lands rules; fail on a missing line or read the branch of HEAD; (c) two committers in one checkout share `.scratchpads/commit-msg.txt`; one committer at a time per checkout; (d) `git diff --name-only | grep -q` under pipefail can fail on a file list over the pipe buffer (check-y.sh lines 170 and 182).")\nopen(p,"w").write("\\n".join(s))\nEOF\nsed -n \'/^## Later/,+1p\' backlog.md | cut -c1-90'
expect block $'cd /repo; f=.scratchpads/runs/2026-10-27-armed-app-track/analysis.md; python3 -I - "$f" <<\'EOF\'\nimport sys\np=sys.argv[1]; t=open(p).read()\nold="`git diff --stat origin/main -- Sources/DirigibleAudio/Capture/CaptureRing.swift Sources/DirigibleAudio/Capture/HAL.swift` prints nothing (the IOProc, the ring, and the listeners; 0013 Callbacks)"\nnew="`git diff --stat origin/main -- Sources/DirigibleAudio/Capture/CaptureRing.swift Sources/DirigibleAudio/Capture/HAL.swift Sources/DirigibleAudio/Capture/LiveAttach.swift Sources/DirigibleAudio/Capture/DeviceList.swift Sources/DirigibleAudio/Listen` prints nothing (each file with an IOProc or a property listener; 0013 Callbacks)"\nassert t.count(old)==1; open(p,"w").write(t.replace(old,new))\nEOF\ngit diff --stat origin/main -- Sources/DirigibleAudio/Capture/CaptureRing.swift Sources/DirigibleAudio/Capture/HAL.swift Sources/DirigibleAudio/Capture/LiveAttach.swift Sources/DirigibleAudio/Capture/DeviceList.swift Sources/DirigibleAudio/Listen; echo "exit $?"'
expect block $'R=.scratchpads/runs/2026-10-20-yesyak-ideas && printf \'%s\\n\' 6 "code gate closed after round 2 fixes: Act on 1 to 3 and the 3 folded nits fixed in ce9ef97c..189bcb6d; the lead fix check found one meaning change from a word cut (deliver SKILL.md \'the run ledger\' became \'the ledger\', which names .scratchpads/ledger.md); the closing agent restores \'run\' first" "one open round (small run, no critical item); lead fix check per lead-judgment" "bash scripts/check-x.test.sh all passed (lead run); git diff b12504d2..HEAD of deliver SKILL.md and AGENTS.md read by the lead" "done" > $R/rows/g.txt && .claude/skills/deliver/scripts/log-decision.sh $R --from $R/rows/g.txt && rm $R/rows/g.txt && sed -i \'\' \'s/^- \\[ \\] 6 Code gate/- [x] 6 Code gate/\' $R/run.md && ../dirigible-yesyak/scripts/evals-for.sh --quoted origin/main 2>&1 | tail -5'
expect block $'cd /repo/.scratchpads/runs/2026-10-19-trim-past-neighbor && sed -i \'\' \'s#^- Branch: fix/trim-past-neighbor$#- Branch: fix/trim-past-neighbor\\n- Worktree: /wt (from main 7792a54d); small run, risk no, one Sonnet agent for Phases 1, 2, 4, 5#\' run.md && sed -n 1,12p run.md'
expect block $'cd /repo/.scratchpads && R=runs/2026-10-19-trim-past-neighbor/run.md && sed -i \'\' -e \'s/^- Status: open (Phases 1 to 8 done; the lead runs the push check and the cold reader, then lands)$/- Status: done (PR 164, 7792a54d..18967aea, tag v0.4.6.1)/\' -e \'s/^- \\[ \\] 9 Land and close$/- [x] 9 Land and close (2026-10-19 09:30, push check 2 exit 0 after push check 1 was killed by a T3 auto-settle; worktree removed)/\' $R && sed -i \'\' \'s/^| 2026-10-19-trim-past-neighbor | trim-past-neighbor | open | |$/| 2026-10-19-trim-past-neighbor | trim-past-neighbor | done | PR 164, v0.4.6.1 |/\' ledger.md && rg -n \'^- Status|^- \\[x\\] 9\' $R && rg -n \'trim-past-neighbor\' ledger.md | cut -c1-120'
expect block $'R=.scratchpads/runs/2026-10-16-timeline-clarity; cat >> $R/run.md <<\'EOF\'\n\n## L3 plan gate closed (2026-10-25)\n\n- review-plan-4.md (round 1: architecture and devils-advocate, 3 Act on, no critical, so no round 2). Fixes by a plan-fix agent (C24, C19 to C21, C23) and by the lead after the UI panel (C25: variant C plus a 1 pt edge, proto/l3/variants/). check-x exit 0.\n- Open risks: the dark edge 0xA8C4EA is a bright line on every clip (HIG lens noise concern), judged on screen in L3-S1; the bench budget effect of the bar and the edge runs at L3-S1 (C22).\n- Order: L3 codes before the workflow upkeep run that the last handoff put first; the upkeep run plans beside it (decisions.tsv, phase 3).\nEOF\n.claude/skills/deliver/scripts/log-decision.sh $R 3 "default: L3 Phase 4 starts before the workflow upkeep run that reflect rule 6 asks for; the upkeep run plans in the free planning slot" "the tester request goes first and its plan is refreshed and gated; the upkeep run is docs and tooling, so it plans with no build beside L3. Reverse: pause the L3 implementer at a slice commit and land the upkeep run first" "new-x.sh rule 6 count 48 upkeep items; run.md handoff of 2026-10-25" "default: L3 first"'
expect block $'cat >> plan.md <<\'EOF\'\n\n## Plan gate changes\n\nThese items override the slice text and the criteria of analysis.md where they differ (review-plan-1.md).\n\n1. S1 scope: count criterion IDs and ranges only inside `## Slices` and `## Criteria map` of plan.md. New C12 case: an Inputs line with `C1 to C3` above `## Slices`, and slices that name only C1: exit 1 with `criterion C2`. Run `probe-c8/replay2.sh` again with that scope and log the result. Criteria: C12\n2. S1 cutoff: the rule checks a run whose first decisions.tsv row (the run start) is at or after the S1 commit time, and a run with no row. The record-number cutoff keeps `first3`. New C12 case: a run with an old first row, no phase 3 row, and a missing criterion passes. C13 then holds for all 10 replay runs. Criteria: C12, C13\n3. S8: deliver Phase 0 step 2 keeps `git status --porcelain` and `git branch` in its first sentence; the resume compares the handoff "with them, the last commit, and the PR state". The C6 check becomes: step 2 has `git status --porcelain` before the resume sentence, and the resume line has `the last commit` and `the PR state`. Criteria: C6\n4. S6: the AGENTS.md words are "and a Monitor that waits until the call ends, re-armed at each expiry"; E37 (b) gets the same words. The C11 check greps `a Monitor that waits until the call ends, re-armed at each expiry`. Criteria: C11\n5. S10: after the C4 checks, commit the edit in `~/projects/agentic_stuff` on its `main` branch, one commit, a plain imperative English subject with no type prefix (that repo\'s style), no push (user, row 11:20). C4 adds: `git -C ~/projects/agentic_stuff log -1 --format=%s` prints the new subject, and its status is clean. Criteria: C4\n6. Phase 4 brief: the agent writes run files and ledger lines in the main checkout by absolute path (the run folder, `.scratchpads/backlog.md`, `.scratchpads/learnings.md`); committed text keeps no local path. Criteria: none\nEOF\ncd /repo && R=.scratchpads/runs/2026-10-20-yesyak-ideas\nw(){ printf \'%s\\n\' "$@" > $R/rows/g.txt; .claude/skills/deliver/scripts/log-decision.sh $R --from $R/rows/g.txt >/dev/null || echo "row failed: $2"; }\nw 3 "criterion change C12: S1 counts IDs and ranges only in ## Slices and ## Criteria map, with a case for an Inputs range; and the cutoff keys on the first decisions.tsv row, with a case for an old run with no phase 3 row" "plan gate 1 Act on 1 and 2: a range in the Inputs line passed every ID, and the phase 3 cutoff checked past runs with no phase 3 row" "review-plan-1.md Act on 1 and 2; 2026-10-16-diagnostics/plan.md:3; replay-2.log" "resolved: plan.md Plan gate changes items 1 and 2"\nw 3 "criterion change C13: the replay holds because the cutoff keys on the first decisions.tsv row, so no past run is checked" "plan gate 1 Act on 2: governance-later-landing and shard1-crash have no phase 3 row and miss IDs" "review-plan-1.md Act on 2" "resolved: plan.md Plan gate changes item 2"\nw 3 "criterion change C6: deliver Phase 0 step 2 keeps git status --porcelain and git branch at every session start; the resume compares the handoff with them, the last commit, and the PR state" "plan gate 1 Act on 3: the draft moved the git check into the resume branch, so a session with no open run skipped it" "review-plan-1.md Act on 3; deliver SKILL.md:23" "resolved: plan.md Plan gate changes item 3"\nw 3 "criterion change C11: the Monitor words are \'a Monitor that waits until the call ends, re-armed at each expiry\', in AGENTS.md and E37 (b)" "plan gate 1 Act on 4: no script prints an exit line; the lead arms the Monitor with its own command" "review-plan-1.md Act on 4" "resolved: plan.md Plan gate changes item 4"\nw 3 "criterion change C4: S10 ends with one commit in ~/projects/agentic_stuff, plain imperative subject, no push; C4 checks the subject and a clean status" "user at 11:20 allowed the commit there (row 11:20)" "review-plan-1.md Noted; row 2026-10-20T11:20" "resolved: plan.md Plan gate changes item 5"\nw 3 "Phase 4 brief gives absolute main-checkout paths for run files and ledger lines" "plan gate 1 Act on 5: the worktree has no .scratchpads" "review-plan-1.md Act on 5" "resolved: plan.md Plan gate changes item 6"\nw 3 "plan gate 1 closed: 5 Act on items fixed in the plan, 4 refuted findings dismissed, 0 Consider; one round (small run, no critical item)" "deliver class table: risk no, one round of two class lenses" "review-plan-1.md; workflow wf_4f98857b-2af, no missing lens" "done"\nrm $R/rows/g.txt; CHECK_PLAN_AT_PHASE4=1 scripts/check-x.sh $R; echo "exit $?"'
expect allow $'R=.scratchpads/runs/2026-10-26-agent-transport && .claude/skills/deliver/scripts/log-decision.sh $R 0 "default: goal agent-transport (MCP play, stop, locate in the app); the batch tool stays out" "tester proposal 0029 item 4 is next in the user order of 2026-10-18 after read by time (done, run 13); brief R16 names play, stop, locate; no such tool exists (MCPToolTests list). batch needs a nested edit design, so it is its own run. Reverse: plan batch first" "wiki 0029; docs/requirements/brief.md:32; Tests/DirigibleCLITests/MCPToolTests.swift toolsListHasEachTool" "default planning slot to agent-transport" && .claude/skills/deliver/scripts/log-decision.sh $R 0 "default: the architecture audit run (2026-10-15-architecture-audit) gets a plan refresh after split-stereo L1 merges" "new-x.sh: 20 product runs since the last architecture run (cadence 5); its slices move Core and Audio files that split L1 changes (NewClipFiles, flush, fades), so a parallel run gives rebase conflicts. Reverse: refresh it now and hold split L1" "new-x.sh output 2026-10-26; architecture-audit plan.md S1 to S3" "default architecture run after split L1"; sed -n 1,12p $R/run.md'
expect allow $'R=.scratchpads/runs/2026-10-23-ledger-wiki && printf \'%s\\n\' "3" "plan gate fix check: 10 of 10 pass; gate closed" "Item 6 took flock in place of rename (probe P4). Item 2 raises the class to bundle, risk no: each landing runs make check and the DMG build, and the run leaves the light path. Accepted: the classifier is decision 0028 and the push check must run the new tests. Reverse: drop the HOOK_TESTS lines and run the tests by hand." "review-plan-1.md Fix check; check-x exit 0" "pass" > $R/rowfc.txt && .claude/skills/deliver/scripts/log-decision.sh $R --from $R/rowfc.txt; sed -n 1,30p $R/run.md'
expect allow $'rg -n -i -B2 -A8 \'architecture\' docs/workflow/release-cycle.md | head -50; sed -n 1,15p .scratchpads/runs/2026-10-15-architecture-audit/run.md; rg -n \'^- \\[.\\]\' .scratchpads/runs/2026-10-15-architecture-audit/run.md'
expect allow $'git fetch -q origin && git log --oneline -1 origin/main; ls .scratchpads/runs | tail -8; echo \'---\'; R=.scratchpads/runs/2026-10-16-timeline-clarity; sed -n \'1,40p\' $R/run.md; echo \'...\'; tail -60 $R/run.md'
expect allow $'cat ~/.claude/usage/limits.json | python3 -I -c \'import json,sys; d=json.load(sys.stdin); print([(r["kind"],r["percentUsed"]) for r in d["rate_limits"]])\'; R=/repo/.scratchpads/runs/2026-10-15-workflow-upkeep-3; wc -w $R/plan.md $R/analysis.md; rg -n \'^## |^### |^- \\*\\*(T|D)[0-9]\' $R/plan.md | cut -c1-200 | head -30'
expect_message 'can write it' 'rm plan.md'
expect_message 'change it with the Edit tool' 'mv x run.md'
# A variable that the command assigns twice, or assigns a quoted value with a space, still reads
# (the guard needs no second search of the assignment). A write through it blocks.
expect allow $'F=x; F=.scratchpads/runs/r/run.md; cat "$F"'
expect allow $'F="a b/run.md"; cat "$F"'
expect block $'F=x; F=.scratchpads/runs/r/run.md; echo x >> "$F"'
expect block $'F="a b/run.md"; echo x >> "$F"'
# The read that the block message recommends passes when its pattern is a write word.
expect allow $'rg -n tee .scratchpads/runs/x/run.md'
expect allow $'rg -c truncate .scratchpads/runs/x/analysis.md'
expect allow $'rg -n "rm" plan.md'
expect block $'echo x | tee -a run.md'
expect block $'time rm run.md'
# A prefix word takes its options before the command word.
expect block $'env -i rm .scratchpads/runs/x/run.md'
expect block $'env -u X rm run.md'
expect block $'sudo -n tee .scratchpads/runs/x/run.md'
expect block $'sudo -u root rm plan.md'
expect block $'command -p rm run.md'
expect block $'nice rm run.md'
expect block $'nice -n 5 rm run.md'
expect block $'xargs -0 rm run.md'
expect block $'xargs -I{} rm .scratchpads/runs/x/run.md'
expect block $'xargs -I {} rm .scratchpads/runs/x/run.md'
expect allow $'xargs -n 1 rg -n tee .scratchpads/runs/x/run.md'
expect allow $'nice -n 5 rg -n rm .scratchpads/runs/x/run.md'
expect block $'for f in a; do rm plan.md; done'
expect block "X=1 make x; $ld"
expect block "time make x; $ld"
expect block "(make x); $ld"
# A group, a negation, a shell keyword, env, and bash also start a command.
expect block "{ make x; }; $ld"
expect block "! make x; $ld"
expect block "if make x; then $ld; fi"
expect block "while make x; do $ld; done"
expect block "for i in 1; do make x; $ld; done"
expect block "if true; then :; else make x; $ld; fi"
expect block "if true; then make x; $ld; fi"
expect block "env X=1 make x; $ld"
expect block "bash scripts/with-lock.sh make x; $ld"

# A chain rule must hold for each join form, not only for the forms that a gate found one at a time
# (run 2026-10-08-upkeep-batch-4). Each chain rule calls this helper: one block case for each join
# of <first> and <second>, and one allow case for &&. The optional <wrap> (@C@ is the chain) puts the
# chain in a context, and <want> is the verdict of the join cases there (the && case always allows).
expect_each_join() {
  local first="$1" second="$2" wrap="${3:-@C@}" want="${4:-block}" join
  for join in '; ' $'\n' ' | ' ' & ' ' > log 2>&1 & ' $'\t;\t' ';  '; do
    expect "$want" "${wrap//@C@/$first$join$second}"
  done
  expect allow "${wrap//@C@/$first && $second}"
}
for commit in 'git commit -m x' 'git -C /x/wt commit -m x' "git -C '/x y/wt' commit -m x" 'git -C "/x y/wt" commit -m x'; do
  expect_each_join 'scripts/with-lock.sh make check' "$commit"
done
for first in 'git commit -F .scratchpads/commit-msg.txt' 'git -C /x/wt commit -m x' \
  'scripts/with-lock.sh make test-filter FILTER=X' 'scripts/with-lock.sh swift test' \
  'scripts/with-lock.sh scripts/probe.sh f swift build' "scripts/with-lock.sh scripts/probe.sh '/x y/f' swift build"; do
  expect_each_join "$first" "$ld"
done

# The command-shape rules read an interpreter heredoc body with no process call as data (an edit of a
# test file that holds the trigger text), and a bash body with the same text as code. A body that names
# a process call (subprocess, child_process, Open3, system(, popen(, exec..(, spawn..(, qx, %x, a
# backtick) can run the text, so it keeps its text. The file-guard rules and the hooks-path rule read
# every body.
for lang in 'python3 -' node perl ruby; do
  data_wrap="$lang"$' <<\'EOF\'\n@C@\nEOF'
  expect_each_join 'make check' 'git commit -m x' "$data_wrap" allow
  expect_each_join 'git commit -F .scratchpads/commit-msg.txt' "$ld" "$data_wrap" allow
  expect_each_value allow msg.txt "${data_wrap//@C@/git commit @V@}" plain
done
bash_wrap=$'bash <<\'EOF\'\n@C@\nEOF'
expect_each_join 'scripts/with-lock.sh make check' 'git commit -m x' "$bash_wrap"
expect_each_value block msg.txt "${bash_wrap//@C@/git commit @V@}"
for push in 'git push origin main' 'git push --force origin feat/x' 'git push -f origin feat/x' 'git push origin +feat/x'; do
  body="open(\"t.sh\", \"a\").write(\"expect block '$push'\\n\")"
  expect allow $'python3 - <<\'EOF\'\n'"$body"$'\nEOF'
  expect allow $'cd /x && python3 - <<\'EOF\'\n'"$body"$'\nEOF'
  expect block $'bash <<\'EOF\'\n'"$push"$'\nEOF'
  expect block $'bash <<\'EOF\'\n'"$body"$'\nEOF'
  expect block $'python3 - <<\'EOF\'\nimport os\nos.system("'"$push"$'")\nEOF'
done
expect block $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run("git push --force origin feat/x", shell=True)\nEOF'
expect block $'python3 - <<\'EOF\'\nimport subprocess\nsubprocess.run(["sh", "-c", "git push origin main"])\nEOF'
expect block $'python3 - <<\'EOF\'\nimport os\nos.system("git push origin main")\nEOF'
expect block $'node - <<\'EOF\'\nrequire("child_process").execSync("git push --force")\nEOF'
expect block $'perl <<\'EOF\'\nsystem("git push origin main");\nEOF'
expect block $'ruby <<\'EOF\'\nsystem "git push origin main"\nEOF'
expect block $'ruby <<\'EOF\'\n`git push origin main`\nEOF'
expect block $'perl <<\'EOF\'\nqx{git push origin main};\nEOF'
expect block $'python3 - <<\'EOF\'\nimport os\nos.system("true")\nbash scripts/land.test.sh\nEOF'
# A printf row with the text (make check-changed ...) in a quoted string is data for the log-decision rule.
expect allow $'printf \'%s\\n\' 6 \'fix row\' \'why\' \'(make check-changed: check-docs, exit 0)\' pass > rows/r.txt; .claude/skills/deliver/scripts/log-decision.sh .scratchpads/runs/r --from rows/r.txt'
expect block $'make check-docs; printf \'%s\\n\' 6 \'fix row\' > rows/r.txt; .claude/skills/deliver/scripts/log-decision.sh .scratchpads/runs/r --from rows/r.txt'
# A python3 body that names a guarded file or a hooks path keeps exit 2.
expect block $'python3 - <<\'EOF\'\nprint(".git/dirigible-flakes")\nEOF'
expect block $'python3 - <<\'EOF\'\nprint(".git/dirigible-check-stamp")\nEOF'
expect block $'python3 - <<\'EOF\'\nprint(".git/dirigible-screen")\nEOF'
expect block $'python3 - <<\'EOF\'\nprint("git config core.hooksPath /dev/null")\nEOF'
expect block $'bash <<\'EOF\'\ngit config core.hooksPath /dev/null\nEOF'
# A search (rg, grep) that names the hooks-path key reads it; each other command that names it with a value stays a change.
expect allow "rg -n 'core.hooksPath=/dev/null' scripts/search-target.txt"
expect allow 'grep -c core.hooksPath .githooks/pre-commit'
expect allow "FOO=1 rg -n 'core.hooksPath' .githooks docs"
expect allow "cd /x && grep -rn core.hooksPath scripts"
# In a one-line search with no substitution, a separator inside a quote that closes on its line is
# part of the pattern.
expect allow "rg -n -i 'a|core.hooksPath' notes.txt"
expect allow "rg -n -i 'destructive|core.hooksPath' .claude/hooks/git-guardrails.sh docs/x.md"
expect allow "grep -E 'x|core.hooksPath' notes.txt"
expect allow 'rg -n "a|core.hooksPath" notes.txt'
expect allow "rg -n 'a;core.hooksPath' notes.txt && git status"
expect allow "rg -n 'a(core.hooksPath)' notes.txt"
expect allow $'rg -n \'it"s|core.hooksPath\' notes.txt; rg -n "it\'s|core.hooksPath" notes.txt'
# A write of the key after a separator stays blocked behind each quote form: an unclosed quote, a
# quote that spans lines, a substitution, an ANSI-C or locale quote, and a backslash before a quote.
expect block 'rg x notes.txt | git config core.hooksPath /dev/null'
expect block "rg 'a|b' notes.txt | git config core.hooksPath /dev/null"
expect block "rg 'a|b' notes.txt; git config core.hooksPath /dev/null"
expect block 'rg "a|$(git config core.hooksPath /dev/null)" notes.txt'
expect block 'rg "a|`git config core.hooksPath /dev/null`" notes.txt'
expect block 'rg a\|b notes.txt; git config core.hooksPath /dev/null'
expect block $'rg \\\' notes.txt; git config core.hooksPath /dev/null; echo \\\''
expect block "rg 'a notes.txt; git config core.hooksPath /dev/null"
expect block "rg -l 'a|core.hooksPath' | xargs git config core.hooksPath"
expect block "rg --pre 'git config core.hooksPath /dev/null' x notes.txt"
expect block $'rg \'x\' notes.txt "a"; git config core.hooksPath /dev/null'
expect block $'python3 - <<\'EOF\'\nx = \'a|b\'; os.system("git config core.hooksPath /dev/null")\nEOF'
expect block $'rg x $\'\\\'\' ; git config core.hooksPath /dev/null ; echo $\'\\\'\''
expect block $'rg x $\'\\\'\' ; git -c core.hooksPath=/dev/null commit -m x ; echo $\'\\\'\''
expect block $'rg $\'\\\'\' ; git config core.hooksPath /dev/null ; echo \'x\''
expect block $'rg \'p\n rg \' ; git config core.hooksPath /dev/null ; echo \'\''
expect block $'echo \'a\nrg \'; git config core.hooksPath /dev/null; echo \'x\ny\''
expect block $'git commit -m "a\nrg "; git config core.hooksPath /dev/null; echo "x\ny"'
expect block $'echo "a\nrg "&& git -c core.hooksPath=/dev/null commit -m x && echo "b\nc"'
expect block $'echo \'a\nrg x\' ; git config core.hooksPath /dev/null ; echo \'b\n\''
expect block 'rg "$(echo ")rg x " ; git config core.hooksPath /dev/null ; echo "(")"'
expect block 'rg "`echo "`rg x " ; git config core.hooksPath /dev/null ; echo "`"`"'
expect block 'rg x <(echo ")rg x " ; git config core.hooksPath /dev/null ; echo "(")'
expect block 'rg "${x:-"}rg x " ; git config core.hooksPath /dev/null ; echo "{"}"'
expect block 'rg x $"a" ; git config core.hooksPath /dev/null ; echo $"b"'
expect block 'rg "a\"rg x " ; git config core.hooksPath /dev/null ; echo "\""'
expect block 'git config core.hooksPath /dev/null'
expect block 'git -c core.hooksPath=/dev/null commit -m x'
expect block 'grep -l x f | xargs git config core.hooksPath'
expect block 'rg x f; git config core.hooksPath /dev/null'
expect block 'rg x f && git config core.hooksPath /dev/null'
expect block "rg --pre 'git config core.hooksPath /dev/null' x f"
expect block 'rg x $(git config core.hooksPath /dev/null)'
# AGT-153: a NAME= value with a quote, a pipe into a shell or xargs, an even backslash run before a
# new line, and a key split by quotes do not make a search line.
expect block "X='a rg ' git config core.hooksPath /dev/null"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | sh"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | bash -s"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | /bin/zsh"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | env sh"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | env -i sh"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | env A=1 bash"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | /usr/bin/env -u X sh"
expect block "rg -r 'git config core.hooksPath /dev/null' -o '^' -m1 README.md | xargs -I{} sh -c {}"
expect block $'rg -n x f \\\\\ngit config core.hooksPath /dev/null'
expect block 'git config core.hooks""Path /dev/null'
expect block 'git config core."hooksPath" /dev/null'
expect block "git config 'core.hooks'Path /dev/null"
expect block 'rg -n core.hooksPath f; git config core.hooks""Path /dev/null'
expect_message 'changes core.hooksPath (the key is split by quotes)' 'git config core.hooks""Path /dev/null'
expect allow 'FOO=1 rg -n core.hooksPath f'
expect allow 'rg -n core.hooksPath f | head -3'
expect allow "rg -n 'core.hooksPath' f | shasum"
expect allow "rg -n 'core.hooksPath' f | env -i shasum"
expect allow 'rg -n core.hooksPath f || sh -c true'
expect allow $'rg -n core.hooksPath \\\nf'
expect allow "rg -n 'core\\.hooksPath' f"
expect allow 'echo "core.hooks" "Path"'
# Each rule reads the same join: an even backslash run before a new line ends the command.
expect block $'rg -n x f \\\\\nmake build'
expect allow $'echo a \\\nb'
expect block $'echo a \\\ngit reset --hard'

for run in 'bash scripts/land.test.sh' 'make test-hooks' 'scripts/test-hooks.sh' 'scripts/with-lock.sh bash scripts/land.test.sh' \
  'scripts/with-lock.sh scripts/test-hooks.sh'; do
  expect_each_context block "$run"
  expect_each_context allow "$run"
done

# A background lock job needs a Bash timeout of 7200000 (AGENTS.md, Commands): the Bash tool stops a
# background call at 30 min by default and the result of a land, a push check, or a mutation pass is
# lost. Each lock word blocks with the flag true and a timeout below 7200000. The same commands pass
# with 7200000, with no flag, and with the flag false. Three of them also run in each shell context.
bg_jobs=(
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main'
  'scripts/with-lock.sh make test-filter FILTER=X'
  'scripts/land.sh "t" x/pr.md'
  'scripts/mutation-pass.sh wt batch.txt'
  'scripts/swift-test.sh' 'scripts/test-shards.sh' 'scripts/bench.sh Foo' 'scripts/bench-pairs.sh Foo'
  'scripts/sanitize.sh thread' 'scripts/flake-monitor/loop.sh --min-load 4 t 1 5 out' 'scripts/test-stress.sh --runs 3 out' 'scripts/with-lock.sh make build' 'scripts/with-lock.sh swift build'
  'bash .scratchpads/loop.sh' 'sh .scratchpads/loop.sh' 'zsh .scratchpads/loop.sh'
  'nohup scripts/with-lock.sh make dmg > d.log 2>&1 &' 'nice -n 5 scripts/with-lock.sh make dmg > d.log 2>&1'
)
for job in "${bg_jobs[@]}"; do
  expect block "$job" true
  expect block "$job" true 1800000
  expect block "$job" true 7199999
  expect allow "$job" true 7200000
  expect allow "$job"
  expect allow "$job" false
done
for job in 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main' 'scripts/land.sh "t" x/pr.md' 'bash .scratchpads/loop.sh'; do
  expect_each_context block "$job" true
  expect_each_context block "$job" true 1800000
  expect_each_context block "$job" true 7199999
  expect_each_context allow "$job" true
done
# The make targets that take no lock (AGENTS.md, Commands) run in the background with no timeout, alone
# or with a redirection, in each shell context. Another word after the target keeps the block.
for job in 'make check-docs' 'make check-fast' 'make lint' 'make format' 'make check-docs > x.log 2>&1' 'make lint | tail -n 5'; do
  expect allow "$job" true
  expect allow "$job" true 1800000
done
for ctx in "${context_block[@]}"; do expect allow "${ctx//@C@/make check-docs}" true; done
for job in 'make' 'make lint build' 'make check-docs > x.log check' 'make -C . lint' 'make check-changed' 'make check-docsx' 'scripts/with-lock.sh make lint'; do
  expect block "$job" true
done
expect_each_context block 'make lint build' true
expect allow 'sleep 5' true
expect allow 'rg -n with-lock.sh AGENTS.md' true
expect allow 'git status' true
expect_agent block 'scripts/with-lock.sh make test-filter FILTER=X' true
expect_agent block 'scripts/land.sh "t" x/pr.md' true 1800000
grep -q '7200000' "$tmp/agent.err" && grep -q 'AGENTS.md' "$tmp/agent.err" ||
  { echo "FAIL: the background block names no 7200000 or no AGENTS.md"; failures=$((failures + 1)); }
expect_agent allow 'scripts/with-lock.sh make test-filter FILTER=X' true 7200000
expect_agent allow 'scripts/with-lock.sh make test-filter FILTER=X'

# One background call runs one lock job: a second job can wait for the lock behind other work until the
# 2 h limit of the call stops it mid-run. Two jobs block at any timeout, also in a shell -c body and in
# each shell context; a with-lock.sh prefix and the command it runs are one job (a shell -c body too),
# and a bare bench-pairs.sh --compare and a lock-free with-lock.sh call take no lock. A single-quoted
# body joins its '\'' parts. Each release form and each form of the lead holds one job, except the
# hooks pass that runs a push check after it.
bg_two_jobs=(
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/bench.sh SessionFileBenchmark > a.log 2>&1; scripts/bench-pairs.sh /m X 3 out > b.log 2>&1'
  'scripts/with-lock.sh make check-changed BASE=origin/main > c.log 2>&1 && scripts/land.sh "t" pr.md'
  'bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/bench.sh SessionFileBenchmark > a.log 2>&1; scripts/bench-pairs.sh /m X 3 out > b.log 2>&1"'
  "(nohup sh -c 'scripts/with-lock.sh make dmg; scripts/land.sh t pr.md' > /dev/null 2>&1 &)"
  'scripts/bench.sh X > a.log; scripts/with-lock.sh scripts/bench-pairs.sh --compare out'
  'scripts/with-lock.sh bash -c "echo a > x.log"; scripts/with-lock.sh bash -c "echo b > y.log"'
  "bash -c 'echo '\\''start'\\''; scripts/with-lock.sh make dmg; scripts/land.sh t pr.md'"
  'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh f bash a.sh; scripts/with-lock.sh make dmg; scripts/land.sh t pr.md'
)
bg_one_job=(
  'scripts/bench-pairs.sh /m X 3 out > b.log 2>&1; scripts/bench-pairs.sh --compare out > c.log 2>&1'
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/bench.sh X > a.log 2>&1; scripts/bench-pairs.sh --compare out'
  'bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/bench.sh X > b.log 2>&1"'
  'scripts/mutation-pass.sh wt batch.txt > m.log 2>&1'
  '(nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=$(git merge-base HEAD origin/main) > l.log 2>&1; echo \"exit \$?\" > l.done" > /dev/null 2>&1 < /dev/null &)'
  '(nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=`git merge-base HEAD origin/main` > l.log 2>&1" &)'
  'make check-docs; make lint'
  'scripts/with-lock.sh bash -c "swift build; swift build -c release"'
  "nohup scripts/with-lock.sh bash -c 'make dmg; scripts/land.sh t pr.md' > l.log 2>&1 &"
  'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh f bash a.sh > a.log; WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh g bash b.sh > b.log'
  "scripts/with-lock.sh make test-hooks HOOK_TESTS='scripts/a.test.sh' > a.log 2>&1; scripts/with-lock.sh make test-hooks HOOK_TESTS='scripts/b.test.sh' > b.log 2>&1"
  'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh f bash a.sh > a.log; scripts/with-lock.sh make dmg > d.log 2>&1'
  "bash -c 'echo '\\''start'\\''; scripts/with-lock.sh make dmg'"
  'cd /x/wt && R=/x/run; WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/land.sh "t" $R/pr.md > $R/logs/land.log 2>&1; echo "exit $?" >> $R/logs/land.log'
  'cd /x/wt && WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main > l.log 2>&1; echo "exit $?" >> l.log'
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1 > h.log 2>&1; echo "exit $?" >> h.log'
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make dmg > d.log 2>&1' 'scripts/bench.sh X > b.log 2>&1'
  '.claude/skills/deliver/scripts/mutation-pass.sh wt batch.txt > m.log 2>&1'
)
for job in "${bg_two_jobs[@]}"; do
  expect block "$job" true 7200000
  expect block "$job" true
  expect allow "$job"
  expect allow "$job" false 7200000
done
for job in "${bg_one_job[@]}"; do expect allow "$job" true 7200000; done
expect_each_context block "${bg_two_jobs[0]}" true 7200000
expect_each_context allow "${bg_two_jobs[0]}" true 7200000
expect allow '(nohup bash -c "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main > l.log 2>&1; echo \"exit \$?\" > l.done" > /dev/null 2>&1 < /dev/null &)'
for form in "${release_forms[@]}"; do
  want=allow
  [[ "$form" == *"then WITH_LOCK_MAX_WAIT=0"* ]] && want=block
  expect "$want" "$form" true 7200000
done
expect_agent block "${bg_two_jobs[1]}" true 7200000
grep -q 'one background call per lock job' "$tmp/agent.err" ||
  { echo "FAIL: the two-job block does not say one background call per lock job"; failures=$((failures + 1)); }
# AGENTS.md states no two-job rule: the message cites the rule in the hook, and that rule exists.
if grep -q 'AGENTS.md' "$tmp/agent.err" || ! grep -qF "(see 'One background call runs one lock job' in .claude/hooks/git-guardrails.sh)" "$tmp/agent.err"; then
  echo "FAIL: the two-job block must cite the hook rule, not AGENTS.md: $(cat "$tmp/agent.err")"; failures=$((failures + 1))
fi
grep -qF '# One background call runs one lock job' "$hook" ||
  { echo "FAIL: the hook has no comment 'One background call runs one lock job'"; failures=$((failures + 1)); }

# A Bash call with no lock word makes no read of the two keys (hook latency, item 1222): a plutil shim
# first in PATH logs each call. A lock-word call reads each key once.
mkdir "$tmp/shim"
printf '#!/bin/bash\necho "$*" >> "$PLUTIL_LOG"\nexec %s "$@"\n' "$(command -v plutil)" > "$tmp/shim/plutil"
chmod +x "$tmp/shim/plutil"
expect_key_reads() {
  local command="$1" want_flag="$2" want_limit="$3" flag_reads limit_reads
  plutil -create xml1 "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert tool_input.command -string "$command" "$input"
  plutil -convert json "$input"
  : > "$tmp/plutil.log"
  PLUTIL_LOG="$tmp/plutil.log" PATH="$tmp/shim:$PATH" "$hook" < "$input" > /dev/null 2>&1
  flag_reads="$(grep -c 'tool_input.run_in_background' "$tmp/plutil.log")"
  limit_reads="$(grep -c 'tool_input.timeout' "$tmp/plutil.log")"
  [[ "$flag_reads $limit_reads" == "$want_flag $want_limit" ]] ||
    { echo "FAIL: expected $want_flag and $want_limit reads of the two keys, got $flag_reads and $limit_reads: $command"; failures=$((failures + 1)); }
}
expect_key_reads 'ls' 0 0
expect_key_reads 'git status' 0 0
expect_key_reads 'bash scripts/land.test.sh' 1 1
expect_key_reads 'scripts/with-lock.sh make test-filter FILTER=X' 1 1

# A repo hook or script test runs as scripts/with-lock.sh make test-hooks HOOK_TESTS='<names>', which
# takes no lock (header of scripts/with-lock.sh): a bare bash run of a .test.sh file ran beside three push checks
# (DLV-157/flake). Each run form after the prefix words blocks: a shell word with flags other than -n,
# or the bare path. A with-lock.sh word in the prefix does not change that (item 1375, below).
for run in 'bash scripts/with-lock.test.sh' 'bash a.test.sh & bash b.test.sh' 'bash a.test.sh; bash b.test.sh' \
  'cd ../wt && bash scripts/land.test.sh' 'scripts/land.test.sh' './scripts/land.test.sh' '../wt/scripts/land.test.sh' \
  'sh scripts/land.test.sh' '/bin/bash scripts/land.test.sh' '/bin/sh scripts/land.test.sh' 'bash -x scripts/land.test.sh' \
  'bash -ex scripts/land.test.sh' 'VAR=1 bash scripts/land.test.sh' 'time bash scripts/land.test.sh' \
  '(bash scripts/land.test.sh)' '{ bash scripts/land.test.sh; }' 'for t in a; do bash scripts/land.test.sh; done' \
  'if true; then bash scripts/land.test.sh; fi' 'scripts/probe.sh f bash scripts/land.test.sh' \
  'bash scripts/land.test.sh > log 2>&1' 'bash scripts/land.test.sh 2>&1 | tail -3' 'bash "scripts/land.test.sh"' \
  'bash .claude/hooks/git-guardrails.test.sh; bash scripts/land.test.sh' $'echo x\nbash scripts/land.test.sh' \
  'env X=1 scripts/land.test.sh' 'bash   scripts/land.test.sh'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
for run in "scripts/with-lock.sh make test-hooks HOOK_TESTS='scripts/land.test.sh'" \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/with-lock.test.sh' 'scripts/with-lock.sh make check-changed FILTER=X' \
  'scripts/with-lock.sh bash -n scripts/land.test.sh' 'scripts/with-lock.sh bash .scratchpads/x/land.test.sh' \
  'scripts/with-lock.sh bash scripts/land.sh' \
  'HOOK_CASES=guardrails-rules scripts/with-lock.sh make test-hooks HOOK_TESTS=.claude/hooks/git-guardrails.test.sh > logs/x.log 2>&1' \
  'bash -n scripts/land.test.sh' 'sh -n scripts/land.test.sh' 'bash -nx scripts/land.test.sh' \
  'rg -n case scripts/land.test.sh' 'sed -n 1,5p scripts/land.test.sh' 'echo bash scripts/land.test.sh' \
  'git add scripts/land.test.sh && git commit -F .scratchpads/commit-msg.txt' 'chmod +x scripts/land.test.sh' \
  'bash .scratchpads/run-tests.sh' 'bash .scratchpads/x/land.test.sh' 'bash scripts/land.sh' \
  $'cat > notes.txt <<\'EOF\'\nbash scripts/land.test.sh\nEOF'; do
  expect allow "$run"
done

# Inside a with-lock.sh call a direct run of a hook test blocks too (item 1375, DLV-206/cost). A .test.sh
# form gets the key-tree reason; a test-hooks.sh form and a bare make test-hooks get the lock-free-form
# reason, because test-hooks.sh makes the key tree. No reason says that the call holds the lock.
expect_each_reason() { # <command> <substring>...
  local run="$1" want
  shift
  for want in "$@"; do expect_message "$want" "$run"; done
}
expect_no_reason() { # <substring> <command>: a block whose message lacks the substring
  local msg
  expect block "$2"
  msg="$("$hook" < "$input" 2>&1)"
  [[ "$msg" != *"$1"* ]] || { echo "FAIL: the message holds '$1': $2"; failures=$((failures + 1)); }
}
for run in 'scripts/with-lock.sh bash scripts/land.test.sh' 'scripts/with-lock.sh bash scripts/with-lock.test.sh > logs/x.log 2>&1' \
  'WITH_LOCK_MAX_WAIT=5 scripts/with-lock.sh bash scripts/land.test.sh' 'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh bash scripts/land.test.sh' \
  'scripts/with-lock.sh scripts/land.test.sh' 'scripts/with-lock.sh sh scripts/land.test.sh' \
  'scripts/with-lock.sh /bin/bash -x scripts/land.test.sh' 'scripts/with-lock.sh scripts/probe.sh f bash scripts/land.test.sh' \
  '../wt/scripts/with-lock.sh bash scripts/land.test.sh' 'scripts/with-lock.sh bash .claude/hooks/git-guardrails.test.sh' \
  'scripts/with-lock.sh .claude/hooks/git-guardrails.test.sh' 'bash scripts/land.test.sh'; do
  expect_each_reason "$run" "HOOK_TESTS='<names>'" 'takes no lock' 'waits while a long holder' '(the header of scripts/with-lock.sh)' \
    'outside the key tree of scripts/test-hooks.sh'
  expect_no_reason 'holds the build lock' "$run"
  expect_no_reason 'outside its lock-free form' "$run"
  expect_no_reason 'long_holder' "$run"
  expect_no_reason 'AGENTS.md' "$run"
done
for run in 'scripts/with-lock.sh scripts/test-hooks.sh scripts/land.test.sh' 'scripts/with-lock.sh bash scripts/test-hooks.sh' \
  'scripts/test-hooks.sh' 'make test-hooks'; do
  expect_each_reason "$run" "HOOK_TESTS='<names>'" 'takes no lock' '(the header of scripts/with-lock.sh)' 'outside its lock-free form'
  expect_no_reason 'holds the build lock' "$run"
  expect_no_reason 'outside the key tree' "$run"
  expect_no_reason 'long_holder' "$run"
  expect_no_reason 'AGENTS.md' "$run"
done

# A --bench-mark word before the command does not hide a hook test: a hook test runs only through
# make test-hooks HOOK_TESTS=, marked or not.
for run in 'scripts/with-lock.sh --bench-mark bash scripts/land.test.sh' 'scripts/with-lock.sh --bench-mark scripts/land.test.sh' \
  'WITH_LOCK_MAX_WAIT=5 scripts/with-lock.sh --bench-mark bash scripts/with-lock.test.sh > logs/x.log 2>&1'; do
  expect_each_reason "$run" "HOOK_TESTS='<names>'" 'takes no lock' '(the header of scripts/with-lock.sh)' 'outside the key tree of scripts/test-hooks.sh'
  expect_no_reason 'outside its lock-free form' "$run"
done
for run in 'scripts/with-lock.sh --bench-mark scripts/test-hooks.sh scripts/land.test.sh' 'scripts/with-lock.sh --bench-mark bash scripts/test-hooks.sh x' \
  'scripts/with-lock.sh --bench-mark make test-hooks' \
  'scripts/with-lock.sh --bench-mark make -s test-hooks HOOK_TESTS=scripts/land.test.sh'; do
  expect_each_reason "$run" "HOOK_TESTS='<names>'" 'takes no lock' '(the header of scripts/with-lock.sh)' 'outside its lock-free form'
  expect_no_reason 'outside the key tree' "$run"
done
expect allow 'scripts/with-lock.sh --bench-mark make test-hooks HOOK_TESTS=scripts/land.test.sh'
expect allow 'WITH_LOCK_MAX_WAIT=5 scripts/with-lock.sh --bench-mark make test-hooks HOOK_TESTS=scripts/land.test.sh > logs/x.log 2>&1'

# Inside a with-lock.sh call a make test-hooks segment passes only when scripts/lock-words.sh, which
# with-lock.sh also reads, classes it as free or release (code gate 1 of upkeep-thirteenth, Act on 1): a
# make flag, another target, or a BASE value makes with-lock.sh take the lock, and the test then holds a
# slot of the cap. A quoted value, a redirect, and a pipe after the words do not count as words. The
# test-rule segment below sends each spelling through the hook and through lock-words.sh.
for run in 'scripts/with-lock.sh make -C ../wt test-hooks HOOK_TESTS=scripts/land.test.sh' \
  'scripts/with-lock.sh make -s test-hooks HOOK_TESTS=scripts/land.test.sh' \
  'scripts/with-lock.sh make --no-print-directory test-hooks HOOK_TESTS=scripts/land.test.sh' \
  'scripts/with-lock.sh make test-hooks -j4 HOOK_TESTS=scripts/land.test.sh' \
  'scripts/with-lock.sh make test-hooks check-changed HOOK_TESTS=scripts/land.test.sh' \
  'scripts/with-lock.sh make -n test-hooks' 'scripts/with-lock.sh make -C ../wt test-hooks' \
  'WITH_LOCK_MAX_WAIT=5 scripts/with-lock.sh make -s test-hooks HOOK_TESTS=scripts/land.test.sh > logs/x.log 2>&1' \
  'cd ../wt && scripts/with-lock.sh make -C . test-hooks HOOK_TESTS=scripts/land.test.sh' \
  '(scripts/with-lock.sh make -s test-hooks HOOK_TESTS=scripts/land.test.sh)' \
  "scripts/with-lock.sh make -s test-hooks HOOK_TESTS='scripts/land.test.sh scripts/with-lock.test.sh'" \
  'scripts/with-lock.sh make test-hooks BASE=origin/main HOOK_TESTS=scripts/land.test.sh'; do
  expect_each_reason "$run" "HOOK_TESTS='<names>'" 'takes no lock' '(the header of scripts/with-lock.sh)' 'outside its lock-free form'
  expect_no_reason 'holds the build lock' "$run"
  expect_no_reason 'outside the key tree' "$run"
done
for run in 'scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1' \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/land.test.sh DIRIGIBLE_HOOKS_ALL=1' \
  "scripts/with-lock.sh make test-hooks HOOK_TESTS='scripts/land.test.sh scripts/with-lock.test.sh'" \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS="scripts/land.test.sh scripts/with-lock.test.sh"' \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/land.test.sh 2>&1 | tail -3' \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/land.test.sh >logs/x.log 2>&1' \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/land.test.sh 12>&1' \
  '{ scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/land.test.sh; }' \
  '../wt/scripts/with-lock.sh /usr/bin/make test-hooks HOOK_TESTS=scripts/land.test.sh'; do
  expect allow "$run"
done

# A quoted string and a data heredoc body are data, not commands (code gate 1 of 2026-10-28-upkeep-sixth,
# Act on 2): a test file named after ( ; & | in a decision row, a commit message, a pull request body,
# an echo, or an rg pattern passes. Code in a $(...) of a quote, and the body of a shell, still block.
for run in '.claude/skills/deliver/scripts/log-decision.sh .scratchpads/runs/x 4 "S1 green (scripts/land.test.sh)" "why; bash scripts/land.test.sh ran" "logs/s1.log" "done"' \
  'git commit -m "test(hooks): the case (bash scripts/land.test.sh) passes; scripts/land.test.sh stays"' \
  $'gh pr create --title t --body "$(cat <<\'EOF\'\nRun (bash scripts/land.test.sh) first\nthen; scripts/land.test.sh\nEOF\n)"' \
  'echo "a | scripts/land.test.sh"' \
  "rg -n '(scripts/land.test.sh|bash scripts/land.test.sh)' docs"; do
  expect allow "$run"
done
for run in 'echo "$(bash scripts/land.test.sh)"' $'bash <<\'EOF\'\nbash scripts/land.test.sh\nEOF' \
  'echo "x y" && bash scripts/land.test.sh' "echo 'x; y'; bash scripts/land.test.sh"; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done

# A heredoc body is data when the head word of its line is not a shell or an interpreter (code gate 2
# of 2026-10-28-upkeep-sixth, Act on 2): a commit message or a pull request body from stdin that
# names a test file after ( or ; passes, with a quoted or an unquoted marker. A shell, an
# interpreter, a pipe to a shell, and an unquoted body with $( or a backtick stay code.
for run in $'git commit -F - <<\'EOF\'\ntest(hooks): the case (bash scripts/land.test.sh) passes; scripts/land.test.sh stays\nEOF' \
  $'gh pr create --title t --body-file - <<\'EOF\'\nRun (bash scripts/land.test.sh) first\nthen; scripts/land.test.sh\nEOF' \
  $'git commit -F - <<EOF\nthe case (bash scripts/land.test.sh) passes; scripts/land.test.sh stays\nEOF' \
  $'git commit -F - <<"EOF"\nthe case (bash scripts/land.test.sh) passes\nEOF' \
  $'git commit -F - <<-\'EOF\'\n\tthe case (bash scripts/land.test.sh) passes\n\tEOF' \
  $'git commit -F - <<\'EOF\'\nthe case $(bash scripts/land.test.sh) stays text\nEOF' \
  $'cd ../wt && git commit -F - <<\'EOF\'\nthe case (bash scripts/land.test.sh) passes\nEOF'; do
  expect allow "$run"
done
for run in $'cat <<\'EOF\' | bash\nbash scripts/land.test.sh\nEOF' $'bash -s <<\'EOF\'\nbash scripts/land.test.sh\nEOF' \
  $'/bin/sh <<\'EOF\'\n(bash scripts/land.test.sh)\nEOF' $'sudo bash <<\'EOF\'\nbash scripts/land.test.sh\nEOF' \
  $'bash <<-\'EOF\'\n\t(bash scripts/land.test.sh)\n\tEOF' \
  $'python3 - <<\'EOF\'\nimport os\nos.system("true")\nbash scripts/land.test.sh\nEOF' \
  $'git commit -F - <<EOF\nthe case $(bash scripts/land.test.sh) runs\nEOF' \
  $'git commit -F - <<EOF\nthe case `bash scripts/land.test.sh` runs\nEOF'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done

# A bare make test-hooks and a scripts/test-hooks.sh run (bare, or inside a with-lock.sh call) run
# every hook test outside the lock-free form (Act on 4). make test-hooks inside a with-lock.sh call (words
# below), bash -n, and a read of the file pass.
for run in 'make test-hooks' 'make -C ../wt test-hooks' 'DIRIGIBLE_FULL_SUITE=1 make test-hooks' 'make test-hooks 2>&1 | tail -3' \
  'make test-hooks HOOK_TESTS=scripts/land.test.sh' 'scripts/test-hooks.sh' './scripts/test-hooks.sh' 'bash scripts/test-hooks.sh' \
  '../wt/scripts/test-hooks.sh scripts/land.test.sh' 'cd ../wt && make test-hooks' 'time make test-hooks' \
  '(make test-hooks)' '(cd ../wt && make test-hooks)' 'make test-hooks>log' 'make test-hooks>log 2>&1' \
  'make -C ../wt test-hooks>log' '(make test-hooks) 2>&1' 'make test-hooks<in'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
for run in "scripts/with-lock.sh make test-hooks HOOK_TESTS='scripts/land.test.sh'" \
  'bash -n scripts/test-hooks.sh' 'rg -n test-hooks Makefile' \
  'sed -n 1,5p scripts/test-hooks.sh' 'echo make test-hooks' 'make check-docs' 'git add scripts/test-hooks.sh'; do
  expect allow "$run"
done

# make -n and make --dry-run print the recipe and run no test (code gate 2, Act on 5).
for run in 'make -n test-hooks' 'make --dry-run test-hooks' 'make -n test-hooks>log' '(make -n test-hooks)' \
  'make -C ../wt --dry-run test-hooks'; do
  expect allow "$run"
done

# A # at the start of a word, outside quotes, starts a shell comment that ends at the new line (code
# gate 2 fix check, 1.2): a quote mark in a comment opens no quoted string, so it hides no command on
# a later line. A # inside a word (a#b, ${x#y}, $#), after a backslash, or in a quote starts no comment.
for run in $'# it\'s here\nbash scripts/land.test.sh\n# that\'s all' $'# it\'s here\nmake test-hooks\n# that\'s all' \
  $'# say "hi\nbash scripts/land.test.sh\n# done"' $'# say "hi\nmake test-hooks\n# done"' \
  $'echo x # it\'s\nbash scripts/land.test.sh\necho y # that\'s' $'# cat > f <<\'EOF\'\nbash scripts/land.test.sh\nEOF' \
  $'echo $(# it\'s\nbash scripts/land.test.sh\n)\n# that\'s all' \
  'echo ${x#y}; bash scripts/land.test.sh' 'echo a#b; bash scripts/land.test.sh' 'echo $#; bash scripts/land.test.sh' \
  'echo \#; bash scripts/land.test.sh' "echo '#'; bash scripts/land.test.sh" 'echo "#"; make test-hooks' \
  'echo a\ #b; bash scripts/land.test.sh'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
for run in $'# run bash scripts/land.test.sh later\necho done' $'# it\'s scripts/land.test.sh\n# that\'s all' \
  $'# it\'s here\nmake check-docs\n# that\'s all' 'echo "a; scripts/land.test.sh" # it'"'"'s fine' \
  $'echo x # bash scripts/land.test.sh\necho y' $'#scripts/land.test.sh\necho y' \
  $'# it\'s here\nscripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/land.test.sh\n# that\'s all'; do
  expect allow "$run"
done

# The project settings parse, and register this hook as a PreToolUse hook for Bash.
python3 -m json.tool "$settings" >/dev/null 2>&1 || { echo "FAIL: .claude/settings.json does not parse"; failures=$((failures + 1)); }
python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
ok = any(e.get("matcher") == "Bash"
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/git-guardrails.sh") for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$settings" 2>/dev/null || { echo "FAIL: .claude/settings.json does not register git-guardrails.sh for Bash"; failures=$((failures + 1)); }


# Unreadable input fails closed.
printf 'not json' | "$hook" 2>/dev/null
[[ $? -eq 2 ]] || { echo "FAIL: unreadable input was allowed"; failures=$((failures + 1)); }

# A build, a test, or a probe runs as scripts/with-lock.sh <command> (AGENTS.md, Commands), so two work
# trees do not build at once. The block message gives the form and the run-only probe form. The scripts
# that take the lock themselves, swift run, swift format, and the make targets that take no lock pass.
for run in 'swift build' 'swift test --filter X' 'cd /w && swift build' 'time make build' 'make test-filter FILTER=x' \
  'make check-changed' 'make -s app' 'scripts/probe.sh .scratchpads/x bash p.sh' 'BASE=origin/main make check-changed' \
  'if swift build; then echo ok; fi' '(cd /w; swift test)' 'make -C /w build' 'env X=1 make test' './scripts/probe.sh f cmd' \
  $'swift build\ngit status' 'until make build; do sleep 1; done' 'if true; then echo x; elif make build; then echo y; fi' \
  'make' 'make -j4' 'make -j 4' 'make -C /w' 'make -sC /w' 'make FOO=1' 'time make' 'make > log 2>&1' 'make -j4 -C /w FOO=1'; do
  expect_message 'scripts/with-lock.sh <command>' "$run"
  expect_message 'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh' "$run"
done
for run in 'scripts/with-lock.sh swift build' 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main' \
  'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh .scratchpads/x /abs/dirigible' 'scripts/with-lock.sh scripts/probe.sh f cmd' \
  'make check-docs' 'make lint' 'make format' 'make check-fast' 'swift format lint --strict Sources' 'swift run dirigible --help' \
  'scripts/swift-test.sh --filter X' 'rg "swift build" AGENTS.md' "rg 'swift build' AGENTS.md" 'echo "make build"' 'make -n build' \
  'make --dry-run test' 'git commit -m "fix: swift build now takes the lock"' $'git commit -F - <<\'EOF\'\nmake build\nEOF' \
  'make -C /w check-docs' 'make -s lint' 'make -j4 check-fast' 'make -j 4 check-docs' 'make -f Makefile lint' 'make --version' \
  'make -n' 'make -C /w -n' 'make -C /w lint FOO=1' 'make FOO=1 format' \
  'swift --version' 'swift package dump-package' 'ls scripts/probe.sh' 'cat scripts/probe.sh' 'echo make build'; do
  expect allow "$run"
done
fi # guardrails-rules

# The hook test rule reads the verdict of scripts/lock-words.sh for a with-lock.sh make test-hooks call.
if case_block test-rule; then
lock_stub="$tmp/lockstub/wl"
mkdir -p "$tmp/lockstub"
printf '#!/bin/bash\n. "%s"\nif lock_make_words "$@" && [[ $lock_goal == test-hooks ]]; then echo free; elif release_call "$@"; then echo release; else echo lock; fi\n' \
  "$(cd "$(dirname "$0")/../../scripts" && pwd)/lock-words.sh" > "$lock_stub"
chmod +x "$lock_stub"
T=scripts/land.test.sh
# The 23 spellings: the hook allows a call if and only if lock-words.sh classes it free or release.
lock_spellings=(
  "scripts/with-lock.sh make test-hooks HOOK_TESTS=$T" "scripts/with-lock.sh /usr/bin/make test-hooks HOOK_TESTS=$T" \
  "scripts/with-lock.sh env make test-hooks HOOK_TESTS=$T" "time scripts/with-lock.sh env X=1 make test-hooks HOOK_TESTS=$T" \
  "env X=1 scripts/with-lock.sh make test-hooks HOOK_TESTS=$T" "scripts/with-lock.sh make -C ../wt test-hooks HOOK_TESTS=$T" \
  "scripts/with-lock.sh make -s test-hooks HOOK_TESTS=$T" "scripts/with-lock.sh make -n test-hooks HOOK_TESTS=$T" \
  "scripts/with-lock.sh make --no-print-directory test-hooks HOOK_TESTS=$T" "scripts/with-lock.sh make test-hooks -j4 HOOK_TESTS=$T" \
  "scripts/with-lock.sh make test-hooks test-hooks HOOK_TESTS=$T" "scripts/with-lock.sh make test-hooks BASE=origin/main HOOK_TESTS=$T" \
  "BASE=origin/main scripts/with-lock.sh make test-hooks HOOK_TESTS=$T" "MAKEFLAGS=BASE=origin/main scripts/with-lock.sh make test-hooks HOOK_TESTS=$T" \
  "scripts/with-lock.sh make test-hooks HOOK_TESTS=" "scripts/with-lock.sh make test-hooks HOOK_TESTS=''" \
  "HOOK_TESTS=$T scripts/with-lock.sh make test-hooks" "scripts/with-lock.sh make test-hooks" \
  "DIRIGIBLE_FULL_SUITE=1 scripts/with-lock.sh make test-hooks" "scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1" \
  "DIRIGIBLE_HOOKS_ALL=1 scripts/with-lock.sh make test-hooks" "scripts/with-lock.sh make test-hooks HOOK_TESTS=$T DIRIGIBLE_HOOKS_ALL=1" \
  "scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=0"
)
expect_each_lock agree \
  "${lock_spellings[@]}"
# While an agent whose brief names a lock step runs, each spelling of class release blocks too (AGT-152).
rw_rec "$tmp/rw-lock" toolu_tl 600 Agent toolu_tl
rw_meta tl toolu_tl none 10
expect_each_lock --live "$tmp/rw-lock" agree "${lock_spellings[@]}"
# Spellings that the fix was not fitted to, each with a fixed verdict. With WITH_LOCK_RUN_ONLY=1, with-lock.sh
# exits 2 and runs nothing unless the command is a built binary or a shell file, so the bare form blocks and
# the HOOK_TESTS=a form is safe to allow (the hook models no run-only mode).
expect_each_lock allow \
  'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1' "scripts/with-lock.sh 'make' test-hooks HOOK_TESTS=a" \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS="a b"' 'MAKEFLAGS=-s scripts/with-lock.sh make test-hooks HOOK_TESTS=a' \
  'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh make test-hooks HOOK_TESTS=a'
expect_each_lock block 'WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh make test-hooks'
# A $ value counts as non-empty.
expect allow 'scripts/with-lock.sh make test-hooks HOOK_TESTS="$T"'
expect allow 'scripts/with-lock.sh make test-hooks HOOK_TESTS=$T'
# The bare form, the whole-suite form, and an env word after with-lock.sh take the lock in with-lock.sh, so they block.
for run in 'scripts/with-lock.sh make test-hooks' 'time scripts/with-lock.sh env X=1 make test-hooks HOOK_TESTS=scripts/land.test.sh' \
  'DIRIGIBLE_FULL_SUITE=1 scripts/with-lock.sh make test-hooks' 'scripts/with-lock.sh make test-hooks>log' \
  '(scripts/with-lock.sh make test-hooks)'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
# A segment of only NAME=value words runs no command, so it passes. A later segment that runs $NAME, a name that an
# earlier segment set to a repo .test.sh path, blocks across ;, &&, ||, and a new line.
for run in 'F=.claude/hooks/git-guardrails.test.sh; sed -n 1,5p $F' 'T=.claude/hooks/git-guardrails.test.sh; rg -n expect_each $T' \
  'F=scripts/land.test.sh; bash $G' 'F=scripts/land.test.sh; bash -n $F' \
  'F=.scratchpads/x/a.test.sh; bash $F' 'F=scripts/land.sh; bash $F' 'F=scripts/land.test.sh && wc -l $F' $'F=scripts/land.test.sh\nwc -l $F'; do
  expect allow "$run"
done
expect_each_context allow 'F=.claude/hooks/git-guardrails.test.sh; sed -n 1,5p $F'
for run in 'F=scripts/land.test.sh; bash $F' 'F=scripts/land.test.sh; bash "$F"' 'F=scripts/land.test.sh; sh ${F}' 'F=scripts/land.test.sh; $F' \
  'F=scripts/land.test.sh; scripts/with-lock.sh bash $F' 'export F=scripts/land.test.sh; bash $F' \
  'F=scripts/land.test.sh && bash $F' 'F=scripts/land.test.sh || bash "$F"' $'F=scripts/land.test.sh\nbash $F' \
  'H=scripts/test-hooks.sh; bash $H'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
expect_each_context block 'F=scripts/land.test.sh; bash $F'
expect_each_context allow 'F=scripts/land.test.sh; bash $F'
# export, declare, typeset, local, and readonly (with -<letters> flags) are assignment words too, and a name set to
# $NAME, "$NAME", or ${NAME} of a recorded name is recorded.
for run in "declare F=$T; bash \$F" "readonly F=$T; bash \$F" "typeset F=$T; bash \$F" "local F=$T; bash \$F" \
  "declare -x F=$T; bash \$F" "declare -r -x F=$T; bash \$F" "F=$T; G=\$F; bash \$G" "F=$T; G=\"\$F\"; bash \$G" \
  "F=$T; G=\${F}; bash \$G" "F=$T; export G=\$F; bash \$G" "F=$T; H=\$F; G=\$H; bash \$G" "F=$T && G=\$F && bash \$G" \
  "H=scripts/test-hooks.sh; G=\$H; bash \$G" $'F=scripts/land.test.sh\nG=$F\nbash $G'; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
for run in "G=\$F; bash \$G" "F=.scratchpads/x/a.test.sh; G=\$F; bash \$G" "F=scripts/land.sh; G=\$F; bash \$G" \
  "F=$T; G=\$F; wc -l \$G" "declare F=$T; wc -l \$F"; do
  expect allow "$run"
done
# An export (or declare -x, typeset -x) of BASE or MAKEFLAGS=BASE=... in an earlier segment is in the environment of a
# with-lock.sh make test-hooks segment, so the call takes the lock and blocks, across ;, &&, and a new line. An export of
# DIRIGIBLE_HOOKS_ALL=1 makes the bare call a hooks pass. A plain BASE=x segment is not in the environment of the child.
lw="scripts/with-lock.sh make test-hooks HOOK_TESTS=$T"
for run in "export BASE=origin/main; $lw" "export BASE=origin/main && $lw" $'export BASE=origin/main\n'"$lw" \
  "export MAKEFLAGS=BASE=origin/main; $lw" "export MAKEFLAGS=BASE=origin/main && $lw" $'export MAKEFLAGS=BASE=origin/main\n'"$lw" \
  "declare -x BASE=origin/main; $lw" "typeset -x BASE=origin/main; $lw"; do
  expect_message "HOOK_TESTS='<names>'" "$run"
done
expect_each_lock agree "export BASE=origin/main; $lw" "export MAKEFLAGS=BASE=origin/main; $lw" "declare -x BASE=origin/main; $lw" \
  'export DIRIGIBLE_HOOKS_ALL=1; scripts/with-lock.sh make test-hooks' 'export DIRIGIBLE_HOOKS_ALL=0; scripts/with-lock.sh make test-hooks' \
  "export BASE=origin/main; export BASE=; $lw" "export -n BASE=origin/main; $lw"
expect_each_lock allow "BASE=origin/main; $lw"
# After a prefix of assignments, cd, and mkdir -p, a cat body that runs a repo .test.sh file is data. A python3 or
# bash body after the same prefix runs it, so it blocks.
expect allow "S=x; mkdir -p stubbin; cat > stubbin/make <<'EOF'"$'\n'"bash $T"$'\nEOF'
expect allow "cd logs && mkdir -p fix4-stub && cat > fix4-stub/make <<'EOF'"$'\n'"bash $T"$'\nEOF'
expect_message 'runs a repo hook test outside the key tree' "L=x; python3 - <<'EOF'"$'\nimport os\nos.system("true")\n'"bash $T"$'\nEOF'
expect_message 'runs a repo hook test outside the key tree' "L=x; bash <<'EOF'"$'\n'"bash $T"$'\nEOF'
expect allow "L=x; python3 - <<'EOF'"$'\n'"bash $T"$'\nEOF'
# A hook copy with no scripts/lock-words.sh above it blocks a with-lock.sh make test-hooks segment, names the file, and
# still allows a command that is no such segment.
mkdir -p "$tmp/nolw/.claude/hooks"
cp "$hook" "$tmp/nolw/.claude/hooks/"
hook_saved="$hook" hook="$tmp/nolw/.claude/hooks/git-guardrails.sh"
expect_message 'scripts/lock-words.sh' "scripts/with-lock.sh make test-hooks HOOK_TESTS=$T"
expect allow 'git status'
hook="$hook_saved"
# One word list decides what a long holder is, for lock_holder of scripts/with-lock.sh and for the release wait
# of a background call of the lead (items 1808, 1766).
lh_repo="$tmp/lh-repo" lh_lock="$tmp/lh-repo/.git/dirigible-build.lock"
mkdir -p "$lh_repo/scripts"
cp "$(dirname "$0")/../../scripts/with-lock.sh" "$(dirname "$0")/../../scripts/lock-words.sh" "$lh_repo/scripts/"
git -C "$lh_repo" init -q
# expect_each_long <held|free> <command>...: with-lock.sh --long-holder with the command as the live holder in a
# temp repo exits 0 for held and 1 for free; the hook blocks (held) or allows (free) the command as a background
# call of the lead beside a live lock-step agent, after a with-lock.sh word, and bare for a command that is no make.
expect_each_long() {
  local want="$1" verdict=allow code=1 cmd got
  [[ "$want" == held ]] && verdict=block code=0
  shift
  for cmd in "$@"; do
    mkdir -p "$lh_lock" && echo $$ > "$lh_lock/pid" && echo "$cmd" > "$lh_lock/command"
    (cd "$lh_repo" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u DIRIGIBLE_BUILD_LOCK -u DIRIGIBLE_BENCH_MARK \
      -u BASE -u MAKEFLAGS -u DIRIGIBLE_HOOKS_ALL scripts/with-lock.sh --long-holder > /dev/null 2>&1)
    got=$?
    rm -rf "$lh_lock"
    [[ $got -eq $code ]] || { echo "FAIL: with-lock.sh --long-holder exit $got (want $code) for the holder: $cmd"; failures=$((failures + 1)); }
    expect_release "$verdict" "$tmp/rw-lock" "scripts/with-lock.sh $cmd" '' '' bg
    [[ "$cmd" == make\ * ]] || expect_release "$verdict" "$tmp/rw-lock" "$cmd" '' '' bg
  done
}
expect_each_long held 'make check-changed BASE=origin/main' 'scripts/land.sh t x/pr.md' 'make dmg' 'scripts/bench.sh NavBench' \
  'scripts/bench-pairs.sh /x/main NavBench 3 /x/pairs' 'make bench FILTER=NavBench' 'make FILTER=NavBench bench' \
  '.claude/skills/deliver/scripts/mutation-pass.sh /x/wt /x/batch.txt' 'scripts/flake-monitor/loop.sh 10 FooTests' \
  'scripts/test-stress.sh --runs 1 /x/out'
# A wrapper hides no long holder: long_words reads the command after a separator and after a wrapper
# word. An argument of another command runs no holder.
expect_each_long held 'scripts/probe.sh /x/p make bench FILTER=NavBench' "bash -c 'cd /x && make bench FILTER=NavBench'" \
  'caffeinate -i scripts/bench.sh NavBench' 'scripts/probe.sh --no-audio /x/p scripts/bench-pairs.sh /x/main NavBench 3 /x/pairs'
expect_each_long free 'scripts/bench-pairs.sh --compare /x/pairs' 'scripts/bench-pairs.sh --lines /x/b.log' 'make build' \
  'make test-filter FILTER=ATests' 'rg -n scripts/bench.sh notes.txt' "bash -c 'make build && echo bench'"
fi # test-rule

# A release call waits while an agent whose brief names a lock step runs (AGT-152).
if case_block release-wait; then
rw="$tmp/rw"
rw_rec "$rw/live" toolu_live 600 Agent toolu_live 'S1 slice agent'
rw_meta alive toolu_live none 598
expect_each_release block "$rw/live"
# Quoted data and calls that are no release call keep their verdict with the live record. A python3 -I
# heredoc body is data, and the same body as a bash heredoc is code.
for run in 'echo "(scripts/with-lock.sh make check-changed BASE=origin/main)"' "rg -n '\`scripts/with-lock.sh make dmg\`' AGENTS.md" \
  $'python3 -I - <<\'EOF\'\nprint(\'it\\\'s; scripts/with-lock.sh make dmg\')\nEOF' \
  $'python3 -I - <<\'EOF\'\nimport subprocess\nif ("land.sh" not in c): pass\nEOF' \
  'scripts/with-lock.sh make test-hooks HOOK_TESTS=scripts/x.test.sh' 'scripts/with-lock.sh swift build' \
  "rg -n 'make check-changed BASE=' notes.txt" \
  "scripts/with-lock.sh bash -c 'time make test-hooks HOOK_TESTS=.claude/hooks/git-guardrails.test.sh HOOK_CASES=\"test-rule|release-wait\"' > logs/s1-test.log 2>&1" \
  "bash -c 'scripts/with-lock.sh make check-changed'" 'scripts/with-lock.sh make check-changed FILTER=ATests' \
  'git commit -m "docs: say scripts/with-lock.sh make dmg is for the lead"' 'git status' \
  'scripts/with-lock.sh make check-changed FILTER="a dmg"' 'bash scripts/x.sh land.sh'; do
  expect_release allow "$rw/live" "$run"
done
expect_release block "$rw/live" $'bash <<\'EOF\'\nprint(\'it\\\'s; scripts/with-lock.sh make dmg\')\nEOF'

P='WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main'
# Liveness of a SendMessage record: its key is the agent id, and its meta is agent-<key>.meta.json. A
# finished meta older than a record over 5 min old means that no resume started.
# rw_send <name> <record age> <meta: none|true|open> <meta mtime age> <want>
rw_send() {
  rm -f "$rw_sub/agent-a0123456789abcdef.meta.json"
  rw_rec "$rw/sm-$1" "toolu_sm$1" "$2" SendMessage a0123456789abcdef
  [[ "$3" == none ]] || rw_meta a0123456789abcdef toolu_orig "$([[ $3 == true ]] && echo true || echo none)" "$4"
  expect_release "$5" "$rw/sm-$1" "$P"
}
rw_send 1 600 true 1200 allow
rw_send 2 600 true 60 allow
rw_send 3 60 true 660 block
rw_send 4 5460 true 6000 allow
rw_send 5 5340 true 6000 allow
rw_send 6 600 open 60 block
rm -f "$rw_sub/agent-a0123456789abcdef.meta.json"
rw_rec "$rw/sm-7" toolu_sm7 240 SendMessage main
expect_release block "$rw/sm-7" "$P"
rw_rec "$rw/sm-8" toolu_sm8 360 SendMessage main
expect_release allow "$rw/sm-8" "$P"
# Liveness of an Agent record: its meta holds its key as the toolUseId.
# rw_agent <name> <record age> <meta: none|true|open> <meta mtime age> <want>
rw_agent() {
  rm -f "$rw_sub"/agent-ag*.meta.json
  rw_rec "$rw/ag-$1" "toolu_ag$1" "$2" Agent "toolu_ag$1"
  [[ "$3" == none ]] || rw_meta "ag$1" "toolu_ag$1" "$([[ $3 == true ]] && echo true || echo none)" "$4"
  expect_release "$5" "$rw/ag-$1" "$P"
}
rw_agent 1 600 open 598 block
rw_agent 2 600 true 60 allow
rw_agent 3 240 none 0 block
rw_agent 4 360 none 0 allow
rw_agent 5 5340 open 5338 block
rw_agent 6 5460 open 5458 allow
# A run or a resume of an agent with an old record: the meta with no finished keeps it live for 90 min
# after its run started, and records over 24 h old do not count.
rw_agent r1 10800 open 600 block
release_has "agr1: Agent \"d toolu_agr1\""
release_has "its run started $(date -r $(($(date +%s) - 600)) +%H:%M)"
rw_agent r2 10800 true 60 allow
rw_agent r3 10800 open 5460 allow
rw_agent r4 10800 open 5340 block
rw_agent r5 90000 open 600 allow
rw_agent r6 86000 open 600 block
rm -f "$rw_sub"/agent-ag*.meta.json
mkdir -p "$rw/empty"
expect_release allow "$rw/empty" "$P"
# Two records of one agent give one message line and one id: the agent id.
rw_rec "$rw/one" toolu_q1 10800 Agent toolu_q1 'agent q'
rw_rec "$rw/one" toolu_q2 600 SendMessage aq 'resume aq'
rw_meta aq toolu_q1 none 590
expect_release block "$rw/one" "$P"
[[ "$(grep -c '^- aq:' "$tmp/release.err")" == 1 ]] || { echo "FAIL: release-wait gives other than one line for agent aq"; failures=$((failures + 1)); }
expect_release allow "$rw/one" "RELEASE_PAST=aq $P"
expect_release block "$rw/one" "RELEASE_PAST=toolu_q1 $P"
rm -f "$rw_sub/agent-aq.meta.json"

# RELEASE_PAST passes the call only when it names each live agent and no other id. The id is the agent
# id when a meta exists (a1), else the record id (toolu_b2).
rw_rec "$rw/two" toolu_a1 600 Agent toolu_a1 'Implement S1'
rw_rec "$rw/two" toolu_b2 120 Agent toolu_b2 'Review lens'
rw_meta a1 toolu_a1 none 598
nb="(nohup bash -c \"$P > l 2>&1\" > /dev/null 2>&1 < /dev/null &)"
for run in "RELEASE_PAST=a1,toolu_b2 $P" "cd /x/wt && (RELEASE_PAST=a1,toolu_b2 nohup bash -c \"$P > l 2>&1\" > /dev/null 2>&1 < /dev/null &)" \
  "(nohup bash -c \"RELEASE_PAST=a1,toolu_b2 $P > l 2>&1\" > /dev/null 2>&1 < /dev/null &)" "RELEASE_PAST=a1,toolu_b2 cd /x/wt && $nb" \
  "export RELEASE_PAST=a1,toolu_b2; cd /x/wt && $nb" "RELEASE_PAST=\"a1,toolu_b2\" $P" "RELEASE_PAST='a1,toolu_b2' $P" \
  "cd /x/wt && RELEASE_PAST=\"a1,toolu_b2\" $nb"; do
  expect_release allow "$rw/two" "$run"
done
for run in "RELEASE_PAST=a1 $P" "RELEASE_PAST=a1 cd /x/wt && $nb" "export RELEASE_PAST=toolu_b2; cd /x/wt && $nb" \
  "RELEASE_PAST=\"a1\" $P" "RELEASE_PAST='toolu_b2' $P"; do
  expect_release block "$rw/two" "$run"
done
expect_release block "$rw/two" "RELEASE_PAST=a1 $P"
release_has 'toolu_b2: Agent "Review lens"'
expect_release block "$rw/two" "RELEASE_PAST=a1,toolu_b2,toolu_zz $P"
release_has 'RELEASE_PAST names toolu_zz'
expect_release block "$rw/two" "$P"
for text in "a1: Agent \"Implement S1\", newest record at $(date -r "$(cut -f1 "$rw/two/toolu_a1")" +%H:%M)" "$rw_sub/agent-a1.meta.json" \
  'toolu_b2: Agent "Review lens"' 'no meta file yet' 'An agent stops being live when' \
  'Start the release call after that agent hands back' 'pass RELEASE_PAST=<id>' 'Build lock: none'; do
  release_has "$text"
done
expect_release allow "$rw/empty" "RELEASE_PAST=toolu_zz $P"
rm -f "$rw_sub/agent-a1.meta.json"

# A bench that the lead runs in the background (no agent_id) waits the same way (item 1730): after a
# with-lock.sh word or bare. The same call in the foreground, a --compare or --lines run, a make goal
# other than bench, and a subagent bench pass.
B='WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make bench FILTER=NavigationKeyBenchmark'
bench_bare=('scripts/bench.sh NavigationKeyBenchmark' 'scripts/bench-pairs.sh /x/main NavigationKeyBenchmark 3 /x/run/pairs')
for run in "$B" 'WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/bench.sh NavigationKeyBenchmark' \
  'scripts/with-lock.sh scripts/bench-pairs.sh /x/main NavigationKeyBenchmark 3 /x/run/pairs' "${bench_bare[@]}" \
  'cd /x/wt && scripts/bench.sh --trace /x/t.trace NavigationKeyBenchmark > /x/run/logs/b.log 2>&1' \
  'bash scripts/bench.sh NavigationKeyBenchmark'; do
  expect_release block "$rw/live" "$run" '' '' bg
  release_has 'or a long background step of the lead (a bench, a mutation pass, a flake loop, or a stress lane)'
  release_has 'alive: Agent "S1 slice agent"'
done
for run in "$B" "${bench_bare[@]}"; do expect_release allow "$rw/live" "$run"; done
for run in 'scripts/bench-pairs.sh --compare /x/run/pairs' 'scripts/bench-pairs.sh --lines /x/run/logs/b.log' \
  'scripts/with-lock.sh make test-filter FILTER=NavigationKeyBenchmark' "rg -n 'scripts/bench.sh NavigationKeyBenchmark' notes.txt" \
  "RELEASE_PAST=alive $B" 'RELEASE_PAST=alive scripts/bench.sh NavigationKeyBenchmark'; do
  expect_release allow "$rw/live" "$run" '' '' bg
done
expect_release allow "$rw/empty" "$B" '' '' bg
# A mutation pass, a flake loop, or a stress lane that the lead runs in the background waits the same way
# (items 1808, 1766): bare, after a with-lock.sh word, or as a line of a script file whose name holds no
# command word. The message names the step. The same calls pass with RELEASE_PAST, with no live record,
# and in the foreground; a subagent mutation pass keeps its refusal of a wait with no limit.
M='.claude/skills/deliver/scripts/mutation-pass.sh /x/wt /x/run/controls/batch.txt'
mkdir -p "$tmp/rw-long"
cat > "$tmp/rw-long/steps.sh" << 'EOF'
set -uo pipefail
tree=/x/wt batch=/x/run/controls/batch.txt log=/x/run/controls/pass-1.log status=0
cd "$tree" || exit 2
WITH_LOCK_MAX_HOLD=6000 .claude/skills/deliver/scripts/mutation-pass.sh "$tree" "$batch" > "$log" 2>&1 || status=$?
echo "exit $status" >> "$log"
EOF
printf 'echo "then run .claude/skills/deliver/scripts/mutation-pass.sh"\nrg -n "flake-monitor/loop.sh" notes.txt\n' > "$tmp/rw-long/notes.sh"
long_forms=("$M > /x/run/controls/pass.log 2>&1" "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh $M"
  'cd /x/wt && scripts/flake-monitor/loop.sh 10 FooTests > /x/l.log 2>&1' 'scripts/with-lock.sh scripts/flake-monitor/loop.sh 10 FooTests'
  'scripts/test-stress.sh --runs 3 /x/run/stress' "bash $tmp/rw-long/steps.sh > /x/run/p.log 2>&1")
long_steps=(mutation-pass.sh mutation-pass.sh flake-monitor/loop.sh flake-monitor/loop.sh test-stress.sh mutation-pass.sh)
for i in "${!long_forms[@]}"; do
  expect_release block "$rw/live" "${long_forms[i]}" '' '' bg
  release_has 'or a long background step of the lead (a bench, a mutation pass, a flake loop, or a stress lane)'
  release_has 'pass RELEASE_PAST=<id>'
  grep -F 'Step: ' "$tmp/release.err" | grep -qF -- "${long_steps[i]}" ||
    { echo "FAIL: release-wait message names no step ${long_steps[i]}: ${long_forms[i]}"; failures=$((failures + 1)); }
  expect_release allow "$rw/live" "RELEASE_PAST=alive ${long_forms[i]}" '' '' bg
  expect_release allow "$rw/empty" "${long_forms[i]}" '' '' bg
  expect_release allow "$rw/live" "${long_forms[i]}"
done
expect_release allow "$rw/live" "bash $tmp/rw-long/notes.sh" '' '' bg
# A shell -c body in a script file splits at its own separators, also one level down.
printf '%s\n' "bash -c 'make build && echo bench'" > "$tmp/rw-long/free-c.sh"
printf '%s\n' "cd /x && bash -c \"echo a; bash -c 'cd /x && $M'\"" > "$tmp/rw-long/held-c.sh"
expect_release allow "$rw/live" "bash $tmp/rw-long/free-c.sh" '' '' bg
expect_release block "$rw/live" "bash $tmp/rw-long/held-c.sh" '' '' bg
release_has 'Step: .claude/skills/deliver/scripts/mutation-pass.sh'
expect_release block "$rw/empty" "$M" '' a1
release_has 'runs a with-lock.sh call with no wait limit in a subagent'
# The release wait loads scripts/lock-words.sh at most once for each hook call (hook latency, item 1222),
# and a call with no lock word never loads it: a hook copy whose lock-words.sh logs each load reads a
# background script of 40 .sh lines and a mutation pass.
lw="$tmp/lw-load"
mkdir -p "$lw/.claude/hooks" "$lw/scripts"
cp "$hook" "$lw/.claude/hooks/"
{ echo 'echo load >> "$LW_LOG"'; cat "$(dirname "$0")/../../scripts/lock-words.sh"; } > "$lw/scripts/lock-words.sh"
for ((i = 1; i <= 40; i++)); do echo "scripts/step-$i.sh --arg $i > log-$i.txt 2>&1"; done > "$lw/steps.sh"
echo "$M" >> "$lw/steps.sh"
hook_saved="$hook" hook="$lw/.claude/hooks/git-guardrails.sh"
export LW_LOG="$lw/loads"
# lw_case <block|allow> <records> <command> <most loads>
lw_case() {
  : > "$LW_LOG"
  expect_release "$1" "$2" "$3" '' '' bg
  (($(wc -l < "$LW_LOG") <= $4)) || { echo "FAIL: the hook loaded lock-words.sh $(wc -l < "$LW_LOG" | tr -d ' ') times, want $4 or fewer: $3"; failures=$((failures + 1)); }
}
lw_case block "$rw/live" "bash $lw/steps.sh > /x/p.log 2>&1" 1
release_has 'Step: .claude/skills/deliver/scripts/mutation-pass.sh'
lw_case allow "$rw/empty" "bash $lw/steps.sh > /x/p.log 2>&1" 1
lw_case allow "$rw/live" 'ls -la /x/run' 0
unset LW_LOG
hook="$hook_saved"
# A subagent bench passes in the foreground and in the background, beside its own live record and
# beside the record of another agent.
rw_rec "$rw/own" toolu_own 600 Agent toolu_own 'S3 slice agent'
rw_meta own toolu_own none 598
for dir in "$rw/own" "$rw/live"; do
  for run in 'scripts/with-lock.sh make bench FILTER=NavigationKeyBenchmark' "${bench_bare[@]}"; do
    expect_release allow "$dir" "$run" '' own
    expect_release allow "$dir" "$run" '' own bg
  done
done
expect_release block "$rw/own" "${bench_bare[0]}" '' '' bg
rm -f "$rw_sub/agent-own.meta.json"

# An Agent record 5 to 90 min old with no meta file gives a note: with no live agent the call runs and
# the note reaches the model as additionalContext JSON on stdout (each control byte escaped); with a
# live agent the note is in the block message. A later rule still blocks.
rw_rec "$rw/note" toolu_n3 900 Agent toolu_n3 'lost agent 3'
expect_release allow "$rw/note" "$P"
release_out '"additionalContext":"note: record toolu_n3 (lost agent 3) is 15 min old'
rw_rec "$rw/note-cr" toolu_n6 900 Agent toolu_n6 $'lost\ragent'
expect_release allow "$rw/note-cr" "$P"
python3 -I -c 'import json, sys; json.load(sys.stdin)' < "$tmp/release.out" 2> /dev/null && release_out 'lost\u000dagent' ||
  { echo "FAIL: release-wait note with a CR is no JSON: $(cat "$tmp/release.out")"; failures=$((failures + 1)); }
rw_rec "$rw/note-main" toolu_n4 900 SendMessage main 'resume main'
expect_release allow "$rw/note-main" "$P"
release_out ''
rw_rec "$rw/note-old" toolu_n5 6000 Agent toolu_n5 'agent 100 min old'
expect_release allow "$rw/note-old" "$P"
release_out ''
expect_release allow "$rw/note" 'git status'
release_out ''
expect_release block "$rw/note" "$P; git reset --hard"
rw_rec "$rw/note-live" toolu_n1 120 Agent toolu_n1 'fresh agent'
rw_rec "$rw/note-live" toolu_n2 900 Agent toolu_n2 'lost agent'
expect_release block "$rw/note-live" "$P"
release_has 'note: record toolu_n2 (lost agent) is 15 min old'

# A delegate_task record has no meta file. With a taskId in its key it is live for 90 min; with no
# taskId (its key is its file name) for 5 min, and then a note names it.
rw_dt=mcp__t3-code__delegate_task
rw_rec "$rw/dt" toolu_c7 1140 "$rw_dt" node:delegated-task:t1 'S1 slice'
expect_release block "$rw/dt" "${release_forms[0]}"
expect_release block "$rw/dt" "${release_forms[1]}"
for text in 'toolu_c7: mcp__t3-code__delegate_task "S1 slice"' 'a delegate_task child with no end text or task_cancel yet' \
  'taskId: node:delegated-task:t1' 'end text of its child (Delegated task <taskId> (<title>) [completed]: or [failed]:)' \
  'task_cancel of its taskId' 'For a delegate_task child that handed back while the hook still names it, a dead agent'; do
  release_has "$text"
done
expect_release allow "$rw/dt" "RELEASE_PAST=toolu_c7 $P"
rw_rec "$rw/dt-89" toolu_c7 5340 "$rw_dt" node:delegated-task:t1 'S1 slice'
expect_release block "$rw/dt-89" "$P"
rw_rec "$rw/dt-91" toolu_c7 5460 "$rw_dt" node:delegated-task:t1 'S1 slice'
expect_release allow "$rw/dt-91" "$P"
release_out ''
rw_rec "$rw/dt-4" toolu_d4 240 "$rw_dt" toolu_d4 'no task 4'
expect_release block "$rw/dt-4" "$P"
release_has 'its delegate_task call returned no taskId yet'
rw_rec "$rw/dt-6" toolu_d6 360 "$rw_dt" toolu_d6 'no task 6'
expect_release allow "$rw/dt-6" "$P"
release_out 'note: record toolu_d6 (no task 6) is 6 min old and has no taskId'
release_out 'delegate-record.sh is not active in this session'

# A script file that bash, sh, zsh, or dash runs is read and its lines classified, one level deep.
sd="$tmp/rw-scripts"
mkdir -p "$sd"
cat > "$sd/chain.sh" << 'EOF'
#!/bin/bash
R=/x/run
cd /x/wt || exit 1
export WITH_LOCK_MAX_WAIT=0
scripts/with-lock.sh make test-hooks DIRIGIBLE_HOOKS_ALL=1 > "$R/logs/hooks-pass-2.log" 2>&1
scripts/with-lock.sh make check-changed BASE=origin/main > "$R/logs/push-check-2.log" 2>&1
scripts/with-lock.sh scripts/land.sh 'Fix the hooks' "$R/pr.md" > "$R/logs/land-2.log" 2>&1
EOF
printf 'cd /x/wt\nWITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main > l 2>&1\n' > "$sd/push.sh"
printf 'cd /x/wt\nscripts/with-lock.sh scripts/land.sh "t" x/pr.md\n' > "$sd/do-land.sh"
printf 'R=/x/run\ncd /x/wt || exit 1\nscripts/with-lock.sh bash -c '"'"'time make test-hooks HOOK_TESTS=scripts/land.test.sh'"'"' > "$R/logs/s4-land.log" 2>&1; echo "exit $?" >> "$R/logs/s4-land.log"\n' > "$sd/tests.sh"
printf 'echo "scripts/with-lock.sh make check-changed BASE=origin/main"\nrg -n "make dmg" AGENTS.md\n' > "$sd/none.sh"
{ printf 'scripts/with-lock.sh make check-changed BASE=origin/main\n'; head -c 70000 /dev/zero | tr '\0' '#'; printf '\n'; } > "$sd/big.sh"
cat > "$sd/data.sh" << 'EOF'
#!/bin/bash
hook="$1"
cases=(
  'scripts/with-lock.sh make dmg'
  "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main"
)
for c in \
  'scripts/land.sh "t" x/pr.md' \
  'cd /x && scripts/with-lock.sh make dmg' \
  ; do
  printf '{"tool_input":{"command":"%s"}}' "$c" | "$hook"
done
P='WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main'
Q="scripts/land.sh 't' x/pr.md"
EOF
printf 'cd /x/wt\n"scripts/with-lock.sh" make dmg\n' > "$sd/quoted.sh"
for run in "R=$sd; rm -f \$R/x.status; (nohup bash \$R/chain.sh > /dev/null 2>&1 < /dev/null &)" \
  "bash $sd/push.sh" "sh $sd/do-land.sh" "cd $sd && bash push.sh > l 2>&1" "/bin/bash -x \"$sd/push.sh\"" \
  "cd /x/wt && R=$sd && (nohup bash -c \"WITH_LOCK_MAX_WAIT=0 bash \$R/push.sh > l 2>&1\" > /dev/null 2>&1 < /dev/null &)" \
  "export S=$sd; bash \${S}/do-land.sh" "bash $sd/quoted.sh"; do
  expect_release block "$rw/live" "$run"
done
expect_release block "$rw/live" 'bash push.sh' "$sd"
for run in "bash $sd/tests.sh" "sh $sd/none.sh" "bash $sd/big.sh" "bash $sd/missing.sh" "bash \$UNSET/push.sh" \
  "bash -c 'echo hi'" "WITH_LOCK_RUN_ONLY=1 scripts/with-lock.sh scripts/probe.sh $tmp bash $sd/push.sh" "rg -n 'bash $sd/push.sh' notes.txt" \
  "WITH_LOCK_MAX_WAIT=0 bash $sd/tests.sh" "bash $sd/data.sh hook.sh" "P='scripts/with-lock.sh make dmg'; echo \"\$P\""; do
  expect_release allow "$rw/live" "$run"
done
# The script lines split with one tr call: a 62 KB script with separators on each line and a push check
# on its last line blocks in under 5 s.
{ for ((i = 0; i < 1300; i++)); do printf 'x=$((i + 1)); echo "a|b" | cut -d"|" -f1 & wait\n'; done
  printf 'scripts/with-lock.sh make check-changed BASE=origin/main\n'; } > "$sd/long.sh"
rw_start=$(date +%s)
expect_release block "$rw/live" "bash $sd/long.sh"
(($(date +%s) - rw_start < 5)) || { echo "FAIL: release-wait took $(($(date +%s) - rw_start)) s for a 62 KB script"; failures=$((failures + 1)); }
# The words of a segment are read in one pass: a 4000-word line with a bash <file> word ends in under 2 s.
rw_ms() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
rw_start=$(rw_ms)
expect allow "echo $(seq -f 'w%g' 1 4000 | tr '\n' ' '); bash x.sh"
rw_took=$(($(rw_ms) - rw_start))
((rw_took < 2000)) || { echo "FAIL: the hook took $rw_took ms for a 4000-word line with a bash <file> word"; failures=$((failures + 1)); }
# The subagent rule reads the same script lines: a release call in a script is a wait with no limit.
expect_release block "$rw/empty" "bash $sd/push.sh" '' a1
expect_release allow "$rw/empty" "bash $sd/tests.sh" '' a1
fi # release-wait

# Real allowed commands (TDD-002). Each line of allowed-commands.txt is "<mode><TAB><command>", or a
# comment that starts with #. The hook gets each command as a lead input with the cwd $cp_dir: with no
# record (each mode), and as a background call beside a live lock-step record (mode any). A free line
# is a long background step of the lead that a release wait can hold.
if case_block corpus; then
corpus="$(dirname "$0")/allowed-commands.txt" cp_dir="$tmp/corpus"
# The bash <file> lines of the corpus name these step files of past runs, relative to $cp_dir.
cp_runs="$cp_dir/.scratchpads/runs"
mkdir -p "$tmp/corpus-none" "$cp_runs/2026-11-04-needs-repro" "$cp_runs/2026-11-07-upkeep-release-wait/logs" \
  "$cp_runs/2026-11-16-upkeep-twentyfirst/controls"
cat > "$cp_runs/2026-11-04-needs-repro/locked-steps.sh" <<'EOF'
set -euo pipefail
cd /x/main
R=.scratchpads/runs/2026-11-04-needs-repro
export WITH_LOCK_RUN_ONLY=1
scripts/with-lock.sh scripts/probe.sh "$PWD/$R/probes/p2" bash "$PWD/$R/probes/p2/run-red.sh" || true
scripts/with-lock.sh scripts/probe.sh "$PWD/$R/probes/p2" bash "$PWD/$R/probes/p2/run-green.sh" || true
tail -n 15 "$R/probes/p2/red.log" "$R/probes/p2/green.log"
EOF
cat > "$cp_runs/2026-11-07-upkeep-release-wait/logs/gate2-1-steps.sh" <<'EOF'
R=/x/main/.scratchpads/runs/2026-11-07-upkeep-release-wait
cd /x/wt-upkeep-rw || exit 1
scripts/with-lock.sh bash -c 'time make test-hooks HOOK_TESTS=.claude/hooks/git-guardrails.test.sh HOOK_CASES=release-wait' > "$R/logs/gate2-1-red.log" 2>&1; echo "exit $?" >> "$R/logs/gate2-1-red.log"
git apply "$R/logs/gate2-1-fix.patch" > "$R/logs/gate2-1-apply.log" 2>&1; echo "exit $?" >> "$R/logs/gate2-1-apply.log"
scripts/with-lock.sh scripts/probe.sh "$R/probes/gate2-1" bash "$R/probes/gate2-1/time-hook.sh" "$R/probes/gate2-1/head" HEAD 2000 4000 8000 > "$R/logs/gate2-1-time-head.log" 2>&1; echo "exit $?" >> "$R/logs/gate2-1-time-head.log"
scripts/with-lock.sh bash -c 'time make test-hooks HOOK_TESTS=.claude/hooks/git-guardrails.test.sh HOOK_CASES=release-wait' > "$R/logs/gate2-1-green.log" 2>&1; echo "exit $?" >> "$R/logs/gate2-1-green.log"
EOF
cat > "$cp_runs/2026-11-16-upkeep-twentyfirst/controls/pass-locked-steps.sh" <<'EOF'
set -uo pipefail
tree=/x/wt-upkeep
controls=/x/main/.scratchpads/runs/2026-11-16-upkeep-twentyfirst/controls
cd "$tree" || exit 2
WITH_LOCK_MAX_HOLD=7000 .claude/skills/deliver/scripts/mutation-pass.sh "$tree" "$controls/batch.txt" > "$controls/pass-1.log" 2>&1
echo "exit $?" >> "$controls/pass-1.log"
EOF
rw_rec "$tmp/corpus-live" toolu_corpus 600 Agent toolu_corpus 'S1 slice agent'
rw_meta corpus toolu_corpus none 598
# The record is live: a release call beside it blocks, so an allow of an any line beside it counts.
expect_release block "$tmp/corpus-live" "${release_forms[0]}" "$cp_dir" '' bg
cp_lines=0 cp_eval=0 cp_lock=0 cp_row=0
while IFS= read -r cp_line; do
  [[ -z "$cp_line" || "$cp_line" == '#'* ]] && continue
  cp_mode="${cp_line%%$'\t'*}" cp_cmd="${cp_line#*$'\t'}"
  [[ "$cp_line" == *$'\t'* && "$cp_mode" =~ ^(any|free)$ ]] ||
    { echo "FAIL: corpus line with no mode word any or free and a tab: ${cp_line:0:160}"; failures=$((failures + 1)); continue; }
  cp_lines=$((cp_lines + 1))
  [[ "$cp_cmd" == *scripts/eval/run.sh* && "$cp_cmd" == *--holdout-keys* ]] && cp_eval=$((cp_eval + 1))
  [[ "$cp_cmd" == *scripts/with-lock.sh* ]] && cp_lock=$((cp_lock + 1))
  [[ "$cp_cmd" == *log-decision.sh* ]] && cp_row=$((cp_row + 1))
  for cp_case in none live; do
    [[ "$cp_case" == none || "$cp_mode" == any ]] || continue
    plutil -create xml1 "$input"
    plutil -insert cwd -string "$cp_dir" "$input"
    plutil -insert tool_input -dictionary "$input"
    plutil -insert tool_input.command -string "$cp_cmd" "$input"
    if [[ "$cp_case" == live ]]; then
      plutil -insert tool_input.run_in_background -bool true "$input"
      plutil -insert tool_input.timeout -integer 7200000 "$input"
    fi
    plutil -convert json "$input"
    DIRIGIBLE_LOCK_AGENTS="$tmp/corpus-$cp_case" "$hook" < "$input" > /dev/null 2> "$tmp/corpus.err"
    [[ $? -ne 2 ]] || { echo "FAIL: corpus $cp_mode line blocked $( [[ $cp_case == none ]] && echo 'with no record' || echo 'beside a live record'): ${cp_cmd:0:160}: $(head -c 200 "$tmp/corpus.err" | tr '\n' ' ')"; failures=$((failures + 1)); }
  done
done < <(cat "$corpus" 2> /dev/null)
((cp_lines >= 30 && cp_eval >= 5 && cp_lock >= 5 && cp_row >= 5)) ||
  { echo "FAIL: $corpus has $cp_lines command lines ($cp_eval eval run.sh --holdout-keys, $cp_lock with-lock.sh, $cp_row log-decision.sh); it needs 30, and 5 of each kind"; failures=$((failures + 1)); }
rm -f "$rw_sub/agent-corpus.meta.json"
fi # corpus
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
gc() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty "${@:2}"; }

if case_block post-commit; then
# The shipped post-commit hook deletes .scratchpads/commit-msg.txt of the work tree that commits, so
# the next `git commit -F` cannot take a stale message. A worktree uses the hooks folder of the main
# checkout, and the hook deletes the file of the worktree only. With no file, the hook exits 0.
post_fail() { echo "FAIL: post-commit: $1"; failures=$((failures + 1)); }
git init -q "$tmp/r"
mkdir -p "$tmp/r/.githooks" "$tmp/r/.scratchpads"
cp "$(dirname "$0")/../../.githooks/post-commit" "$tmp/r/.githooks/" || post_fail 'no .githooks/post-commit'
git -C "$tmp/r" config core.hooksPath "$tmp/r/.githooks"
printf 'one\n' > "$tmp/r/.scratchpads/commit-msg.txt"
gc "$tmp/r" -F .scratchpads/commit-msg.txt || post_fail 'a commit with -F failed'
[[ ! -e "$tmp/r/.scratchpads/commit-msg.txt" ]] || post_fail 'the message file is still there after the commit'
gc "$tmp/r" -m two || post_fail 'a commit with no message file failed'
(cd "$tmp/r" && .githooks/post-commit) || post_fail "the hook exits $? with no message file"
git -C "$tmp/r" worktree add -q "$tmp/w" 2>/dev/null || post_fail 'git worktree add failed'
mkdir -p "$tmp/w/.scratchpads"
printf 'main\n' > "$tmp/r/.scratchpads/commit-msg.txt"
printf 'three\n' > "$tmp/w/.scratchpads/commit-msg.txt"
gc "$tmp/w" -F .scratchpads/commit-msg.txt || post_fail 'a commit in the worktree failed'
[[ ! -e "$tmp/w/.scratchpads/commit-msg.txt" ]] || post_fail 'the worktree message file is still there'
[[ "$(cat "$tmp/r/.scratchpads/commit-msg.txt" 2>/dev/null)" == main ]] || post_fail 'a worktree commit deleted the file of the main checkout'

fi # post-commit
if case_block pre-commit; then
# The shipped pre-commit hook refuses a commit when core.hooksPath is not exactly .githooks: with an
# absolute path, each worktree runs the hooks of the main checkout. With .githooks, the hook of the
# worktree runs make lint, which fails here because the repo has no Makefile.
pre_fail() { echo "FAIL: pre-commit: $1"; failures=$((failures + 1)); }
git init -q "$tmp/p"
mkdir -p "$tmp/p/.githooks"
cp "$(dirname "$0")/../../.githooks/pre-commit" "$tmp/p/.githooks/" || pre_fail 'no .githooks/pre-commit'
mkdir -p "$tmp/p/scripts"
cp "$(dirname "$0")/../../scripts/check-sizes.sh" "$(dirname "$0")/../../scripts/check-waits.sh" "$tmp/p/scripts/" \
  || pre_fail 'no scripts/check-sizes.sh or scripts/check-waits.sh'
: > "$tmp/p/scripts/check-sizes.allow"
: > "$tmp/p/scripts/check-waits.allow"
git -C "$tmp/p" add .githooks scripts
gc "$tmp/p" -m hook || pre_fail 'the commit of the hook failed'
git -C "$tmp/p" worktree add -q "$tmp/pw" 2>/dev/null || pre_fail 'git worktree add failed'
git -C "$tmp/p" config core.hooksPath "$tmp/p/.githooks"
gc "$tmp/pw" -m absolute 2>"$tmp/err" && pre_fail 'a commit with an absolute hooks path passed'
grep -q 'make setup' "$tmp/err" || pre_fail 'the refusal does not name make setup'
git -C "$tmp/p" config core.hooksPath .githooks
mkdir -p "$tmp/pw/Sources/M"
echo '// a' > "$tmp/pw/Sources/M/A.swift"
gc "$tmp/pw" -m relative 2>"$tmp/err" && pre_fail 'a commit with no Makefile passed'
grep -q lint "$tmp/err" || pre_fail 'the hook of the worktree did not run make lint'
grep -q 'make setup' "$tmp/err" && pre_fail 'the hook names make setup with the .githooks path'
# A stamped make check-changed run marks its tree with the pid of run-checks.sh and its start time,
# and a commit during the run makes its pass stamp useless. A live mark refuses the commit and names
# the pid and its command. A pid whose start time differs (a reused pid), a dead pid, and a mark of
# another tree do not refuse. $$ of this shell is the live pid.
marks="$(git -C "$tmp/pw" rev-parse --path-format=absolute --git-dir)/dirigible-check-running"
mkdir -p "$marks" && ps -o lstart= -p $$ > "$marks/$$"
gc "$tmp/pw" -m marked 2>"$tmp/err" && pre_fail 'a commit during a check-changed run passed'
grep -q "make check-changed run (pid $$: .*bash" "$tmp/err" || pre_fail "the refusal does not name the pid and its command: $(cat "$tmp/err")"
gc "$tmp/p" -m other 2>"$tmp/err"
grep -q 'check-changed run' "$tmp/err" && pre_fail 'a mark of the worktree refused a commit in the main tree'
echo 'Mon Jan  1 00:00:00 2001' > "$marks/$$"
gc "$tmp/pw" -m reused 2>"$tmp/err"
grep -q lint "$tmp/err" || pre_fail "a reused pid did not reach make lint: $(cat "$tmp/err")"
rm "$marks/$$"
dead="$(bash -c 'echo $$')"
echo 'Mon Jan  1 00:00:00 2001' > "$marks/$dead"
gc "$tmp/pw" -m dead 2>"$tmp/err"
grep -q lint "$tmp/err" || pre_fail "a dead pid did not reach make lint: $(cat "$tmp/err")"
# Before make lint, the hook runs scripts/check-sizes.sh and scripts/check-waits.sh on the working
# tree. A Swift file of 401 lines under Sources/, or a raw .wait(timeout: under Tests/, with no
# allow entry, refuses the commit before make lint. 400 lines, and a raw wait under Sources/, pass.
mkdir -p "$tmp/pw/Sources/M" "$tmp/pw/Tests/T"
seq 401 | sed 's|^|// |' > "$tmp/pw/Sources/M/Big.swift"
gc "$tmp/pw" -m big 2>"$tmp/err" && pre_fail 'a commit with a Swift file of 401 lines passed'
grep -q '^check-sizes: Sources/M/Big.swift: 401 lines, over 400' "$tmp/err" || pre_fail "a file of 401 lines gave no check-sizes line: $(cat "$tmp/err")"
grep -q lint "$tmp/err" && pre_fail 'make lint ran before the size gate'
seq 400 | sed 's|^|// |' > "$tmp/pw/Sources/M/Big.swift"
gc "$tmp/pw" -m fits 2>"$tmp/err"
grep -q check-sizes "$tmp/err" && pre_fail 'a Swift file of 400 lines failed the size gate'
grep -q lint "$tmp/err" || pre_fail "a Swift file of 400 lines did not reach make lint: $(cat "$tmp/err")"
rm "$tmp/pw/Sources/M/Big.swift"
echo 'group.wait(timeout: .now() + 1)' > "$tmp/pw/Tests/T/W.swift"
gc "$tmp/pw" -m wait 2>"$tmp/err" && pre_fail 'a commit with a raw wait under Tests/ passed'
grep -qF 'check-waits: Tests/T/W.swift:1: a raw .wait(timeout: with no allow entry' "$tmp/err" || pre_fail "a raw wait under Tests/ gave no check-waits line: $(cat "$tmp/err")"
grep -q lint "$tmp/err" && pre_fail 'make lint ran before the wait gate'
mv "$tmp/pw/Tests/T/W.swift" "$tmp/pw/Sources/M/W.swift"
gc "$tmp/pw" -m source-wait 2>"$tmp/err"
grep -q check-waits "$tmp/err" && pre_fail 'a raw wait under Sources/ failed the wait gate'
grep -q lint "$tmp/err" || pre_fail "a raw wait under Sources/ did not reach make lint: $(cat "$tmp/err")"
# make lint runs only when the working tree has a changed or new .swift path or a changed
# .swift-format. A stub make records its calls: a change of only a doc makes none.
mkdir -p "$tmp/bin"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$tmp/make.calls" > "$tmp/bin/make"
chmod +x "$tmp/bin/make"
rm -rf "$tmp/pw/Sources" "$tmp/pw/Tests"
lint_ran() { # <commit message>: commit in the worktree with the stub make; true when it ran make lint
  rm -f "$tmp/make.calls"
  PATH="$tmp/bin:$PATH" gc "$tmp/pw" -m "$1" 2>"$tmp/err" || pre_fail "the commit $1 failed: $(cat "$tmp/err")"
  [[ -s "$tmp/make.calls" ]]
}
settle() { git -C "$tmp/pw" add -A && lint_ran settle || true; }
mkdir -p "$tmp/pw/docs"
echo x > "$tmp/pw/docs/x.md"
! lint_ran doc-only || pre_fail 'a change of only docs/x.md ran make lint'
settle
mkdir -p "$tmp/pw/Sources/M"
echo '// a' > "$tmp/pw/Sources/M/T.swift"
echo '{}' > "$tmp/pw/.swift-format"
git -C "$tmp/pw" add -A
lint_ran staged-new || pre_fail 'a new staged .swift file did not run make lint'
echo '// b' >> "$tmp/pw/Sources/M/T.swift"
lint_ran changed-swift || pre_fail 'a changed .swift file did not run make lint'
settle
echo '// c' > "$tmp/pw/Sources/M/New.swift"
lint_ran untracked-swift || pre_fail 'a new untracked .swift file did not run make lint'
rm "$tmp/pw/Sources/M/New.swift"
echo '{"version": 1}' > "$tmp/pw/.swift-format"
lint_ran changed-format || pre_fail 'a changed .swift-format did not run make lint'

fi # pre-commit
if case_block commit-msg; then
# The shipped commit-msg hook has no word pair check: a message with a pair that no staged file shows commits.
msg_fail() { echo "FAIL: commit-msg: $1"; failures=$((failures + 1)); }
m="$tmp/m"
git init -q "$m"
mkdir -p "$m/.githooks"
cp "$(dirname "$0")/../../.githooks/commit-msg" "$m/.githooks/" || msg_fail 'no .githooks/commit-msg'
git -C "$m" config core.hooksPath .githooks
echo x > "$m/other.txt"
git -C "$m" add other.txt
gc "$m" -m 'x: 10 before, 11 after' || msg_fail 'a word pair that no staged file shows was refused'

# The commit-msg hook refuses a staged change that cuts graded eval key text (evals-for.sh
# --staged): a key term that the staged file holds fewer times than the file at HEAD, or a 5-word
# run of the key points that the file at HEAD holds and the staged file does not. An insertion next
# to kept key text, a key that changes in the same commit, and a body line `Eval keys: <IDs>` pass.
k="$tmp/k" deliver=.claude/skills/deliver/SKILL.md
git init -q "$k"
mkdir -p "$k/.githooks" "$k/scripts" "$k/docs/workflow" "$k/.claude/skills/deliver"
cp "$(dirname "$0")/../../.githooks/commit-msg" "$k/.githooks/"
cp "$(dirname "$0")/../../scripts/evals-for.sh" "$k/scripts/"
git -C "$k" config core.hooksPath .githooks
cat > "$k/docs/workflow/evals.md" <<'EOF'
# Evals

## Scenarios

| ID | Type | Source | Question | Key points | Files | Old | New |
|---|---|---|---|---|---|---|---|
| E2 | policy | s | q | (c) Before the push: `make check-changed BASE=origin/main`, which picks `check-docs`. | `.claude/skills/deliver/SKILL.md` | - | - |
| E37 | policy | s | q | (b) Run the same command again with `run_in_background`. | `AGENTS.md` | - | - |
EOF
printf 'Then run the push check `make check-changed BASE=origin/main` with `run_in_background`.\nCommit nothing until it ends.\n' > "$k/$deliver"
printf 'When the call stops, run the same command again with `run_in_background`; a subagent waits.\n' > "$k/AGENTS.md"
git -C "$k" add -A
gc "$k" -m base || msg_fail 'the first commit of the eval key fixture was refused'
key_refused() {
  gc "$k" "$@" 2>"$tmp/err" && msg_fail "a cut of eval key text passed: $*"
  grep -q "$want_id" "$tmp/err" || msg_fail "the refusal names no $want_id: $(cat "$tmp/err")"
}
printf 'Commit nothing until it ends.\n' > "$k/$deliver"
git -C "$k" add -A
want_id=E2 key_refused -m 'cut the push check'
printf 'Then run the push check `make check-changed BASE=origin/main` with `run_in_background`.\nCommit no file until it ends.\n' > "$k/$deliver"
git -C "$k" add -A
gc "$k" -m 'keep the key line' 2>"$tmp/err" || msg_fail "a change that keeps the key text was refused: $(cat "$tmp/err")"
printf 'When the call stops, run the same command again with `run_in_background` and a Bash `timeout` of 7200000; a subagent waits.\n' > "$k/AGENTS.md"
git -C "$k" add -A
gc "$k" -m 'insert a timeout' 2>"$tmp/err" || msg_fail "an insertion next to kept key text was refused: $(cat "$tmp/err")"
sed -i '' 's|BASE=origin/main`, which|BASE=<base>`, which|' "$k/docs/workflow/evals.md"
sed -i '' 's|BASE=origin/main|BASE=<base>|' "$k/$deliver"
git -C "$k" add -A
gc "$k" -m 'a rule and its key' 2>"$tmp/err" || msg_fail "a rule and its key change in one commit was refused: $(cat "$tmp/err")"
printf 'A subagent waits.\n' > "$k/AGENTS.md"
git -C "$k" add -A
want_id=E37 key_refused -m 'cut the rerun'
gc "$k" -m $'cut the rerun\n\nEval keys: E37' 2>"$tmp/err" || msg_fail "a cut with an Eval keys line was refused: $(cat "$tmp/err")"

fi # commit-msg
if case_block agent-guard; then
# The second hook, agent-guard.sh, refuses an Agent call with worktree isolation: such a worktree does
# not fit the run layout, and its creation can set the hooks path of the shared git config. It also
# refuses a brief of Agent, SendMessage, or delegate_task with a wrong commit message path, and a
# brief with a lock step while a long call holds the build lock, and a delegate_task to a provider
# before its recorded rate-limit reset.
agent_hook="$(dirname "$0")/agent-guard.sh"
# The hooks pass and the push check run this file as a release call, and a bench can hold the lock,
# so a case of the real repo must name no lock step: the real --long-holder would see that holder.
# The lock-step cases below use a temp repo with a fake lock state. The pattern is lock_re of
# agent-guard.sh, read from its line with the lists of scripts/lock-words.sh.
lock_words_src="$(cd "$(dirname "$0")/../../scripts" && pwd)/lock-words.sh"
real_lock_re="$(bash -c ". '$lock_words_src'; $(sed -n '/^lock_re=/p' "$(dirname "$0")/agent-guard.sh"); printf '%s' \"\$lock_re\"")"
no_lock_step() { # <text>
  ! grep -qE "$real_lock_re" <<< "$1" || { echo "FAIL: agent-guard: a real-repo brief case names a lock word: $1"; failures=$((failures + 1)); }
}
expect_agent() {
  local want="$1" json="$2" got
  no_lock_step "$json"
  printf '%s' "$json" | "$agent_hook" 2>"$tmp/agent-err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: agent-guard: expected $want, got $got: $json"; failures=$((failures + 1)); }
}
expect_agent block '{"tool_input":{"description":"d","prompt":"p","isolation":"worktree"}}'
grep -q 'git worktree add' "$tmp/agent-err" ||
  { echo "FAIL: the agent-guard block message does not name git worktree add: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
expect_agent allow '{"tool_input":{"description":"d","prompt":"p"}}'
python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
ok = any(e.get("matcher") == "Agent|SendMessage|mcp__t3-code__delegate_task"
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/agent-guard.sh") for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$settings" 2>/dev/null || { echo "FAIL: .claude/settings.json does not register agent-guard.sh for Agent, SendMessage, and delegate_task"; failures=$((failures + 1)); }

# A brief with a git commit -F or --file path other than .scratchpads/commit-msg.txt blocks, in the field of each tool. The correct path (also in
# backticks or before a ; or .), - (stdin), and text with no path pass.
# expect_brief <want> <tool name, or - for none> <field> <text> [isolation] [cwd]
expect_brief() {
  local want="$1" got
  no_lock_step "$4"
  plutil -create xml1 "$input"
  [[ "$2" == - ]] || plutil -insert tool_name -string "$2" "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert "tool_input.$3" -string "$4" "$input"
  [[ -z "${5:-}" ]] || plutil -insert tool_input.isolation -string "$5" "$input"
  [[ -z "${6:-}" ]] || plutil -insert cwd -string "$6" "$input"
  plutil -convert json "$input"
  "$agent_hook" < "$input" 2>"$tmp/agent-err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: agent-guard: expected $want, got $got: $2 $3: $4"; failures=$((failures + 1)); }
}
expect_brief block Agent prompt $'Commit:\nrun git commit -F .scratchpads/runs/x/commit-msg.txt'
grep -qF 'git commit -F .scratchpads/commit-msg.txt' "$tmp/agent-err" && grep -qF 'put the text in a file in the run folder' "$tmp/agent-err" ||
  { echo "FAIL: the agent-guard brief message does not name the path and the data route: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
for text in 'git commit -F /abs/.scratchpads/commit-msg.txt' 'git commit --file=.scratchpads/runs/x/commit-msg.txt' \
  'git commit -q --no-verify -F .scratchpads/runs/x/commit-msg.txt' 'Run `git commit -F .scratchpads/runs/x/commit-msg.txt` at the end.'; do
  expect_brief block Agent prompt "$text"
done
expect_brief block SendMessage message 'Then git commit -F .scratchpads/runs/x/commit-msg.txt.'
expect_brief block Agent prompt 'Commit with git commit -F ../main/.scratchpads/commit-msg.txt, then rg -F foo bar'
expect_brief block Agent prompt 'git commit -F ../other/.scratchpads/commit-msg.txt then git commit -F .scratchpads/commit-msg.txt'
expect_brief allow Agent prompt 'git commit -F .scratchpads/commit-msg.txt, and find the row with rg -F .scratchpads/runs/x/rows .gitignore'
expect_brief allow Agent prompt 'Commit with git commit -m fix, then find the row with rg -F .scratchpads/runs/x/rows .gitignore'
expect_brief allow Agent prompt 'Commit with git commit -m fix. Then find the row with rg -F .scratchpads/runs/x/rows .gitignore'
expect_brief allow Agent prompt 'Run git commit -m fix && rg -F .scratchpads/runs/x/rows .gitignore'
# A separator inside the quoted message does not end the commit.
expect_brief block Agent prompt 'Run git commit -m "fix; thing" -F ../main/.scratchpads/commit-msg.txt'
expect_brief block mcp__t3-code__delegate_task task 'git commit -F /abs/.scratchpads/commit-msg.txt'
expect_brief block - prompt 'git commit -F .scratchpads/runs/x/commit-msg.txt'
# Any other path blocks, also a placeholder (the agent would commit with the file of the run folder).
for text in 'git commit -F <file>' 'git commit -F <file in the run folder>' 'git commit -F <msgfile>' 'git commit -F RUN/msg-3a.txt' \
  'git commit -F msg.txt' 'git commit --file=msg.txt' 'Commit with git commit -F $R/logs/s4-msg.txt.' \
  'Commit with git commit -F $R/logs/x.txt.' 'Commit with git commit -aF msg.txt.' \
  'Run git -C /x/wt commit -F .scratchpads/runs/x/msg.txt at the end.' 'Run git -C ../wt commit -F msg.txt at the end.' \
  'Commit with git commit -F .scratchpads/commit-msg.txt -F msg.txt at the end.' 'Commit with git commit -F "" at the end.' \
  'Commit with git commit -F " msg.txt" at the end.' \
  'Run git commit -F - < /x/other/msg.txt at the end.' 'Run cat /x/msg.txt | git commit -F - at the end.' \
  "Don't commit the way of the user's note: git commit -F ../x/msg.txt at the end." \
  'Commit with "git commit -F ../x/msg.txt" at the end.' "Tell the agent: 'run git commit -F ../x/m when you finish'."; do
  expect_brief block Agent prompt "$text"
done
for text in 'git commit -F .scratchpads/commit-msg.txt' 'git commit --file=.scratchpads/commit-msg.txt' \
  'Run `git commit -F .scratchpads/commit-msg.txt`; never commit a .scratchpads file.' \
  'Commit with `git commit -F .scratchpads/commit-msg.txt`.' 'Use `git commit -F` with the message file.' \
  'Commit with git commit -aF .scratchpads/commit-msg.txt.' 'Commit with git commit -F ".scratchpads/commit-msg.txt" at the end.' \
  'Run git -C /x/wt commit -F .scratchpads/commit-msg.txt at the end.' 'Commit with git commit -F - and a heredoc.' \
  "Find the old text with rg -n 'git commit -F' .claude first." "Find the old text with rg -n 'git commit -F <file>' docs." \
  'Run `git commit` then search with rg -F foo bar.' 'Commit with git commit -m "rg -F case" at the end.' \
  'Read run.md and continue at S6.'; do
  expect_brief allow Agent prompt "$text"
done
expect_brief allow SendMessage message 'git commit -F .scratchpads/commit-msg.txt, then hand back.'
expect_brief allow mcp__t3-code__delegate_task task 'Fix the tests and commit.' worktree
# A quote that holds git commit is data when a block report touches it (see reports() in
# commit-files.awk). An instruction near a block word, a report that the quote does not touch, and a
# commit with no quote stay blocked.
for text in '8. Brief that named `git commit -F <run folder file>` was blocked by agent-guard.' \
  '(3) git-guardrails refused `git commit -F <run folder file>`' \
  '8. Brief that named "git commit -F <run folder file>" was blocked by agent-guard.' \
  'BLOCKED by .claude/hooks/git-guardrails.sh: `git commit -F rows/x.txt`' \
  "BLOCKED by .claude/hooks/git-guardrails.sh: 'git commit -F rows/x.txt' reads a commit message file other than .scratchpads/commit-msg.txt, which can be the file of another work tree. Write .scratchpads/commit-msg.txt in the work tree that commits and pass that relative path (git commit -F .scratchpads/commit-msg.txt), or pass the message on stdin (git commit -F - with a heredoc)." \
  "PreToolUse:Bash hook error: [\"\$CLAUDE_PROJECT_DIR\"/.claude/hooks/git-guardrails.sh]: BLOCKED by .claude/hooks/git-guardrails.sh: 'git commit -F rows/x.txt' reads a commit message file other than .scratchpads/commit-msg.txt, which can be the file of another work tree."; do
  expect_brief allow Agent prompt "$text"
done
for text in 'If the commit is blocked, run `git commit -F rows/x.txt`.' \
  'Run `git commit -F rows/x.txt`; it was blocked before.' \
  'If the commit is blocked, run git commit -F rows/x.txt.' \
  'Commit with `git commit -F <run>/rows/s4-commit-msg.txt`.'; do
  expect_brief block Agent prompt "$text"
done
for text in 'The first gate-fix brief was blocked by agent-guard.sh for `git commit -F <run-folder file>`.' \
  'The first gate-fix brief was blocked by .claude/hooks/agent-guard.sh: `git commit -F <run-folder file>`.' \
  'The brief was refused by agent-guard.sh for `git commit -F <x>`.' \
  'The brief was Blocked by agent-guard.sh for "git commit -F <x>".' \
  "The brief was REFUSED BY agent-guard.sh: 'git commit -F <x>'." \
  'Blocked by agent-guard.sh for: `git commit -F <x>`.' \
  'It failed once. The brief was blocked by agent-guard.sh for `git commit -F <x>`.' \
  'The brief has been blocked by agent-guard.sh for `git commit -F <x>`.' \
  '1) It was blocked by agent-guard.sh for `git commit -F <file>`.'; do
  expect_brief allow Agent prompt "$text"
done
for text in 'If blocked by agent-guard.sh for this, run `git commit -F rows/x.txt`.' \
  'When blocked by agent-guard.sh for `git commit -F a`, run `git commit -F rows/x.txt`.' \
  'Do not get blocked by the hook: `git commit -F rows/x.txt`.' \
  'The brief was blocked by agent-guard.sh for git commit -F rows/x.txt.' \
  'The brief was blocked by agent-guard.sh for `git commit -F <x>` and `git commit -F x.txt`.' \
  'blocked by agent-guard.sh for `git commit -F <x>`; next run git commit -F rows/y.txt.' \
  'If blocked by agent-guard.sh: `git commit -F rows/x.txt`.' \
  'When refused by git-guardrails.sh for `git commit -F rows/x.txt`, retry.' \
  'Unless blocked by policy: `git commit -F rows/x.txt`.' \
  'Do not get blocked by agent-guard.sh for `git commit -F rows/x.txt`; run it.' \
  'To avoid being blocked by agent-guard.sh for `git commit -F rows/x.txt`, write the file elsewhere.' \
  'Commit with refused by x for: `git commit -F ../other/msg.txt`' \
  'Next step: blocked by hook for "git commit -F rows/x.txt" so retry with it.' \
  'If agent-guard.sh refused by mistake for `git commit -F rows/x.txt`, run it again.' \
  'It is blocked by default for `git commit -F rows/x.txt`: run it after the gate.' \
  'Never get blocked by agent-guard.sh for `git commit -F rows/x.txt`; run it with the path.' \
  'Refused by agent-guard.sh: `git commit -F rows/x.txt`. Run it again after the fix.' \
  'The brief was blocked by policy for `git commit -F rows/x.txt`.' \
  'Once blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'Unless refused by agent-guard.sh: `git commit -F rows/x.txt`.' \
  'Do not get blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  $'Don\'t get blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'The brief was blocked by agent-guard.sh for `git commit -F rows/x.txt` so run it again.' \
  'Commit now; refused by agent-guard.sh for: `git commit -F ../other/msg.txt`' \
  'Please commit, blocked by agent-guard.sh for `git commit -F ../other/msg.txt`.' \
  'Run this, blocked by agent-guard.sh for `git commit -F ../other/msg.txt`' \
  'Do it now - blocked by agent-guard.sh for `git commit -F ../other/msg.txt`.' \
  'Commit now and it was blocked by agent-guard.sh for `git commit -F ../other/msg.txt`.' \
  'We run it now, it was blocked by agent-guard.sh for `git commit -F ../other/msg.txt`.' \
  'The agent must commit now and it was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'The step is: run this and it was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  $'The fix is to commit now \xe2\x80\x94 it was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  $'The fix is to commit now \xe2\x80\x93 it was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'The plan: commit now and it was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'We run it now and it was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'The fix: commit it the brief was blocked by agent-guard.sh for `git commit -F rows/x.txt`.' \
  'The brief was blocked by policy for `git commit -F <x>`.' \
  'Once blocked by agent-guard.sh for `git commit -F <x>`.' \
  'The brief was blocked by agent-guard.sh for `git commit -F <x>` so run it again.' \
  'The fix: commit it the brief was blocked by agent-guard.sh for `git commit -F <x>`.' \
  'Commit again. It was blocked by agent-guard.sh for `git commit -F ../other/.scratchpads/commit-msg.txt`.' \
  'Commit again! It was blocked by agent-guard.sh for `git commit -F ../other/.scratchpads/commit-msg.txt`.' \
  'The agent retries the step that was blocked by agent-guard.sh for `git commit -F ../other/.scratchpads/commit-msg.txt`.' \
  $'It was blocked by agent-guard.sh for `git commit -F ../other/.scratchpads/commit-msg.txt`.\nRun that command again now.'; do
  expect_brief block Agent prompt "$text"
done
# The Bash path does not read a report: git-guardrails.sh blocks the same commit in a command.
expect block 'git commit -F rows/x.txt'
expect block 'echo blocked; git commit -F rows/x.txt'

# Review-field cases. A brief that names a review-plan-<n>.md or review-diff-<n>.md file of the open
# run of the hook cwd (open-run.py) is refused while scripts/check-plan.sh exits 1 for that run.
# ag_run <repo> <slug> <status> <row time> <siblings: yes or no>: a run folder in a git repo that
# check-plan.sh passes, plus a review-diff-1.md whose Act on item has an Invariant field and, with
# yes, a Siblings field.
ag_run() {
  local f="$1/.scratchpads/runs/$2"
  mkdir -p "$f"
  [[ -d "$1/.git" ]] || git init -q "$1"
  printf '# Analysis: x\n\n## Unknowns\n\n| id | parent | question | resolver | answer | row |\n|---|---|---|---|---|---|\n| U1 | - | Q? | default | A. | %s |\n' "$4" > "$f/analysis.md"
  printf '# Plan: x\n\nAgents: B = S1.\n\n## Slices\n\n### S1 one\n\n- Check: `targets: check-fast`.\n' > "$f/plan.md"
  printf '%s\t1\tx\ty\tz\tw\n' "$4" > "$f/decisions.tsv"
  printf '# Run %s\n\n- Status: %s\n- Branch: chore/%s\n' "$2" "$3" "$2" > "$f/run.md"
  printf '# Code gate, round 1\n\n## Act on\n\n1. (warning, x) A fix.\n   - Invariant: i.\n' > "$f/review-diff-1.md"
  [[ "$5" == no ]] || printf '   - Siblings: s.\n' >> "$f/review-diff-1.md"
}
ag_repo="$tmp/ag-repo"
ag_fx="$ag_repo/.scratchpads/runs/r1"
ag_run "$ag_repo" r1 open 2026-11-06T10:00 no
expect_brief block Agent prompt "Apply the fixes of $ag_fx/review-diff-1.md." '' "$ag_fx"
for part in 'scripts/check-plan.sh' "$ag_fx" 'no Siblings field' \
  'Fix what scripts/check-plan.sh names (the lead writes review fields itself, with no agent), then start the agent.'; do
  grep -qF "$part" "$tmp/agent-err" || { echo "FAIL: the agent-guard review-field message does not hold $part: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
done
expect_brief block SendMessage message "Apply the fixes of $ag_fx/review-diff-1.md." '' "$ag_fx"
expect_brief block mcp__t3-code__delegate_task task "Apply the fixes of $ag_fx/review-diff-1.md." '' "$ag_fx"
expect_brief block Agent prompt "Add the Siblings field to each Act on item of $ag_fx/review-diff-1.md." '' "$ag_fx"
expect_brief block Agent prompt $'Apply the fixes of review-diff-1.md.\nRun folder: '"$ag_fx" '' "$ag_fx"
# The repo top is in no run folder, so open_run takes the open run with the newest row: r1, not r2.
ag_run "$ag_repo" r2 open 2026-11-06T09:00 no
expect_brief block Agent prompt 'Apply the fixes of .scratchpads/runs/r1/review-plan-1.md.' '' "$ag_repo"
expect_brief allow Agent prompt "Apply the fixes of $ag_repo/.scratchpads/runs/r2/review-diff-1.md." '' "$ag_fx"
expect_brief allow Agent prompt $'Fix item 1 of the code gate: A fix.\n   - Invariant: i.' '' "$ag_fx"
expect_brief allow Agent prompt 'Apply the fixes of review-diff-1.md.' '' "$ag_fx"
expect_brief allow Agent prompt "Write $ag_fx/review-diff-<n>.md, then read $ag_fx/review-plan-*.md." '' "$ag_fx"
ag_run "$tmp/ag-done" r1 done 2026-11-06T10:00 no
expect_brief allow Agent prompt "Apply the fixes of $tmp/ag-done/.scratchpads/runs/r1/review-diff-1.md." '' "$tmp/ag-done/.scratchpads/runs/r1"
ag_run "$tmp/ag-ok" r1 open 2026-11-06T10:00 yes
expect_brief allow Agent prompt "Apply the fixes of $tmp/ag-ok/.scratchpads/runs/r1/review-diff-1.md." '' "$tmp/ag-ok/.scratchpads/runs/r1"
# An exit of check-plan.sh other than 0 and 1 is not its verdict: a hook copy beside a stub that
# exits 3 lets the brief pass and names the exit.
ag_stub="$tmp/ag-stub"
mkdir -p "$ag_stub/.claude/hooks" "$ag_stub/scripts"
cp "$(dirname "$0")/agent-guard.sh" "$(dirname "$0")/commit-files.awk" "$(dirname "$0")/open-run.py" "$ag_stub/.claude/hooks/"
cp "$lock_words_src" "$ag_stub/scripts/"
printf '#!/bin/bash\nexit 3\n' > "$ag_stub/scripts/check-plan.sh"
chmod +x "$ag_stub/scripts/check-plan.sh"
ag_real_hook="$agent_hook"
agent_hook="$ag_stub/.claude/hooks/agent-guard.sh"
expect_brief allow Agent prompt "Apply the fixes of $ag_fx/review-diff-1.md." '' "$ag_fx"
grep -qF 'scripts/check-plan.sh' "$tmp/agent-err" && grep -qF 'exited 3' "$tmp/agent-err" ||
  { echo "FAIL: agent-guard does not name the exit 3 of check-plan.sh: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
# An exit 1 of check-plan.sh blocks for any rule, and the block text prints each check-plan: line
# (the whole output when none), not the first 3 lines.
printf '#!/bin/bash\necho "check-plan: one" >&2\necho "check-plan: two" >&2\necho "check-plan: three" >&2\necho "check-plan: late cause" >&2\necho "other noise" >&2\nexit 1\n' > "$ag_stub/scripts/check-plan.sh"
expect_brief block Agent prompt "Apply the fixes of $ag_fx/review-diff-1.md." '' "$ag_fx"
grep -qF 'check-plan: late cause' "$tmp/agent-err" && ! grep -qF 'other noise' "$tmp/agent-err" ||
  { echo "FAIL: the agent-guard block text does not print each check-plan: line: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
printf '#!/bin/bash\necho "line 9: boom" >&2\nexit 1\n' > "$ag_stub/scripts/check-plan.sh"
expect_brief block Agent prompt "Apply the fixes of $ag_fx/review-diff-1.md." '' "$ag_fx"
grep -qF 'line 9: boom' "$tmp/agent-err" ||
  { echo "FAIL: the agent-guard block text drops an exit 1 output that has no check-plan: line: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
agent_hook="$ag_real_hook"

# The lock-step briefs that agent-guard.sh passes below write records (AGT-152): they go to a folder
# that no release-wait case reads.
DIRIGIBLE_LOCK_AGENTS="$tmp/ag-records"
# Lock-step brief cases (a temp repo copy of the hook and a lock state written by the test)
# While a release call holds the build lock or waits first for it, or a bench, a mutation pass, a
# flake loop, or a stress lane holds it, or a bench marker is live (with-lock.sh --long-holder),
# agent-guard.sh refuses a brief that names a lock step, unless a line of the brief says Build lock:
# none. The cases run a copy of the hook in a temp repo, so the real lock state does not change them.
lock_dir_src="$(cd "$(dirname "$0")" && pwd)"
lock_repo="$tmp/lock-repo" lock_dir="$tmp/lock-repo/.git/dirigible-build.lock" lock_first="$tmp/lock-repo/.git/dirigible-build-first"
lock_marks="$tmp/lock-repo/.git/dirigible-bench-marks"
mkdir -p "$lock_repo/.claude/hooks" "$lock_repo/scripts"
git -C "$lock_repo" init -q
cp "$lock_dir_src/agent-guard.sh" "$lock_dir_src/commit-files.awk" "$lock_repo/.claude/hooks/"
cp "$lock_dir_src/../../scripts/with-lock.sh" "$lock_dir_src/../../scripts/lock-words.sh" "$lock_repo/scripts/"
( : ) & lock_dead=$!
wait "$lock_dead"
# A dead group leader with a live member: kill -0 on the leader pid fails, kill -0 on -<leader> works.
set -m
( sleep 60 > /dev/null 2>&1 & echo $! > "$tmp/lock-member" ) &
lock_leader=$!
set +m
wait "$lock_leader"
lock_member="$(cat "$tmp/lock-member")"
# lock_state <release|lane|dead-release|dead-release-child|dead-release-group|ordinary|bench|mutation|ticket|dead-ticket|marker|free>:
# the live pid is that of this shell; the dead pid is that of an ended subshell.
lock_state() {
  rm -rf "$lock_dir" "$lock_first" "$lock_marks"
  case "$1" in
    release | lane | dead-release | dead-release-child | dead-release-group | ordinary | bench | mutation)
      mkdir -p "$lock_dir"
      case "$1" in dead-release*) echo "$lock_dead" > "$lock_dir/pid" ;; *) echo "$$" > "$lock_dir/pid" ;; esac
      case "$1" in
        dead-release-child) echo "$$" > "$lock_dir/child" ;;
        dead-release-group) echo "$lock_leader" > "$lock_dir/child" ;;
      esac
      case "$1" in
        ordinary) echo 'make build' > "$lock_dir/command" ;;
        bench) echo 'scripts/bench.sh' > "$lock_dir/command" ;;
        mutation) echo '.claude/skills/deliver/scripts/mutation-pass.sh /t/wt' > "$lock_dir/command" ;;
        lane) echo 'scripts/test-stress.sh --runs 1 out' > "$lock_dir/command" ;;
        *) : > "$lock_dir/release"; echo 'make check-changed BASE=origin/main' > "$lock_dir/command" ;;
      esac ;;
    ticket) mkdir -p "$lock_first/$$" ;;
    dead-ticket) mkdir -p "$lock_first/$lock_dead" ;;
    marker) mkdir -p "$lock_marks" && printf '\n1\n/t/bench\n' > "$lock_marks/$$" ;;
  esac
}
# expect_lock_brief <want> <lock state> <tool name> <field> <text>
expect_lock_brief() {
  local want="$1" got
  lock_state "$2"
  plutil -create xml1 "$input"
  plutil -insert tool_name -string "$3" "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert "tool_input.$4" -string "$5" "$input"
  plutil -convert json "$input"
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE "$lock_repo/.claude/hooks/agent-guard.sh" < "$input" 2>"$tmp/agent-err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: agent-guard lock step, $2: expected $want, got $got: $3 $4: ${5//$'\n'/\\n}"; failures=$((failures + 1)); }
}
lock_step='Run `scripts/with-lock.sh make test-filter FILTER=X` for the slice.'
lock_blocks=("$lock_step"
  'Run each build and test as `scripts/with-lock.sh <command>`.' 'Builds go through `scripts/with-lock.sh` only.'
  'Then run make test-hooks HOOK_TESTS=scripts/x.test.sh.' 'Run `make check-changed FILTER=ATests`.'
  "Say Build lock: none here. $lock_step" 'No build. Never call scripts/with-lock.sh.'
  'Then run make app and open the bundle.' 'Run `make test-slow` for the slice.' 'Run make test-asan, then make test-tsan.'
  'Run make check-warnings before the commit.' 'Run scripts/bench-pairs.sh for the pairs.'
  'Run scripts/swift-test.sh and scripts/sanitize.sh.' 'Run BASE=origin/main make check-changed.'
  'Run `swift build` in the tree, then `swift test --filter X`.' 'Start it with swift run dirigible --help.'
  'No swift build here. Read the files.'
  'Run make -j4 test.' 'Run `make -C . build`.' 'Run make -C dir test-filter FILTER=x.' 'Run make -j 4 -C . test.'
  'Run make FILTER=x -C . test-filter.' "Run make FILTER='A B' test-filter." $'Run make  -j4\t test.' $'Run make\t-C\tdir\tbuild.'
  'Run make --jobs=4 check.' 'Run make -- test.'
  'Run make lint test.' 'Run make check-docs build.' 'Run make -C . format test-filter FILTER=x.'
  "$lock_step"$'\n`Build lock: none`' "$lock_step"$'\n-Build lock: none')
lock_allows=($'Run `swift build`.\nBuild lock: none'
  'Read the swift tests folder and the swift testing notes.' 'Run swift format lint on the file.'
  'Use a swift build-free route (swift run-free reading).'
  "$lock_step"$'\n- Build lock: none' "$lock_step"$'\n* Build lock: none' "$lock_step"$'\n  Build lock: none'
  "$lock_step"$'\n> Build lock: none' "$lock_step"$'\n  - Build lock: none, because the agent only reads.'
  "$lock_step"$'\nBuild lock: none' $'Build lock: none.\nNever call scripts/with-lock.sh.'
  'Run make lint and make format.' 'Read scripts/bench-pairs.test.sh and the makefile text.'
  'Read plan.md and review it.' 'Run `scripts/with-lock.sh --builders` to list the trees.'
  'Run `scripts/with-lock.sh --release-holder` first.' 'Run `scripts/with-lock.sh --long-holder` first.'
  'Run make check-docs and make lint.' 'Run make check-fast.'
  'Read the Makefile target make-check-docs.' 'The tests build a remake test fixture.'
  'Run make -C . check-docs.' 'Run make -j4 lint.' 'Run make -C dir format.' 'Run make -s check-fast.' $'Run make\t-C\t.\tlint.'
  'Run make FILTER=x check-docs.' 'Run make -n.' 'Run make lint check-docs.' 'Run make format check-fast.')
for text in "${lock_blocks[@]}"; do
  grep -qE "$real_lock_re" <<< "$text" || { echo "FAIL: real_lock_re misses a lock step of the hook: $text"; failures=$((failures + 1)); }
done
# A live release holder and a live release ticket with a free lock refuse a lock-step brief.
for state in release ticket; do
  for text in "${lock_blocks[@]}"; do expect_lock_brief block "$state" Agent prompt "$text"; done
  expect_lock_brief block "$state" SendMessage message "$lock_step"
  expect_lock_brief block "$state" mcp__t3-code__delegate_task task "$lock_step"
  for text in "${lock_allows[@]}"; do expect_lock_brief allow "$state" Agent prompt "$text"; done
done
# A bench holder, a mutation-pass holder, and a live bench marker refuse a lock-step brief too, and
# a Build lock: none line passes it.
for state in bench mutation marker; do
  expect_lock_brief block "$state" Agent prompt "$lock_step"
  expect_lock_brief block "$state" SendMessage message "$lock_step"
  expect_lock_brief block "$state" mcp__t3-code__delegate_task task "$lock_step"
  expect_lock_brief allow "$state" Agent prompt "$lock_step"$'\nBuild lock: none'
done
expect_lock_brief block bench Agent prompt "$lock_step"
grep -qF '(holder: scripts/bench.sh)' "$tmp/agent-err" && grep -qF 'add the line Build lock: none' "$tmp/agent-err" && grep -qF 'a bench' "$tmp/agent-err" ||
  { echo "FAIL: the lock-step message for a bench holder does not name the holder and the Build lock: none line: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
# A closing-agent brief (deliver Phase 7) beside a mutation pass that the lead started: refused, and
# passed with a Build lock: none line.
closing_brief='Run Phase 7 up to scripts/check-governance.sh, with scripts/with-lock.sh make build for the CLI.'
expect_lock_brief block mutation Agent prompt "$closing_brief"
grep -qF 'mutation-pass.sh' "$tmp/agent-err" ||
  { echo "FAIL: the lock-step message for a mutation-pass holder does not name it: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
expect_lock_brief allow mutation Agent prompt "$closing_brief"$'\nBuild lock: none'
# No long holder and no live ticket: the brief keeps its verdict.
for state in dead-release ordinary dead-ticket free; do
  expect_lock_brief allow "$state" Agent prompt "$lock_step"
  expect_lock_brief allow "$state" SendMessage message "$lock_step"
done
# A holder pid that is dead, with a live child or a live child group, still holds the lock.
for state in dead-release-child dead-release-group; do
  expect_lock_brief block "$state" Agent prompt "$lock_step"
done
builtin kill "$lock_member" 2>/dev/null
expect_lock_brief block release Agent prompt "$lock_step"
grep -qF 'Build lock: none' "$tmp/agent-err" && grep -qF 'scripts/with-lock.sh --builders' "$tmp/agent-err" && grep -qF 'check-changed BASE=origin/main' "$tmp/agent-err" ||
  { echo "FAIL: the lock-step message does not name the pass line, --builders, and the holder: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
grep -qF 'runs no with-lock.sh step' "$tmp/agent-err" && ! grep -qF 'takes no lock' "$tmp/agent-err" ||
  { echo "FAIL: the lock-step message does not give the pass line to an agent that runs no with-lock.sh step: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
grep -qF 'A with-lock.sh call that prints no lock also waits while this call holds the lock.' "$tmp/agent-err" ||
  { echo "FAIL: the lock-step message does not say that a call that prints no lock waits while this call holds the lock: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
# A stress lane holds the lock with no release marker and no ticket, so the message says that it
# holds the lock and does not say that it waits first.
expect_lock_brief block lane Agent prompt "$lock_step"
grep -qF 'or a stress lane holds it (holder: scripts/test-stress.sh --runs 1 out)' "$tmp/agent-err" && ! grep -qF 'stress lane holds the build lock or waits first' "$tmp/agent-err" ||
  { echo "FAIL: the lock-step message for a stress lane does not say that the lane holds the lock: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
expect_lock_brief allow dead-ticket Agent prompt "$lock_step"
[[ ! -e "$lock_first/$lock_dead" ]] || { echo 'FAIL: agent-guard: the ticket of a dead pid stays'; failures=$((failures + 1)); }
# The commit message rule keeps its verdicts with a free lock and with a release holder.
for state in free release; do
  expect_lock_brief block "$state" Agent prompt 'Commit with git commit -F msg.txt at the end.'
  expect_lock_brief allow "$state" Agent prompt 'Commit with git commit -F .scratchpads/commit-msg.txt at the end.'
done
# A query that exits other than 0 or 1 (a failing or a missing with-lock.sh) refuses a lock-step
# brief, and the message names the status: a pass would turn the guard off. Build lock: none passes.
for stub in 'exit 2' 'exit 127' missing; do
  if [[ "$stub" == missing ]]; then rm -f "$lock_repo/scripts/with-lock.sh"; want='exited 127'
  else printf '#!/bin/bash\n%s\n' "$stub" > "$lock_repo/scripts/with-lock.sh"; want="exited ${stub#exit }"; fi
  expect_lock_brief block free Agent prompt "$lock_step"
  grep -qF "scripts/with-lock.sh --long-holder $want" "$tmp/agent-err" && grep -qF 'add the line Build lock: none' "$tmp/agent-err" ||
    { echo "FAIL: agent-guard, query $stub: the message does not name the status ($want) and Build lock: none: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
  expect_lock_brief allow free Agent prompt "$lock_step"$'\nBuild lock: none'
  expect_lock_brief allow free Agent prompt 'Read plan.md and review it.'
done
cp "$lock_dir_src/../../scripts/with-lock.sh" "$lock_dir_src/../../scripts/lock-words.sh" "$lock_repo/scripts/"
# The lists of the hook equal their sources: lock_targets the Makefile .PHONY line minus the four
# make targets that take no lock (lock_free_targets), and lock_scripts the scripts that AGENTS.md says take the lock
# themselves. A new make target is then a lock step the day it exists. An empty source fails.
# lock_lists_equal <Makefile> <AGENTS.md> <scripts/lock-words.sh>
lock_lists_equal() {
  local free='check-docs|check-fast|lint|format' want_t have_t want_s have_s
  want_t="$(sed -n 's/^\.PHONY: //p' "$1" | tr ' ' '\n' | grep -vxE "$free" | sort)"
  have_t="$(sed -n "s/^lock_targets='\(.*\)'\$/\1/p" "$3" | tr '|' '\n' | sort)"
  [[ "$(sed -n "s/^lock_free_targets='\(.*\)'\$/\1/p" "$3")" == "$free" ]] || return 1
  want_s="$(python3 -I -c '
import re, sys
m = re.search(r"((?:`scripts/[\w/-]+\.sh`(?:,? and |, )?)+) take the lock themselves", open(sys.argv[1], encoding="utf-8").read())
print("\n".join(sorted(re.findall(r"scripts/([\w/-]+)\.sh", m.group(1)))) if m else "")
' "$2")"
  have_s="$(sed -n "s/^lock_scripts='\(.*\)'\$/\1/p" "$3" | tr '|' '\n' | sort)"
  [[ -n "$want_t" && "$want_t" == "$have_t" && -n "$want_s" && "$want_s" == "$have_s" ]]
}
# expect_lock_lists <equal|differ> <name> <Makefile> <AGENTS.md> <scripts/lock-words.sh>
expect_lock_lists() {
  local got
  lock_lists_equal "$3" "$4" "$5" && got=equal || got=differ
  [[ "$got" == "$1" ]] || { echo "FAIL: agent-guard lock lists, $2: expected $1, got $got"; failures=$((failures + 1)); }
}
lock_real="$lock_dir_src/../.." lock_mut="$tmp/lock-mut"
mkdir -p "$lock_mut"
expect_lock_lists equal 'the real files' "$lock_real/Makefile" "$lock_real/AGENTS.md" "$lock_words_src"
sed 's/^\(\.PHONY: .*\)$/\1 newtarget/' "$lock_real/Makefile" > "$lock_mut/Makefile.new-target"
expect_lock_lists differ 'the Makefile gains a target' "$lock_mut/Makefile.new-target" "$lock_real/AGENTS.md" "$lock_words_src"
sed 's/^\(\.PHONY: .*\) static /\1 /' "$lock_real/Makefile" > "$lock_mut/Makefile.no-static"
expect_lock_lists differ 'the Makefile loses static' "$lock_mut/Makefile.no-static" "$lock_real/AGENTS.md" "$lock_words_src"
sed 's/|dmg|/|/' "$lock_words_src" > "$lock_mut/hook.no-dmg"
expect_lock_lists differ 'the hook list loses dmg' "$lock_real/Makefile" "$lock_real/AGENTS.md" "$lock_mut/hook.no-dmg"
sed "s/^lock_free_targets='check-docs|check-fast|lint|format'\$/lock_free_targets='check-docs|check-fast|format'/" "$lock_words_src" > "$lock_mut/hook.no-free-lint"
expect_lock_lists differ 'the hook free list loses lint' "$lock_real/Makefile" "$lock_real/AGENTS.md" "$lock_mut/hook.no-free-lint"
sed 's/`scripts\/test-stress.sh` take the lock/`scripts\/other.sh` take the lock/' "$lock_real/AGENTS.md" > "$lock_mut/AGENTS.new-script"
expect_lock_lists differ 'AGENTS.md names another script' "$lock_real/Makefile" "$lock_mut/AGENTS.new-script" "$lock_words_src"
sed 's/, and `scripts\/test-stress.sh`//' "$lock_real/AGENTS.md" > "$lock_mut/AGENTS.no-stress"
expect_lock_lists differ 'AGENTS.md has no test-stress.sh' "$lock_real/Makefile" "$lock_mut/AGENTS.no-stress" "$lock_words_src"
sed 's/`scripts\/flake-monitor\/loop.sh`, //' "$lock_real/AGENTS.md" > "$lock_mut/AGENTS.no-loop"
expect_lock_lists differ 'AGENTS.md has no flake-monitor/loop.sh' "$lock_real/Makefile" "$lock_mut/AGENTS.no-loop" "$lock_words_src"
sed 's/take the lock themselves/take the lock/' "$lock_real/AGENTS.md" > "$lock_mut/AGENTS.no-sentence"
expect_lock_lists differ 'the AGENTS.md sentence is gone' "$lock_real/Makefile" "$lock_mut/AGENTS.no-sentence" "$lock_words_src"
sed 's/^\.PHONY: .*$//' "$lock_real/Makefile" > "$lock_mut/Makefile.no-phony"
expect_lock_lists differ 'the Makefile has no .PHONY line' "$lock_mut/Makefile.no-phony" "$lock_real/AGENTS.md" "$lock_words_src"

# Provider limit cases. A delegate_task whose target provider or model has a line in
# dirigible-provider-limits of the git common dir, with a reset after now, is refused. PROVIDER_LIMIT_NOW
# pins now at a minute start, and the reset of a line is the start of its UTC minute.
limit_file="$lock_repo/.git/dirigible-provider-limits"
limit_t=$((1792000000 / 60 * 60))
limit_after="$(date -u -r $((limit_t + 60)) +%Y-%m-%dT%H:%M)"
limit_now="$(date -u -r "$limit_t" +%Y-%m-%dT%H:%M)"
limit_before="$(date -u -r $((limit_t - 60)) +%Y-%m-%dT%H:%M)"
# expect_limit <want> <file text for printf %b, or - for no file> <providerInstanceId> <model> [<tool name>]
expect_limit() {
  local want="$1" got tool="${5:-mcp__t3-code__delegate_task}" field=task
  [[ "$tool" != Agent ]] || field=prompt
  lock_state free
  if [[ "$2" == - ]]; then rm -f "$limit_file"; else printf '%b' "$2" > "$limit_file"; fi
  plutil -create xml1 "$input"
  plutil -insert tool_name -string "$tool" "$input"
  plutil -insert tool_input -dictionary "$input"
  plutil -insert "tool_input.$field" -string 'Review the diff.' "$input"
  plutil -insert tool_input.target -dictionary "$input"
  plutil -insert tool_input.target.providerInstanceId -string "$3" "$input"
  plutil -insert tool_input.target.model -string "$4" "$input"
  plutil -convert json "$input"
  env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE PROVIDER_LIMIT_NOW=$limit_t "$lock_repo/.claude/hooks/agent-guard.sh" < "$input" 2>"$tmp/agent-err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == "$want" ]] || { echo "FAIL: agent-guard provider limit: expected $want, got $got: $tool $3 $4: ${2//$'\n'/\\n}"; failures=$((failures + 1)); }
}
expect_limit block "antigravity\t$limit_after\n" antigravity gemini-4-argon
grep -q "antigravity" "$tmp/agent-err" && grep -q "$limit_after" "$tmp/agent-err" && grep -q "dirigible-provider-limits" "$tmp/agent-err" ||
  { echo "FAIL: the provider limit message does not name the provider, the reset, and the file: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
expect_limit block "gemini-4-argon\t$limit_after\n" antigravity gemini-4-argon
expect_limit block "opencode\t$limit_before\nantigravity\t$limit_after\n" antigravity gemini-4-argon
expect_limit block "antigravity\tsoon\nantigravity\t$limit_after\n" antigravity gemini-4-argon
expect_limit allow "antigravity\t$limit_now\n" antigravity gemini-4-argon
expect_limit allow "antigravity\t$limit_before\n" antigravity gemini-4-argon
expect_limit allow "opencode\t$limit_after\n" antigravity gemini-4-argon
expect_limit allow "antigravity\t$limit_after\n" opencode opencode/big-pickle-free
expect_limit allow - antigravity gemini-4-argon
expect_limit allow "antigravity\tsoon\n" antigravity gemini-4-argon
grep -q "dirigible-provider-limits" "$tmp/agent-err" ||
  { echo "FAIL: a malformed provider limit line gives no note on stderr: $(cat "$tmp/agent-err")"; failures=$((failures + 1)); }
expect_limit allow "antigravity\t2026-02-30T10:00\n" antigravity gemini-4-argon
expect_limit allow "antigravity\t$limit_after\n" antigravity gemini-4-argon Agent

# Records of lock-step briefs (AGT-152). A passed Agent, SendMessage, or delegate_task brief that names
# a lock step, with no Build lock: none line, writes one record file; a refused brief and a brief with
# no lock step write none.
ag_sess="$tmp/ag-e2e-s/sess.jsonl" ag_sub="$tmp/ag-e2e-s/sess/subagents" ag_rec_n=0
mkdir -p "$ag_sub"
ag_step='Run scripts/with-lock.sh make test-hooks HOOK_TESTS=x'
# ag_write <records dir> <json>: agent-guard.sh of the temp repo, with a free lock, on the brief.
ag_write() {
  lock_state free
  printf '%s' "$2" | env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE DIRIGIBLE_LOCK_AGENTS="$1" "$lock_repo/.claude/hooks/agent-guard.sh" > /dev/null 2>&1
}
# expect_records <count> <json>: the brief leaves that many record files in a new folder.
expect_records() {
  ag_dir="$tmp/ag-rec-$((ag_rec_n += 1))"
  mkdir -p "$ag_dir"
  ag_write "$ag_dir" "$2"
  [[ "$(find "$ag_dir" -type f | wc -l | tr -d ' ')" == "$1" ]] || { echo "FAIL: agent-guard record files, want $1: $2"; failures=$((failures + 1)); }
}
# ag_fields <file> <tool> <key> <description>: the record line holds an epoch and the four fields.
ag_fields() {
  local t tool key path desc
  IFS=$'\t' read -r t tool key path desc < "$1"
  [[ "$t" =~ ^[0-9]+$ && "$tool" == "$2" && "$key" == "$3" && "$path" == "$ag_sess" && "$desc" == "$4" ]] ||
    { echo "FAIL: agent-guard record fields: $(tr '\t' '|' < "$1")"; failures=$((failures + 1)); }
}
expect_records 1 "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_c1\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"S1 slice\",\"prompt\":\"$ag_step\"}}"
ag_fields "$ag_dir/toolu_c1" Agent toolu_c1 'S1 slice'
expect_records 1 "{\"tool_name\":\"SendMessage\",\"tool_use_id\":\"toolu_s1\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"to\":\"a0123456789abcdef\",\"message\":\"$ag_step\"}}"
ag_fields "$ag_dir/toolu_s1" SendMessage a0123456789abcdef 'resume a0123456789abcdef'
ag_dt="{\"tool_name\":\"mcp__t3-code__delegate_task\",\"tool_use_id\":\"toolu_c7\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"title\":\"S1 slice\",\"task\":\"$ag_step\"}}"
expect_records 1 "$ag_dt"
ag_fields "$ag_dir/toolu_c7" mcp__t3-code__delegate_task toolu_c7 'S1 slice'
# delegate-record.sh keeps the delegate_task records: the PostToolUse result of the call puts the taskId
# in the key, and the end text of the child or a task_cancel removes the record of that exact taskId.
dr_hook="$(dirname "$0")/delegate-record.sh" dr_dt=mcp__t3-code__delegate_task dr_t=node:delegated-task:
# dr_run <records dir> <input>: the hook exits 0 and prints nothing.
dr_run() {
  local code
  printf '%s' "$2" | DIRIGIBLE_LOCK_AGENTS="$1" "$dr_hook" > "$tmp/dr.out" 2>&1
  code=$?
  [[ $code -eq 0 && ! -s "$tmp/dr.out" ]] || { echo "FAIL: delegate-record.sh exit $code, output '$(cat "$tmp/dr.out")': $2"; failures=$((failures + 1)); }
}
# dr_post <tool_use_id> <tool_response JSON>: the PostToolUse input of a delegate_task call.
dr_post() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"%s","tool_use_id":"%s","tool_input":{"title":"S1 slice","task":"x"},"tool_response":%s}' "$dr_dt" "$1" "$2"
}
# dr_prompt <prompt, JSON-escaped>, dr_cancel <taskId>: a UserPromptSubmit input, a task_cancel input.
dr_prompt() { printf '{"hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1"; }
dr_cancel() {
  printf '{"hook_event_name":"PostToolUse","tool_name":"mcp__t3-code__task_cancel","tool_use_id":"toolu_k","tool_input":{"taskId":"%s"},"tool_response":[{"type":"text","text":"{}"}]}' "$1"
}
# dr_left <dir> <file>...: the folder holds exactly these record files, in ls order.
dr_left() {
  local d="$1" got
  shift
  got="$(ls "$d" | tr '\n' ' ')"
  [[ "$got" == "${*:+$* }" ]] || { echo "FAIL: delegate-record.sh left '$got' in ${d##*/}, want '$*'"; failures=$((failures + 1)); }
}
dr_n=0
for resp in "\"{\\\"taskId\\\":\\\"${dr_t}t1\\\",\\\"childThreadId\\\":\\\"thread:x\\\"}\"" \
  "[{\"type\":\"text\",\"text\":\"{\\\"taskId\\\": \\\"${dr_t}t1\\\", \\\"childThreadId\\\": \\\"thread:x\\\"}\"}]" \
  "[{\"type\":\"text\",\"text\":\"note\"},{\"type\":\"text\",\"text\":\"{\\\"taskId\\\":\\\"${dr_t}t1\\\"}\"}]"; do
  ag_dir="$tmp/dr-post-$((dr_n += 1))"
  ag_write "$ag_dir" "$ag_dt"
  dr_run "$ag_dir" "$(dr_post toolu_c7 "$resp")"
  ag_fields "$ag_dir/toolu_c7" "$dr_dt" "${dr_t}t1" 'S1 slice'
done
# A mode wait result in the state completed or failed removes the record: no end text follows it.
# A running result, also one that timed out, and a result in any other state keep the record with
# the taskId.
dr_wait() { # <status> [<more fields>]: a mode wait result whose summary quotes another status
  printf '[{"type":"text","text":"{\\"taskId\\":\\"%st1\\",\\"status\\":\\"%s\\"%s,\\"latestTerminalSummary\\":\\"was \\\\\\"status\\\\\\":\\\\\\"completed\\\\\\"\\"}"}]' "$dr_t" "$1" "${2:-}"
}
for resp in "$(dr_wait completed ',\"workState\":\"result_available\"')" "$(dr_wait failed)" \
  "\"{\\\"taskId\\\":\\\"${dr_t}t1\\\", \\\"status\\\": \\\"completed\\\"}\""; do
  ag_dir="$tmp/dr-post-$((dr_n += 1))"
  ag_write "$ag_dir" "$ag_dt"
  dr_run "$ag_dir" "$(dr_post toolu_c7 "$resp")"
  dr_left "$ag_dir"
done
for resp in "$(dr_wait running ',\"waitTimedOut\":true')" "$(dr_wait queued)"; do
  ag_dir="$tmp/dr-post-$((dr_n += 1))"
  ag_write "$ag_dir" "$ag_dt"
  dr_run "$ag_dir" "$(dr_post toolu_c7 "$resp")"
  ag_fields "$ag_dir/toolu_c7" "$dr_dt" "${dr_t}t1" 'S1 slice'
done
ag_dir="$tmp/dr-post-none"
ag_write "$ag_dir" "$ag_dt"
dr_run "$ag_dir" "$(dr_post toolu_c7 '[{"type":"text","text":"error: no child"}]')"
ag_fields "$ag_dir/toolu_c7" "$dr_dt" toolu_c7 'S1 slice'
# The end text removes only the record whose key is the whole taskId, and only in the states completed
# and failed at the start of the prompt or of a line of it. Other tools keep their records.
dr_fill() {
  rm -rf "$1"
  rw_rec "$1" toolu_e1 60 "$dr_dt" "${dr_t}t1"
  rw_rec "$1" toolu_e2 60 "$dr_dt" "${dr_t}t1-2"
  rw_rec "$1" toolu_e3 60 "$dr_dt" "${dr_t}a.b"
  rw_rec "$1" toolu_e4 60 "$dr_dt" "${dr_t}t2"
  rw_rec "$1" toolu_e5 60 Agent "${dr_t}t1"
}
dr_end() { # <state> <taskId>: the end text of a child, JSON-escaped, with its result line
  printf 'Delegated task %s (S1 slice (x)) [%s]:\\nDone.' "$dr_t$2" "$1"
}
dr="$tmp/dr-end"
for prompt in 'Go on with the next slice.' "$(dr_end completed t3)" "$(dr_end running t1)" "See: $(dr_end completed t1)" \
  "$(dr_end completed aXb)" "$(dr_end canceled t1)"; do
  dr_fill "$dr"
  dr_run "$dr" "$(dr_prompt "$prompt")"
  dr_left "$dr" toolu_e1 toolu_e2 toolu_e3 toolu_e4 toolu_e5
done
dr_fill "$dr"
dr_run "$dr" "$(dr_prompt "$(dr_end completed t1)\\n\\nCall the next tool.")"
dr_left "$dr" toolu_e2 toolu_e3 toolu_e4 toolu_e5
dr_fill "$dr"
dr_run "$dr" "$(dr_prompt "$(dr_end failed t2)\\n\\n$(dr_end failed a.b)")"
dr_left "$dr" toolu_e1 toolu_e2 toolu_e5
# A task_cancel removes the record of its exact taskId.
for id in t1-x aXb t; do
  dr_fill "$dr"
  dr_run "$dr" "$(dr_cancel "$dr_t$id")"
  dr_left "$dr" toolu_e1 toolu_e2 toolu_e3 toolu_e4 toolu_e5
done
dr_fill "$dr"
dr_run "$dr" "$(dr_cancel "${dr_t}t1")"
dr_left "$dr" toolu_e2 toolu_e3 toolu_e4 toolu_e5
dr_fill "$dr"
dr_run "$dr" "$(dr_cancel "${dr_t}a.b")"
dr_left "$dr" toolu_e1 toolu_e2 toolu_e4 toolu_e5
# An input that the hook does not know, and a missing records folder, give exit 0 and no output.
dr_fill "$dr"
for in_text in '' 'not json' "Delegated task ${dr_t}t1 (S1 slice) [completed]: not json" \
  "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$dr_dt\",\"tool_use_id\":\"toolu_e1\",\"tool_response\":\"{\\\"taskId\\\":\\\"x\\\"}\"}"; do
  dr_run "$dr" "$in_text"
done
dr_left "$dr" toolu_e1 toolu_e2 toolu_e3 toolu_e4 toolu_e5
dr_run "$tmp/dr-none" "$(dr_prompt "$(dr_end completed t1)")"
dr_run "$tmp/dr-none" "$(dr_post toolu_c7 '"{\"taskId\":\"t\"}"')"
[[ ! -e "$tmp/dr-none" ]] || { echo "FAIL: delegate-record.sh made a missing records folder"; failures=$((failures + 1)); }
# dr_registered <settings file> <event> [<tool>...]: the event has an entry of delegate-record.sh, and
# the matcher of an entry of it covers each tool (an entry with no matcher covers each tool).
dr_registered() {
  python3 -c '
import json, re, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get(sys.argv[2], [])
def covers(e, tool):
    return e.get("matcher") in (None, "", "*") or re.fullmatch(e["matcher"], tool) is not None
def runs(e):
    return any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/delegate-record.sh") for h in e.get("hooks", []))
ok = any(runs(e) for e in entries) and all(any(runs(e) and covers(e, t) for e in entries) for t in sys.argv[3:])
sys.exit(0 if ok else 1)
' "$@" 2>/dev/null
}
dr_registered "$settings" PostToolUse "$dr_dt" mcp__t3-code__task_cancel || { echo "FAIL: .claude/settings.json does not register delegate-record.sh for PostToolUse of delegate_task and task_cancel"; failures=$((failures + 1)); }
dr_registered "$settings" UserPromptSubmit || { echo "FAIL: .claude/settings.json does not register delegate-record.sh for UserPromptSubmit"; failures=$((failures + 1)); }
dr_registered "$tmp/old-settings.json" PostToolUse "$dr_dt" && { echo "FAIL: the delegate-record registration check passed a settings file with no PostToolUse entry"; failures=$((failures + 1)); }
dr_registered "$tmp/old-settings.json" UserPromptSubmit && { echo "FAIL: the delegate-record registration check passed a settings file with no UserPromptSubmit entry"; failures=$((failures + 1)); }
for brief in "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_c2\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"d\",\"prompt\":\"$ag_step\\nBuild lock: none\"}}" \
  "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_c3\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"d\",\"prompt\":\"Run make check-docs.\"}}" \
  "{\"tool_name\":\"SendMessage\",\"tool_use_id\":\"toolu_c4\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"to\":\"a1\",\"message\":\"Go on with the next item.\"}}" \
  "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_c5\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"d\",\"prompt\":\"$ag_step\",\"isolation\":\"worktree\"}}" \
  "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_c6\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"d\",\"prompt\":\"$ag_step\\ngit commit -F .scratchpads/runs/x/commit-msg.txt\"}}" \
  "{\"tool_name\":\"mcp__t3-code__delegate_task\",\"tool_use_id\":\"toolu_c8\",\"tool_input\":{\"title\":\"t\",\"task\":\"$ag_step\\nBuild lock: none\"}}" \
  "{\"tool_name\":\"mcp__t3-code__delegate_task\",\"tool_use_id\":\"toolu_c9\",\"tool_input\":{\"title\":\"t\",\"task\":\"Run make check-docs.\"}}"; do
  expect_records 0 "$brief"
done
# Each write removes the record files over 24 h old.
ag_dir="$tmp/ag-purge"
mkdir -p "$ag_dir"
printf 'x\n' > "$ag_dir/old"; touch -t "$(rw_stamp $(($(date +%s) - 1441 * 60)))" "$ag_dir/old"
printf 'x\n' > "$ag_dir/young"; touch -t "$(rw_stamp $(($(date +%s) - 1437 * 60)))" "$ag_dir/young"
ag_write "$ag_dir" "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_p1\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"p\",\"prompt\":\"$ag_step\"}}"
[[ ! -e "$ag_dir/old" && -e "$ag_dir/young" && -e "$ag_dir/toolu_p1" ]] || { echo "FAIL: agent-guard record purge: $(ls "$ag_dir" | tr '\n' ' ')"; failures=$((failures + 1)); }
# End to end: the record of agent-guard.sh makes git-guardrails.sh refuse the push check until the meta
# of the agent says finished; a resume with no lock words writes no record, and its meta start write
# makes the agent live again.
ag_dir="$tmp/ag-e2e"
mkdir -p "$ag_dir"
ag_push='WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh make check-changed BASE=origin/main'
ag_write "$ag_dir" "{\"tool_name\":\"Agent\",\"tool_use_id\":\"toolu_t1\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"description\":\"S1 slice\",\"prompt\":\"$ag_step\"}}"
expect_release block "$ag_dir" "$ag_push"
release_has 'toolu_t1: Agent "S1 slice"'
printf '{"toolUseId":"toolu_t1","finished":true}' > "$ag_sub/agent-at1.meta.json"
expect_release allow "$ag_dir" "$ag_push"
ag_write "$ag_dir" "{\"tool_name\":\"SendMessage\",\"tool_use_id\":\"toolu_s2\",\"transcript_path\":\"$ag_sess\",\"tool_input\":{\"to\":\"at1\",\"message\":\"Go on with the next item.\"}}"
[[ "$(ls "$ag_dir")" == toolu_t1 ]] || { echo "FAIL: agent-guard wrote a record for a resume with no lock step: $(ls "$ag_dir" | tr '\n' ' ')"; failures=$((failures + 1)); }
ag_t=$(($(date +%s) - 7200))
printf '%s\tAgent\ttoolu_t1\t%s\tS1 slice\n' "$ag_t" "$ag_sess" > "$ag_dir/toolu_t1"
touch -t "$(rw_stamp "$ag_t")" "$ag_dir/toolu_t1"
printf '{"toolUseId":"toolu_t1"}' > "$ag_sub/agent-at1.meta.json"
expect_release block "$ag_dir" "$ag_push"
release_has 'at1: Agent "S1 slice"'
printf '{"toolUseId":"toolu_t1","finished":true}' > "$ag_sub/agent-at1.meta.json"
expect_release allow "$ag_dir" "$ag_push"
# End to end for a delegate_task child: the record holds the push check until the end text of the
# child reaches the lead as a prompt.
ag_dir="$tmp/ag-e2e-dt"
ag_write "$ag_dir" "$ag_dt"
dr_run "$ag_dir" "$(dr_post toolu_c7 "\"{\\\"taskId\\\":\\\"${dr_t}t1\\\"}\"")"
expect_release block "$ag_dir" "$ag_push"
release_has 'toolu_c7: mcp__t3-code__delegate_task "S1 slice"'
dr_run "$ag_dir" "$(dr_prompt "$(dr_end completed t1)")"
expect_release allow "$ag_dir" "$ag_push"
DIRIGIBLE_LOCK_AGENTS="$tmp/lock-agents"
fi # agent-guard
if case_block usage-hook; then
# The third hook, usage-hook.sh, gives the usage mode as context at an agent start. It denies nothing
# and always exits 0. The fixture clock and limits file give each mode.
usage_hook="$(dirname "$0")/usage-hook.sh"
usage_now=1792000000
usage_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z; }
# expect_usage <mode> <five_hour percent> <minutes to the reset>
expect_usage() {
  local mode="$1" out code
  printf '{"written_at":%s,"rate_limits":[{"kind":"five_hour","percentUsed":%s,"resetsAt":"%s"}]}\n' \
    $((usage_now * 1000)) "$2" "$(usage_iso $((usage_now + $3 * 60)))" > "$tmp/usage-limits.json"
  out="$(printf '{"tool_input":{}}' | USAGE_LIMITS_FILE="$tmp/usage-limits.json" USAGE_MODE_NOW=$usage_now "$usage_hook" 2>/dev/null)"
  code=$?
  [[ $code -eq 0 ]] || { echo "FAIL: usage-hook $mode: exit $code"; failures=$((failures + 1)); }
  printf '%s' "$out" | python3 -c '
import json, sys
mode = sys.argv[1]
out = json.load(sys.stdin)
assert list(out) == ["hookSpecificOutput"], "one hookSpecificOutput object"
h = out["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse", "event name"
assert "Usage mode: " + mode + "." in h["additionalContext"], "context names the mode"
assert "permissionDecision" not in h and "permissionDecisionReason" not in h, "no deny"
if mode == "stop":
    assert "Stop at a safe point" in h["additionalContext"], "stop text"
    assert "except a free-model job, the reflect agent," in h["additionalContext"], "stop text names the free-job exception"
' "$mode" 2>"$tmp/usage-err" || { echo "FAIL: usage-hook $mode: $(tail -n 1 "$tmp/usage-err") (output: $out)"; failures=$((failures + 1)); }
}
expect_usage normal 10 120
expect_usage save 76 120
expect_usage spend 10 30
expect_usage stop 85 120
# A broken usage-mode.sh (no jq, or a non-zero exit) gives the normal text and exit 0.
mkdir "$tmp/nojq"
for t in cat dirname date; do ln -s "$(command -v $t)" "$tmp/nojq/$t"; done
out="$(printf '{}' | PATH="$tmp/nojq" /bin/bash "$usage_hook" 2>/dev/null)"
[[ $? -eq 0 && "$out" == *"Usage mode: normal."* ]] ||
  { echo "FAIL: usage-hook with no jq did not give the normal text and exit 0: $out"; failures=$((failures + 1)); }

# The settings register usage-hook.sh for each tool that starts an agent job. The matcher is a
# regex that must match the whole tool name.
# matcher_covers <settings file> <tool name>
matcher_covers() {
  python3 -c '
import json, re, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
ok = any(re.fullmatch(e.get("matcher", ""), sys.argv[2])
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/usage-hook.sh") for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$1" "$2" 2>/dev/null
}
for tool in Agent Workflow SendMessage mcp__t3-code__delegate_task; do
  matcher_covers "$settings" "$tool" || { echo "FAIL: .claude/settings.json does not register usage-hook.sh for $tool"; failures=$((failures + 1)); }
done
for tool in SendMessage mcp__t3-code__delegate_task; do
  matcher_covers "$tmp/old-settings.json" "$tool" && { echo "FAIL: the matcher check passed a settings file with no $tool"; failures=$((failures + 1)); }
done

fi # usage-hook
guard_hook="$(dirname "$0")/handback-guard.sh"
hb_now="$(date +%s)"
hb_iso() { date -u -r $((hb_now - $1 * 60)) +%Y-%m-%dT%H:%M:%S.000Z; }
# hb_line <role> <minutes ago> <content JSON>: one line of a transcript
hb_line() { printf '{"type":"%s","timestamp":"%s","message":{"role":"%s","content":%s}}\n' "$1" "$(hb_iso "$2")" "$1" "$3"; }
# hb_text <role> <minutes ago> <text>: an entry with a text content
hb_text() { local t="${3//\\/\\\\}"; hb_line "$1" "$2" "\"${t//\"/\\\"}\""; }
# hb_use <minutes ago> <use id> <tool> <input JSON>: an assistant tool call
hb_use() { hb_line assistant "$1" "[{\"type\":\"tool_use\",\"id\":\"$2\",\"name\":\"$3\",\"input\":$4}]"; }
# hb_result <minutes ago> <use id> <text>: the result of a tool call
hb_result() { hb_line user "$1" "[{\"type\":\"tool_result\",\"tool_use_id\":\"$2\",\"content\":\"$3\"}]"; }
# hb_session <name>: write stdin as the agent transcript, and name its folder in hb_dir
hb_session() { hb_dir="$tmp/$1"; mkdir -p "$hb_dir/s/subagents"; : > "$hb_dir/s.jsonl"; cat > "$hb_dir/s/subagents/agent-a1.jsonl"; }
# hb_in <tool> [<tool_input JSON>]: the hook input of agent a1
hb_in() {
  local ti="${2-}"
  [[ -n "$ti" ]] || ti='{}'
  printf '{"transcript_path":"%s/s.jsonl","agent_id":"a1","tool_name":"%s","tool_input":%s}' "$hb_dir" "$1" "$ti"
}
# hb_expect <hook> <want exit> <label> <hook input>; the stderr stays in $tmp/hb-err
hb_expect() {
  local code
  printf '%s' "$4" | "$1" 2>"$tmp/hb-err"
  code=$?
  [[ $code -eq $2 ]] || { echo "FAIL: $(basename "$1") $3: expected exit $2, got $code"; failures=$((failures + 1)); }
}
hb_err_has() {
  grep -qF -- "$2" "$tmp/hb-err" || { echo "FAIL: $1: stderr has no '$2': $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
}
hb_bg_start() {
  hb_use 12 u1 Bash '{"command":"sleep 300","run_in_background":true}'
  hb_result 12 u1 'Command running in background with ID: b1. Output is being written to: /x'
}
hb_mon_start() {
  hb_use "$1" u3 Monitor '{"command":"x"}'
  hb_result "$1" u3 'Monitor started (task m1, expires in 30m. Output is being written to: /x'
}

# hook_registered <settings file> <hook script> <tool name>: a PreToolUse entry runs the script for the tool
hook_registered() {
  python3 -c '
import json, re, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get("PreToolUse", [])
def covers(matcher):
    return matcher in (None, "", "*") or re.fullmatch(matcher, sys.argv[3]) is not None
ok = any(covers(e.get("matcher"))
         and any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/" + sys.argv[2]) for h in e.get("hooks", []))
         for e in entries)
sys.exit(0 if ok else 1)
' "$1" "$2" "$3" 2>/dev/null
}

if case_block handback-guard; then
# The fourth hook, handback-guard.sh, refuses a SubagentHandback call while a background task of the
# agent runs. It reads the transcript of the subagent: <dir>/s.jsonl is the session file and
# <dir>/s/subagents/agent-a1.jsonl is the agent file. Timestamps come from the clock of this test.

hb_session running < <(hb_bg_start)
hb_expect "$guard_hook" 2 'a running background Bash' "$(hb_in SubagentHandback)"
hb_err_has 'a running background Bash' 'b1 (shell)'
hb_err_has 'a running background Bash' 'TaskStop b1'
hb_err_has 'a running background Bash' 'handback-guard.sh'
hb_err="$(cat "$tmp/hb-err")"
[[ "${hb_err%%TaskStop b1*}" != *[Ww]ait* ]] ||
  { echo "FAIL: the hand-back refusal says wait before it names TaskStop b1: $hb_err"; failures=$((failures + 1)); }
[[ "$(sed 's/Never stop a task with pkill -f\.//' "$tmp/hb-err")" != *pkill* ]] ||
  { echo "FAIL: the hand-back refusal names pkill other than in a never rule: $hb_err"; failures=$((failures + 1)); }
running_dir="$hb_dir"

for status in completed failed killed; do
  hb_session "end-$status" < <(hb_bg_start; hb_text user 3 "<task-notification><task-id>b1</task-id><status>$status</status></task-notification>")
  hb_expect "$guard_hook" 0 "a $status notification ends the task" "$(hb_in SubagentHandback)"
done
hb_session taskstop < <(hb_bg_start; hb_use 3 u2 TaskStop '{"task_id":"b1"}'; hb_result 3 u2 'Error: No task found with ID: b1')
hb_expect "$guard_hook" 0 'a TaskStop call ends the task' "$(hb_in SubagentHandback)"
hb_session mon-expired < <(hb_mon_start 20; hb_text user 2 '<task-notification><task-id>m1</task-id><summary>s</summary><event>[Monitor expired after 30m, stopped]</event></task-notification>')
hb_expect "$guard_hook" 0 'a Monitor expiry event ends the monitor' "$(hb_in SubagentHandback)"
hb_session mon-old < <(hb_mon_start 31)
hb_expect "$guard_hook" 0 'a Monitor older than its expiry time ends' "$(hb_in SubagentHandback)"
hb_session child < <(
  hb_use 9 u4 Agent '{"prompt":"p"}'
  hb_line user 9 '[{"type":"tool_result","tool_use_id":"u4","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: c1 (internal)"}]}]'
  hb_text user 2 '<agent-message from="c1"> [Subagent hand-back] done'
)
hb_expect "$guard_hook" 0 'a child hand-back message ends the agent task' "$(hb_in SubagentHandback)"

hb_session mon-event < <(hb_mon_start 5; hb_text user 2 '<task-notification><task-id>m1</task-id><summary>s</summary><event>a line</event></task-notification>')
hb_expect "$guard_hook" 2 'a Monitor event with no status does not end the monitor' "$(hb_in SubagentHandback)"
hb_err_has 'a Monitor event with no status' 'm1 (monitor)'
hb_session quoted < <(hb_bg_start; hb_line assistant 3 '[{"type":"text","text":"<task-notification><task-id>b1</task-id><status>completed</status></task-notification>"}]')
hb_expect "$guard_hook" 2 'an assistant text that quotes a notification does not end the task' "$(hb_in SubagentHandback)"
hb_session mon-new < <(hb_mon_start 10)
hb_expect "$guard_hook" 2 'a Monitor before its expiry time still runs' "$(hb_in SubagentHandback)"

# The guard fails open: a refusal with no way out loses the report.
hb_dir="$running_dir"
hb_expect "$guard_hook" 0 'no agent_id (the lead)' "$(printf '{"transcript_path":"%s/s.jsonl","tool_name":"SubagentHandback"}' "$hb_dir")"
hb_expect "$guard_hook" 0 'another tool' "$(hb_in Bash '{"command":"ls"}')"
hb_expect "$guard_hook" 0 'no transcript file' "$(printf '{"transcript_path":"%s/none/s.jsonl","agent_id":"a1","tool_name":"SubagentHandback"}' "$tmp")"
hb_expect "$guard_hook" 0 'input that is not JSON' 'not json'

hook_registered "$settings" handback-guard.sh SubagentHandback ||
  { echo "FAIL: .claude/settings.json does not register handback-guard.sh for SubagentHandback"; failures=$((failures + 1)); }
hook_registered "$tmp/old-settings.json" handback-guard.sh SubagentHandback &&
  { echo "FAIL: the registration check passed a settings file with no handback-guard.sh"; failures=$((failures + 1)); }

fi # handback-guard
if case_block agent-clock; then
# The fifth hook, agent-clock.sh, refuses the tool calls of a subagent after 90 active minutes. A gap
# between two entries of the transcript counts at most 15 min.
clock_hook="$(dirname "$0")/agent-clock.sh"
# hb_span <from> <to>: one entry for each minute from <from> to <to> minutes ago
hb_span() { local m; for ((m = $1; m >= $2; m--)); do hb_text user "$m" x; done; }
# hb_bash <command>: the hook input of a Bash call of agent a1, with the repo root as its cwd
clock_root="$(cd "$(dirname "$0")/../.." && pwd)"
hb_bash() {
  printf '{"transcript_path":"%s/s.jsonl","agent_id":"a1","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$hb_dir" "$clock_root" "$1"
}

hb_session over < <(hb_span 91 0)
hb_expect "$clock_hook" 2 'make build at 91 active minutes' "$(hb_bash 'make build')"
hb_err_has 'the clock refusal' '90'
hb_err_has 'the clock refusal' 'run.md'
hb_err_has 'the clock refusal' 'SubagentHandback'
hb_err_has 'the clock refusal' 'git add <paths> && git commit -F .scratchpads/commit-msg.txt'
hb_err_has 'the clock refusal' 'log-decision.sh <run folder> --from <file in .scratchpads/>'
hb_err_has 'the clock refusal' '.claude/skills/deliver/scripts/log-decision.sh'
# The steps run in this order: handoff, log rows, commit or leave the tree, then SubagentHandback.
hb_rest="$(cat "$tmp/hb-err")"
for hb_part in 'Write the handoff in run.md' 'log-decision.sh <run folder> --from' 'git add <paths>' 'leave the working tree' 'call SubagentHandback'; do
  [[ "$hb_rest" == *"$hb_part"* ]] || { echo "FAIL: the clock refusal: '$hb_part' is missing or out of order: $hb_rest"; failures=$((failures + 1)); break; }
  hb_rest="${hb_rest#*"$hb_part"}"
done
[[ "$(cat "$tmp/hb-err")" != *'still passes'* ]] || { echo "FAIL: the clock refusal says 'still passes'"; failures=$((failures + 1)); }
hb_session under < <(hb_span 89 0)
hb_expect "$clock_hook" 0 'make build at 89 active minutes' "$(hb_bash 'make build')"
hb_session idle < <(hb_span 330 300; hb_span 30 0)
hb_expect "$clock_hook" 0 'a 5 h gap counts 15 min (75 active minutes)' "$(hb_bash 'make build')"
hb_session short < <(hb_span 11 0)
AGENT_CLOCK_MIN=10 hb_expect "$clock_hook" 2 'AGENT_CLOCK_MIN sets the limit' "$(hb_bash 'make build')"
hb_err_has 'AGENT_CLOCK_MIN' 'limit of 10'

# The pass and block forms of a refused agent. Each trigger (the limit, the commit hand-off) runs
# all of them: add a form here, not to one trigger.
clock_pass_tools=(Read ToolSearch TaskStop SubagentHandback)
clock_edit_forms=(
  '2~Edit~{"file_path":"/t/Sources/A/a.swift"}~Edit of a Sources/ path'
  '2~Write~~Write with no file_path'
  '0~Write~{"file_path":"/t/.scratchpads/commit-msg.txt"}~Write of .scratchpads/commit-msg.txt'
  '0~Edit~{"file_path":"/t/.scratchpads/runs/r/run.md"}~Edit of run.md under .scratchpads'
  '0~Write~{"file_path":"/t/.scratchpads/runs/x/row.txt"}~Write of a row file under .scratchpads/runs'
  '2~Write~{"file_path":"/t/row.txt"}~Write of a file in the tree root'
)
clock_pass_commands=('git status' 'git diff --stat' 'git log -1' 'git add -A' 'git commit -F x'
  '.claude/skills/deliver/scripts/log-decision.sh run 4 d w e r'
  'git commit -F x 2>&1' 'git -c core.pager=cat log -1'
  'cd T && git commit -F x' 'git -C T status' 'cd T && R=x .claude/skills/deliver/scripts/log-decision.sh $R --from f')
clock_block_commands=('git push origin x' 'make test' 'cd T && git commit -F x && make test' 'git status && make test'
  'git commit -F x; scripts/with-lock.sh make check-fast' 'git status $(make test)' 'git status & make test'
  'bash x/log-decision.sh' 'x/log-decision.sh run 4 d w e r' 'git status `make test`' 'git diff <(make test)'
  'git diff >(make test)')
# The hand-off forms of reflect step 4 and of a row or commit check: echo with no redirect, and
# scripts/wiki.py lesson and move by the word scripts/wiki.py or the path in the repo of the hook.
clock_pass_commands+=('git commit -F x; echo $?' '.claude/skills/deliver/scripts/log-decision.sh r --from f; echo "exit $?"'
  'echo done' 'scripts/wiki.py lesson K --from f' "$clock_root/scripts/wiki.py move 1 done"
  'cd . && scripts/wiki.py lesson K --from f' "cd $clock_root && scripts/wiki.py lesson K --from f"
  'cd /tmp | scripts/wiki.py lesson K --from f')
clock_block_commands+=('echo x > f' 'echo x >> f' 'git status; echo x < f' 'scripts/wiki.py add next --from f'
  'python3 scripts/wiki.py move 1 done' 'x/wiki.py lesson K --from f' '.scratchpads/x/scripts/wiki.py lesson K --from f'
  '/other/scripts/wiki.py move 1 done' 'cd .scratchpads/x && scripts/wiki.py lesson K --from f'
  'cd scripts && scripts/wiki.py lesson K --from f' 'cd .scratchpads/x; scripts/wiki.py lesson K --from f'
  'cd /tmp && scripts/wiki.py lesson K --from f' 'cd && scripts/wiki.py lesson K --from f'
  'X=1 cd .scratchpads/x && scripts/wiki.py lesson K --from f' 'X=1 Y=2 cd /tmp; scripts/wiki.py lesson K --from f')
# clock_forms <transcript folder> <trigger name>: each pass and block form against one transcript
clock_forms() {
  local form tool want input label command
  hb_dir="$1"
  for tool in "${clock_pass_tools[@]}"; do
    hb_expect "$clock_hook" 0 "$tool past the $2" "$(hb_in "$tool")"
  done
  for form in "${clock_edit_forms[@]}"; do
    IFS='~' read -r want tool input label <<< "$form"
    hb_expect "$clock_hook" "$want" "$label past the $2" "$(hb_in "$tool" "$input")"
  done
  for command in "${clock_pass_commands[@]}"; do
    hb_expect "$clock_hook" 0 "Bash '$command' past the $2" "$(hb_bash "$command")"
  done
  for command in "${clock_block_commands[@]}"; do
    hb_expect "$clock_hook" 2 "Bash '$command' past the $2" "$(hb_bash "$command")"
  done
}
clock_forms "$tmp/over" 'limit'

# A check that started before the limit can finish and be read.
hb_session check < <(
  hb_span 91 81
  hb_use 80 u1 Bash '{"command":"make test","run_in_background":true}'
  hb_result 80 u1 'Command running in background with ID: b1. Output is being written to: /x'
  hb_span 79 0
)
for tool in Monitor TaskOutput; do
  hb_expect "$clock_hook" 0 "$tool with a running background task" "$(hb_in "$tool")"
done
hb_dir="$tmp/over"
hb_expect "$clock_hook" 2 'Monitor with no running background task' "$(hb_in Monitor)"

# The commit hand-off: a Bash call with a git commit segment at 60 active minutes or more, and a new
# commit in the HEAD history of its work tree, inside the window of the call. The transcript holds
# 62 minutes of entries, the call 1 min before the end (61 active minutes), the commit 30 s before
# the end. The temp repos get their commit times from the clock of this test.
# hb_commit <minutes ago> <use id> <command> <cwd>: an assistant Bash call with a cwd
hb_commit() {
  local c="${3//\\/\\\\}"
  c="${c//\"/\\\"}"
  printf '{"type":"assistant","timestamp":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{"command":"%s"}}]}}\n' \
    "$(hb_iso "$1")" "$4" "$2" "$c"
}
# ct_commit <repo> <committer seconds ago> <author seconds ago> [<git commit option>...]
ct_commit() {
  GIT_COMMITTER_DATE="$((hb_now - $2)) +0000" GIT_AUTHOR_DATE="$((hb_now - $3)) +0000" \
    git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m m "${@:4}"
}
# ct_repo <name> <new|old|amend|detached|root>: the repo $ct_tree. new: a base commit 10 min ago and
# a commit 30 s ago. old: the base commit only, as after a failed commit. amend: the commit has an old
# author time. detached: new, on a detached HEAD. root: the one commit is the new one.
ct_repo() {
  ct_tree="$tmp/ctr-$1"
  rm -rf "$ct_tree"
  git init -q "$ct_tree"
  [[ "$2" == root ]] || ct_commit "$ct_tree" 600 600
  [[ "$2" != detached ]] || git -C "$ct_tree" checkout -q --detach
  case "$2" in
    new | detached | root) ct_commit "$ct_tree" 30 30 ;;
    amend) ct_commit "$ct_tree" 30 1200 ;;
  esac
}
# ct_session <name> <first minute> <command with @T@> <cwd: tree|elsewhere> <result text>: the transcript
# of agent a1 with the commit call; the hook input for make build is hb_bash
ct_session() {
  local cwd="$tmp"
  [[ "$4" != tree ]] || cwd="$ct_tree"
  hb_session "ct-$1" < <(hb_span "$2" 2; hb_commit 1 c1 "${3//@T@/$ct_tree}" "$cwd"; hb_result 0 c1 "$5")
}
ct_refused() { # <label>: the hand-off refusal names the commit hand-off, the handoff file, the row route, and the hand-back
  hb_err_has "$1" 'commit hand-off'
  hb_err_has "$1" 'run.md'
  hb_err_has "$1" 'log-decision.sh <run folder> --from <file in .scratchpads/>'
  hb_err_has "$1" 'SubagentHandback'
}
ct_shapes=(
  'quiet~new~git commit -q -F x; echo exit $?; git log --oneline -1~tree~'
  'tail~new~git commit -F x 2>&1 | tail -5~tree~[main 1234abc] m'
  'cd~new~cd @T@ && git commit -m x~elsewhere~[main 1234abc] m'
  'dash-C~new~git -C @T@ commit -m x~elsewhere~[main 1234abc] m'
  'env-word~new~GIT_AUTHOR_DATE=2026-10-01 git commit -m x~tree~[main 1234abc] m'
  'dash-c~new~git -c user.name=x commit -m x~tree~[main 1234abc] m'
  'amend~amend~git commit --amend --no-edit~tree~[main 1234abc] m'
  'detached~detached~git commit -m x~tree~[detached HEAD 1234abc] m'
  'root~root~git commit -m x~tree~[main (root-commit) 1234abc] m'
  'env-cmd~new~env FOO=1 git commit -m x~tree~[main 1234abc] m'
  'time~new~time git commit -m x~tree~[main 1234abc] m'
  'command~new~command git commit -m x~tree~[main 1234abc] m'
  'no-pager~new~git --no-pager commit -m x~tree~[main 1234abc] m'
  'subshell~new~(cd @T@ && git commit -m x)~elsewhere~[main 1234abc] m'
  'cd-then-C~new~cd @T@/x && git -C @T@ commit -m x~elsewhere~[main 1234abc] m'
  'relative~new~cd @T@/.. && git -C ctr-relative commit -m x~elsewhere~[main 1234abc] m'
  'git-dir~new~git --git-dir=@T@/.git --work-tree=@T@ commit -m x~elsewhere~[main 1234abc] m'
  'date~amend~git commit --date=2020-01-01 -m x~tree~[main 1234abc] m'
  'env-date~amend~GIT_AUTHOR_DATE=2020-01-01 git commit -m x~tree~[main 1234abc] m'
  'reuse~amend~git commit -C HEAD~tree~[main 1234abc] m'
)
for ct_shape in "${ct_shapes[@]}"; do
  IFS='~' read -r ct_name ct_mode ct_command ct_cwd ct_text <<< "$ct_shape"
  ct_repo "$ct_name" "$ct_mode"
  ct_session "$ct_name" 62 "$ct_command" "$ct_cwd" "$ct_text"
  hb_expect "$clock_hook" 2 "make build after a commit at 61 active minutes: $ct_name" "$(hb_bash 'make build')"
  ct_refused "the commit hand-off: $ct_name"
done
ct_repo at59 new
ct_session at59 60 'git commit -q -F x' tree ''
hb_expect "$clock_hook" 0 'make build after a commit at 59 active minutes' "$(hb_bash 'make build')"
ct_repo failed old
ct_session failed 62 'git commit -q -F x; echo exit $?' tree 'exit 1'
hb_expect "$clock_hook" 0 'make build after a failed commit (no new commit in the window)' "$(hb_bash 'make build')"
ct_repo failed-error old
ct_session failed-error 62 'git commit -F x 2>&1 | tail -5' tree 'lint: 3 errors'
hb_expect "$clock_hook" 0 'make build after a failed commit whose output has no error flag' "$(hb_bash 'make build')"
ct_repo failed-date old
ct_session failed-date 62 'git commit --date=2020-01-01 -m x' tree 'lint: 3 errors'
hb_expect "$clock_hook" 0 'make build after a failed commit with an author date option' "$(hb_bash 'make build')"
ct_repo gone new
ct_session gone 62 'git commit -q -F x' tree ''
rm -rf "$ct_tree"
hb_expect "$clock_hook" 0 'make build when the git call fails (the work tree is gone)' "$(hb_bash 'make build')"
# Text that names a commit is no commit call: a request blob, a prompt snapshot, and a reply text.
ct_repo text new
hb_session ct-text < <(
  hb_span 62 2
  printf '{"type":"api-request-blob","timestamp":"%s","body":"{\\"type\\":\\"assistant\\",\\"name\\":\\"Bash\\",\\"command\\":\\"git commit -m x\\"}"}\n' "$(hb_iso 1)"
  printf '{"type":"prompt_snapshot","timestamp":"%s","text":"git commit -m x"}\n' "$(hb_iso 1)"
  hb_text assistant 1 'Run git commit -m x when done.'
  hb_text user 0 x
)
hb_expect "$clock_hook" 0 'make build when a blob, a snapshot, and a reply only quote git commit' "$(hb_bash 'make build')"
# A coordinator message after the commit clears the trigger; a task notification does not.
ct_repo clear new
hb_session ct-clear < <(hb_span 62 2; hb_commit 1 c1 'git commit -m x' "$ct_tree"; hb_result 0 c1 ''; hb_text user 0 'The coordinator sent a message while you were working: go on')
hb_expect "$clock_hook" 0 'make build after a coordinator message that follows the commit' "$(hb_bash 'make build')"
hb_session ct-notify < <(hb_span 62 2; hb_commit 1 c1 'git commit -m x' "$ct_tree"; hb_result 0 c1 ''; hb_text user 0 '[SYSTEM NOTIFICATION] a task ended')
hb_expect "$clock_hook" 2 'make build after a task notification that follows the commit' "$(hb_bash 'make build')"
# A commit result that quotes the coordinator text still closes its commit call.
ct_repo quote new
hb_session ct-quote < <(hb_span 62 2; hb_commit 1 c1 'git commit -m x' "$ct_tree"; hb_result 0 c1 'The coordinator sent a message while you were working: go on')
hb_expect "$clock_hook" 2 'make build after a commit whose result quotes the coordinator text' "$(hb_bash 'make build')"
clock_forms "$tmp/ct-quiet" 'commit hand-off'

hb_expect "$clock_hook" 0 'no agent_id (the lead)' "$(printf '{"transcript_path":"%s/s.jsonl","tool_name":"Bash","tool_input":{"command":"make test"}}' "$hb_dir")"
hb_expect "$clock_hook" 0 'no transcript file' "$(printf '{"transcript_path":"%s/none/s.jsonl","agent_id":"a1","tool_name":"Bash","tool_input":{"command":"make test"}}' "$tmp")"
hb_expect "$clock_hook" 0 'input that is not JSON' 'not json'
for tool in Bash Read; do
  hook_registered "$settings" agent-clock.sh "$tool" ||
    { echo "FAIL: .claude/settings.json does not register agent-clock.sh for $tool"; failures=$((failures + 1)); }
done

fi # agent-clock
if case_block write-guard; then
# The sixth hook, write-guard.sh, refuses a Write over an existing run.md, plan.md, or analysis.md
# of a run folder: the Edit tool changes such a file. A new file and each other name pass.
write_hook="$(dirname "$0")/write-guard.sh"
wg_dir="$tmp/wg/.scratchpads/runs/r"
mkdir -p "$wg_dir" "$tmp/wg/docs"
for name in run.md plan.md analysis.md pr.md review-plan-1.md; do echo x > "$wg_dir/$name"; done
echo x > "$tmp/wg/docs/run.md"
# wg_expect <exit status> <path>: a Write input for the path gives the exit status.
wg_expect() {
  local code
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s","content":"y"}}' "$2" | "$write_hook" 2>"$tmp/write-err"
  code=$?
  [[ $code -eq $1 ]] || { echo "FAIL: write-guard: expected exit $1, got $code: $2"; failures=$((failures + 1)); }
}
for name in run.md plan.md analysis.md; do
  wg_expect 2 "$wg_dir/$name"
  grep -q 'with the Edit tool' "$tmp/write-err" ||
    { echo "FAIL: the write-guard message for $name does not name the Edit tool: $(cat "$tmp/write-err")"; failures=$((failures + 1)); }
done
wg_expect 0 "$wg_dir/pr.md"
wg_expect 0 "$wg_dir/review-plan-1.md"
wg_expect 0 "$tmp/wg/.scratchpads/runs/new/run.md"
wg_expect 0 "$tmp/wg/docs/run.md"
hook_registered "$settings" write-guard.sh Write ||
  { echo "FAIL: .claude/settings.json does not register write-guard.sh for Write"; failures=$((failures + 1)); }

fi # write-guard
if case_block holdout-keys; then
# git-guardrails.sh refuses a read of holdout-keys.md outside the listed forms: a Bash path word, a
# Read file_path, or a Grep path or glob that names the file. A mention of the name passes.
hk_dir="$tmp/hk"
mkdir -p "$hk_dir"
printf '## H90\nmade-up key points\n' > "$hk_dir/holdout-keys.md"
hk_run='.scratchpads/runs/r'
hk="$hk_run/holdout-keys.md"
for run in "head -20 $hk | cut -c1-40" "cat $hk" "sed -n 1,9p $hk" "rg H24 $hk" "rg -A1 '^## ' $hk" \
  "cd $hk_run && head holdout-keys.md" 'cat .scratchpads/runs/*/holdout-keys.md' "cat $hk|head" "(cat $hk)" \
  "head < $hk" "mv $hk $hk_run/notes.txt" "cat $hk >> $hk_run/notes.txt" "rg -n '^## ' $hk && cat $hk"; do
  expect_message 'reads holdout-keys.md' "$run"
done
expect_message 'a pattern that is not the bare name' "cat $hk"
for run in "rg '^## ' $hk" "rg -n '^## ' $hk" "rg -n \"^## \" '$hk'" \
  "scripts/eval/run.sh $hk_run/eval-p7 origin/main HEAD H90 p7 --holdout-keys $hk" \
  "WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh scripts/eval/run.sh $hk_run/eval-p7 origin/main HEAD H90 p7 --holdout-keys $hk" \
  "cat $hk_run/new-key.txt >> $hk" "mv $hk_run/new-keys.txt $hk" "mv -f $hk_run/new-keys.txt $hk" \
  "scripts/check-eval-keys.sh origin/main $hk_run"; do
  expect allow "$run"
done
# The eval call as the lead writes it from the main checkout: a cd head, R=... prefixes and
# NAME=value words, a path that ends in /scripts/eval/run.sh, with-lock.sh, and a log redirect.
hk_eval='/x/wt/scripts/eval/run.sh $R/eval-p7 origin/main HEAD H90 p7'
for run in "cd /x/wt && R=/x/runs/r && scripts/eval/run.sh \$R/eval-p7 origin/main HEAD H90 p7 --holdout-keys \$R/holdout-keys.md > \$R/logs/eval-p7.log 2>&1" \
  "R=/x/runs/r && scripts/eval/run.sh \$R/eval-p7 origin/main HEAD H90 p7 --holdout-keys \$R/holdout-keys.md" \
  "R=/x/runs/r; RUNS=1 $hk_eval --holdout-keys \$R/holdout-keys.md >> \$R/logs/eval.log 2>&1" \
  "cd /x/wt && scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys /x/runs/r/holdout-keys.md" \
  "ANSWER_MODEL=sonnet GRADER_MODEL=opus ../wt/scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk" \
  "scripts/with-lock.sh scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk 2>&1" \
  "WITH_LOCK_MAX_WAIT=0 /x/wt/scripts/with-lock.sh $hk_eval --holdout-keys $hk --holdout-keys /x/runs/q/holdout-keys.md"; do
  expect allow "$run"
done
# Near forms that still read the file: a command after the call, a redirect into the file, the file
# as another argument or in a variable value, and a name that is not listed (PATH can stub a tool).
for run in "cd /x/wt && scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk && cat $hk" \
  "scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk > $hk" \
  "scripts/eval/run.sh $hk a b H90 t --holdout-keys $hk" \
  "R=$hk && scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys \$R" \
  "PATH=/x/stub:\$PATH scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk" \
  "cat $hk_run/Holdout-Keys.md"; do
  expect_message 'reads holdout-keys.md' "$run"
done
# A log redirect whose target bash can expand to the file: a glob, or a variable (braced or
# not). The target must be a literal path that ends in .log.
for run in "R=/x/runs/r && scripts/eval/run.sh \$R/eval a b H90 t --holdout-keys \$R/holdout-keys.md > \$R/holdout-key*.md 2>&1" \
  "scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys /x/runs/r/holdout-keys.md > /x/runs/r/holdout-key?.md" \
  "R=/x/runs/r/holdout-key && scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk > \${R}s.md" \
  "R=/x/runs/r && scripts/eval/run.sh \$R/eval a b H90 t --holdout-keys \$R/holdout-keys.md > \$R/holdout-key\$S.md"; do
  expect_message 'reads holdout-keys.md' "$run"
done
# The block text names each redirect operator that the eval form takes, and each one passes.
expect_message '<op> one of >, >>, 1>, 1>>, 2>, and 2>>' "scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk > $hk"
for op in '>' '>>' '1>' '1>>' '2>' '2>>'; do
  expect allow "scripts/eval/run.sh $hk_run/eval a b H90 t --holdout-keys $hk $op $hk_run/logs/e.log 2>&1"
done
# A mention of the bare name passes from a folder that does not hold the file, and is refused from
# a folder that holds it.
for run in "rg -c 'refuses a read of \`holdout-keys.md\`' docs/workflow/evals.md" 'rg -n holdout-keys.md docs .claude' \
  'rg -l holdout-keys scripts'; do
  expect allow "$run" '' '' "$tmp"
done
expect block 'rg -n holdout-keys.md docs .claude' '' '' "$hk_dir"
# hk_tool <want> <hook input>: the verdict of the hook for a Read or Grep input; a block names the file.
hk_tool() {
  local got
  printf '%s' "$2" | "$hook" 2>"$tmp/hk.err"
  [[ $? -eq 2 ]] && got=block || got=allow
  [[ "$got" == allow ]] || grep -q 'reads holdout-keys.md' "$tmp/hk.err" || got="block ($(head -c 120 "$tmp/hk.err"))"
  [[ "$got" == "$1" ]] || { echo "FAIL: holdout-keys: expected $1, got $got: $2"; failures=$((failures + 1)); }
}
hk_tool block '{"tool_name":"Read","tool_input":{"file_path":"/w/.scratchpads/runs/r/holdout-keys.md"}}'
hk_tool allow '{"tool_name":"Read","tool_input":{"file_path":"/w/.scratchpads/runs/r/keys.md"}}'
hk_tool allow '{"tool_name":"Read","tool_input":{"file_path":"/w/.scratchpads/runs/r/holdout-keys.md.txt"}}'
hk_tool block '{"tool_name":"Read","tool_input":{"file_path":"/w/.scratchpads/runs/r/Holdout-Keys.md"}}'
hk_tool block '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"/w/.scratchpads/runs/r/HOLDOUT-KEYS.md"}}'
hk_tool block '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"/w/.scratchpads/runs/r/holdout-keys.md"}}'
hk_tool block '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"/w/.scratchpads/runs/r","glob":"holdout-keys.md"}}'
hk_tool allow '{"tool_name":"Grep","tool_input":{"pattern":"holdout-keys.md","path":"docs/workflow"}}'
hk_tool allow '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"/w/.scratchpads/runs/r"}}'
for tool in Read Grep; do
  hook_registered "$settings" git-guardrails.sh "$tool" ||
    { echo "FAIL: .claude/settings.json does not register git-guardrails.sh for $tool"; failures=$((failures + 1)); }
done
hook_registered "$tmp/old-settings.json" git-guardrails.sh Read &&
  { echo "FAIL: the registration check passed a settings file with no git-guardrails.sh entry for Read"; failures=$((failures + 1)); }
fi # holdout-keys
stop_hook="$(dirname "$0")/stop-guard.sh"
# lead_session <name>: write stdin as the lead transcript, and name its folder in hb_dir
lead_session() { hb_dir="$tmp/$1"; mkdir -p "$hb_dir"; cat > "$hb_dir/s.jsonl"; }
# stop_in <stop_hook_active> [<cwd>]: the Stop hook input of the lead
stop_in() { printf '{"hook_event_name":"Stop","transcript_path":"%s/s.jsonl","stop_hook_active":%s,"cwd":"%s"}' "$hb_dir" "$1" "${2:-$tmp}"; }
hb_agent_start() {
  hb_use 8 u4 Agent '{"prompt":"x","run_in_background":true}'
  hb_result 8 u4 'Async agent launched successfully. agentId: a2 (internal ID)'
}
# stop_fixture <name>: a git checkout with no commit, and its stop-shadow log path in stop_log
stop_fixture() { stop_fx="$tmp/$1"; mkdir -p "$stop_fx/.scratchpads/runs"; git init -q "$stop_fx"; stop_log="$stop_fx/.git/dirigible-stop-shadow.log"; }
# stop_run <name> <status> [<extra run.md line>]: a run folder of the fixture with one unticked phase
stop_run() {
  mkdir -p "$stop_fx/.scratchpads/runs/$1"
  printf '# Run %s\n\n- Status: %s\n- Branch: chore/%s\n%s\n## Phases\n\n- [x] 0 Open\n- [ ] 1 Analyze\n' "$1" "$2" "$1" "${3-}" > "$stop_fx/.scratchpads/runs/$1/run.md"
  printf '2026-10-28T10:00\t0\tx\n' > "$stop_fx/.scratchpads/runs/$1/decisions.tsv"
}
stop_lines() { if [[ -f "$stop_log" ]]; then wc -l < "$stop_log" | tr -d ' '; else echo 0; fi; }
# stop_expect <case> <input>: the hook exits 0 and prints nothing on stdout or stderr (it never blocks)
stop_expect() {
  local out code
  out="$(printf '%s' "$2" | "$stop_hook" 2>"$tmp/hb-err")"
  code=$?
  [[ $code -eq 0 ]] || { echo "FAIL: stop-guard.sh $1: expected exit 0, got $code: $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
  [[ -z "$out" && ! -s "$tmp/hb-err" ]] ||
    { echo "FAIL: stop-guard.sh $1: it printed output, so it blocks or talks: $out $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
}

# tail_session <name> <filler lines>: a shell starts, about 1 KB for each filler line, a second shell starts
tail_session() {
  hb_dir="$tmp/$1"; mkdir -p "$hb_dir"
  { hb_use 400 old1 Bash '{"command":"sleep 300","run_in_background":true}'
    hb_result 400 old1 'Command running in background with ID: bold. Output is being written to: /x'
    python3 -c '
import json, sys
line = json.dumps({"type": "user", "message": {"role": "user", "content": "x" * 1000}})
sys.stdout.write((line + "\n") * int(sys.argv[1]))
' "$2"
    hb_use 2 new1 Bash '{"command":"sleep 300","run_in_background":true}'
    hb_result 2 new1 'Command running in background with ID: bnew. Output is being written to: /x'
  } > "$hb_dir/s.jsonl"
}

# event_registered <settings file> <event> <hook script>: an entry of the event runs the script
event_registered() {
  python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get(sys.argv[2], [])
sys.exit(0 if any(h.get("command", "").replace("\"", "").endswith("/.claude/hooks/" + sys.argv[3]) for e in entries for h in e.get("hooks", [])) else 1)
' "$1" "$2" "$3" 2>/dev/null
}
# event_timeout <settings file> <event> <hook script>: the entry of the script sets a timeout of 1 to 120 seconds
event_timeout() {
  python3 -c '
import json, sys
entries = json.load(open(sys.argv[1])).get("hooks", {}).get(sys.argv[2], [])
found = [h for e in entries for h in e.get("hooks", []) if h.get("command", "").replace("\"", "").endswith("/.claude/hooks/" + sys.argv[3])]
sys.exit(0 if found and all(type(h.get("timeout")) is int and 1 <= h["timeout"] <= 120 for h in found) else 1)
' "$1" "$2" "$3" 2>/dev/null
}

if case_block stop-guard; then
# The seventh hook, stop-guard.sh, runs when the lead ends a turn. It never blocks: it appends a line to
# dirigible-stop-shadow.log in the git common dir. Rule A logs the stop while only background shells
# run (nothing wakes the loop when a shell ends). Rule B logs when no task runs, an open run has an
# unticked phase, and its run.md has no `waits: user` line.

# Rule A: only background shells run. The hook logs one line with its reason and does not block.
stop_fixture fx-shell
lead_session stop-shell < <(hb_bg_start)
stop_expect 'only a background shell runs' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 1 && "$(< "$stop_log")" == *' would-block-shell b1: only background shells run, no Monitor' ]] ||
  { echo "FAIL: rule A logs one would-block-shell line with its reason: $(cat "$stop_log" 2>&1)"; failures=$((failures + 1)); }
stop_expect 'rule A, second call' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 2 ]] || { echo "FAIL: rule A adds a line for each stop: $(stop_lines)"; failures=$((failures + 1)); }
stop_expect 'stop_hook_active is true' "$(stop_in true "$stop_fx")"
[[ "$(stop_lines)" == 2 ]] || { echo "FAIL: a stop with stop_hook_active true adds a line: $(stop_lines)"; failures=$((failures + 1)); }
stop_expect 'rule A outside a git checkout' "$(stop_in false "$tmp")"

stop_fixture fx-shell-pass
lead_session stop-shell-monitor < <(hb_bg_start; hb_mon_start 5)
stop_expect 'a shell and a Monitor' "$(stop_in false "$stop_fx")"
lead_session stop-shell-agent < <(hb_bg_start; hb_agent_start)
stop_expect 'a shell and a running agent' "$(stop_in false "$stop_fx")"
lead_session stop-shell-ended < <(hb_bg_start; hb_text user 3 '<task-notification><task-id>b1</task-id><status>completed</status></task-notification>')
stop_expect 'the shell ended' "$(stop_in false "$stop_fx")"
stop_expect 'no transcript file' "$(printf '{"transcript_path":"%s/none/s.jsonl","stop_hook_active":false,"cwd":"%s"}' "$tmp" "$stop_fx")"
stop_expect 'input that is not JSON' 'not json'
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: a pass case of rule A adds a line: $(cat "$stop_log")"; failures=$((failures + 1)); }

# Rule B, with a fixture checkout that holds the runs of the lead. A run is open when its run.md has a
# `- Status: open` line; the lead in the main checkout gets the run whose folder holds cwd, else the
# open run with the newest decisions.tsv row.
lead_session stop-idle < <(hb_text user 3 x)

stop_fixture fx-open
stop_run r1 open
stop_expect 'rule B does not block' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 1 && "$(< "$stop_log")" == *' would-block r1 via newest row: - [ ] 1 Analyze' ]] ||
  { echo "FAIL: rule B logs one would-block line for the open run: $(cat "$stop_log" 2>&1)"; failures=$((failures + 1)); }
stop_expect 'rule B, second call' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 2 ]] || { echo "FAIL: rule B adds a line for each stop: $(stop_lines)"; failures=$((failures + 1)); }

stop_fixture fx-done
stop_run r1 done
stop_expect 'a run with status done' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: a done run adds a line to the stop log"; failures=$((failures + 1)); }

stop_fixture fx-waits
stop_run r1 open 'waits: user (the plan gate)'
stop_expect 'a run that waits for the user' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: a waits: user line adds a line to the stop log"; failures=$((failures + 1)); }

stop_fixture fx-task
stop_run r1 open
lead_session stop-task-monitor < <(hb_bg_start; hb_mon_start 5)
stop_expect 'a running Monitor' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 0 ]] || { echo "FAIL: rule B logs while a Monitor runs"; failures=$((failures + 1)); }

stop_fixture fx-end20
stop_run r1 open
for i in $(seq 20); do echo "2026-10-28T10:00:0${i: -1}Z would-block r1 via newest row: - [ ] 1 Analyze" >> "$stop_log"; done
lead_session stop-end20 < <(hb_text user 3 x)
stop_expect 'a log with 20 would-block lines' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 && "$(tail -n 1 "$stop_log")" == *' done' ]] ||
  { echo "FAIL: 20 would-block lines end rule B with one done line: $(tail -n 2 "$stop_log")"; failures=$((failures + 1)); }
stop_expect 'a log with a done line' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 ]] || { echo "FAIL: a log with a done line gets a line"; failures=$((failures + 1)); }

stop_fixture fx-old
stop_run r1 open
echo "$(date -u -v-15d +%Y-%m-%dT%H:%M:%SZ) would-block r1 via newest row: - [ ] 1 Analyze" > "$stop_log"
stop_expect 'a log whose first line is 15 days old' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 2 && "$(tail -n 1 "$stop_log")" == *' done' ]] ||
  { echo "FAIL: a first line of 15 days ends rule B with one done line: $(tail -n 2 "$stop_log")"; failures=$((failures + 1)); }

stop_fixture fx-end20-shell
for i in $(seq 10); do echo "2026-10-28T10:00:0${i: -1}Z would-block-shell b1: only background shells run, no Monitor" >> "$stop_log"; done
for i in $(seq 10); do echo "2026-10-28T10:01:0${i: -1}Z would-block r1 via newest row: - [ ] 1 Analyze" >> "$stop_log"; done
lead_session stop-end20-shell < <(hb_bg_start)
stop_expect 'a log with 20 lines of both rules, a shell runs' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 && "$(tail -n 1 "$stop_log")" == *' done' ]] ||
  { echo "FAIL: 20 lines of both rules end rule A with one done line: $(tail -n 2 "$stop_log")"; failures=$((failures + 1)); }
stop_expect 'a log with a done line, a shell runs' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 21 ]] || { echo "FAIL: a log with a done line gets a rule A line"; failures=$((failures + 1)); }

# A done log ends the hook before any transcript read. A stub background-tasks.py leaves a marker
# file when the hook calls it, so no marker means no read.
real_stop_hook="$stop_hook"
stub_hooks="$tmp/stub-hooks"; mkdir -p "$stub_hooks"
cp "$(dirname "$0")/stop-guard.sh" "$(dirname "$0")/open-run.py" "$stub_hooks/"
printf 'import os\n\n\ndef running_tasks(path, *args, **kwargs):\n    open(os.environ["STUB_MARKER"], "w").close()\n    return {}\n' > "$stub_hooks/background-tasks.py"
stop_hook="$stub_hooks/stop-guard.sh"
export STUB_MARKER="$tmp/stub-marker"
stop_fixture fx-done-first
stop_run r1 open
lead_session stop-done-first < <(hb_text user 3 x)
rm -f "$STUB_MARKER"
stop_expect 'a log with no done line reads the transcript' "$(stop_in false "$stop_fx")"
[[ -e "$STUB_MARKER" ]] || { echo "FAIL: the stub background-tasks.py was not called, so the done-first case proves nothing"; failures=$((failures + 1)); }
echo "2026-10-28T10:00:00Z done" > "$stop_log"
rm -f "$STUB_MARKER"
stop_expect 'a done log, a transcript path that does not exist' "$(printf '{"transcript_path":"%s/none/s.jsonl","stop_hook_active":false,"cwd":"%s"}' "$tmp" "$stop_fx")"
stop_expect 'a done log, a transcript' "$(stop_in false "$stop_fx")"
[[ ! -e "$STUB_MARKER" && "$(stop_lines)" == 1 ]] || { echo "FAIL: a done log still reads the transcript or adds a line"; failures=$((failures + 1)); }
unset STUB_MARKER
stop_hook="$real_stop_hook"

# The lead transcript is read from its last 8 MiB only (the longest measured span of a background
# shell is 7.1 MiB). A task that starts before the tail is not found; a task that starts in the tail,
# 4 to 8 MiB before the end, is.
tail_session stop-tail 9000
stop_fixture fx-tail
stop_expect 'a transcript over the tail bound' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 1 && "$(< "$stop_log")" == *' would-block-shell bnew: '* ]] ||
  { echo "FAIL: a transcript over 8 MiB gives the task of its tail alone: $(cat "$stop_log" 2>&1)"; failures=$((failures + 1)); }
tail_session stop-tail-in 6500
stop_fixture fx-tail-in
stop_expect 'a task 6 MiB before the end' "$(stop_in false "$stop_fx")"
[[ "$(stop_lines)" == 1 && "$(< "$stop_log")" == *' would-block-shell bold,bnew: '* ]] ||
  { echo "FAIL: a shell that starts 6 MiB before the end is found: $(cat "$stop_log" 2>&1)"; failures=$((failures + 1)); }

event_registered "$settings" Stop stop-guard.sh || { echo "FAIL: .claude/settings.json does not register stop-guard.sh for Stop"; failures=$((failures + 1)); }
event_registered "$tmp/old-settings.json" Stop stop-guard.sh && { echo "FAIL: the Stop registration check passed a settings file with no stop-guard.sh"; failures=$((failures + 1)); }
event_timeout "$settings" Stop stop-guard.sh || { echo "FAIL: .claude/settings.json sets no timeout of 1 to 120 seconds on stop-guard.sh"; failures=$((failures + 1)); }
event_timeout "$tmp/old-settings.json" Stop stop-guard.sh && { echo "FAIL: the Stop timeout check passed a settings file with no stop-guard.sh"; failures=$((failures + 1)); }

fi # stop-guard
if case_block pre-compact; then
# The eighth and ninth hooks keep the run state through a compaction. pre-compact.sh prints what the
# summary must keep (Claude Code adds the stdout of PreCompact to the compaction instructions). It
# names the open run of cwd, the branch, the worktree, the first unticked slice, and the running
# background tasks, in 120 words or fewer, and copies no message of the user. post-compact.sh appends
# one line to dirigible-compactions.log in the git common dir.
pre_hook="$(dirname "$0")/pre-compact.sh"
post_hook="$(dirname "$0")/post-compact.sh"
# pc_in <hook event> <cwd> [<summary>]: the hook input for the lead transcript in hb_dir
pc_in() {
  printf '{"hook_event_name":"%s","trigger":"auto","cwd":"%s","transcript_path":"%s/s.jsonl","compact_summary":"%s"}' "$1" "$2" "$hb_dir" "${3-}"
}
# pc_run <cwd>: run PreCompact; the output is in pc_out, the exit status must be 0
pc_run() {
  pc_out="$(pc_in PreCompact "$1" | "$pre_hook" 2>"$tmp/hb-err")"
  [[ $? -eq 0 && ! -s "$tmp/hb-err" ]] || { echo "FAIL: pre-compact.sh at $1: exit not 0 or stderr: $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
}
# pc_has <case> <text>: pc_out holds the text
pc_has() { [[ "$pc_out" == *"$2"* ]] || { echo "FAIL: pre-compact.sh $1: no '$2' in: $pc_out"; failures=$((failures + 1)); }; }
pc_lacks() { [[ "$pc_out" != *"$2"* ]] || { echo "FAIL: pre-compact.sh $1: '$2' in: $pc_out"; failures=$((failures + 1)); }; }
# pc_run_md <name> <status> <branch> <row time>: a run folder of the fixture with two slices, one ticked
pc_run_md() {
  mkdir -p "$stop_fx/.scratchpads/runs/$1"
  printf '# Run %s\n\n- Status: %s\n- Branch: %s\n\n## Phases\n\n- [x] 0 Open\n- [ ] 4 Implement\n\n## Slices\n\n- [x] S1 first slice\n- [ ] S2 the next slice of %s\n' "$1" "$2" "$3" "$1" > "$stop_fx/.scratchpads/runs/$1/run.md"
  printf '%s\t0\tx\n' "$4" > "$stop_fx/.scratchpads/runs/$1/decisions.tsv"
}

# A run worktree: the open run whose last Branch line names the branch of cwd.
stop_fixture pc-branch
git -C "$stop_fx" worktree add -q --orphan -b chore/x "$stop_fx-wt"
pc_main="$(cd -P "$stop_fx" && pwd)"
pc_wt="$(cd -P "$stop_fx-wt" && pwd)"
pc_run_md chore-x open chore/x 2026-10-28T10:00
pc_run_md other open chore/other 2026-10-28T12:00
lead_session pc-tasks < <(hb_bg_start)
pc_run "$pc_wt"
pc_has 'run worktree' "$pc_main/.scratchpads/runs/chore-x"
pc_has 'run worktree' 'Branch: chore/x'
pc_has 'run worktree' "Worktree: $pc_wt"
pc_has 'run worktree' 'S2 the next slice of chore-x'
pc_has 'run worktree' 'b1 (shell)'
pc_lacks 'run worktree' "runs/other"

# The main checkout: the open run whose folder holds cwd, else the open run with the newest row.
stop_fixture pc-main
pc_run_md older open chore/older 2026-10-28T09:00
pc_run_md newer open chore/newer 2026-10-28T12:00
pc_main="$(cd -P "$stop_fx" && pwd)"
pc_run "$pc_main/.scratchpads/runs/older"
pc_has 'cwd inside the older run' "$pc_main/.scratchpads/runs/older"
pc_lacks 'cwd inside the older run' "runs/newer"
pc_lacks 'cwd inside the older run' 'newest row'
pc_run "$pc_main"
pc_has 'cwd at the checkout top' "$pc_main/.scratchpads/runs/newer"
pc_has 'cwd at the checkout top' 'newest row'
pc_lacks 'cwd at the checkout top' "runs/older"

# No open run: the keep list alone, and exit 0.
stop_fixture pc-done
pc_run_md old done chore/old 2026-10-28T09:00
pc_run "$stop_fx"
pc_has 'a done run' 'Keep in the summary'
pc_lacks 'a done run' 'runs/old'
pc_lacks 'a done run' 'Run folder'
pc_run "$tmp"
pc_has 'cwd outside a git checkout' 'Keep in the summary'
pc_lacks 'cwd outside a git checkout' 'Run folder'
pc_out="$(printf 'not json' | "$pre_hook" 2>&1)"
[[ $? -eq 0 ]] && pc_has 'input that is not JSON' 'Keep in the summary' || { echo "FAIL: pre-compact.sh exits non-zero on input that is not JSON"; failures=$((failures + 1)); }

# The output has 120 words or fewer, and holds no text of a user message.
stop_fixture pc-cap
pc_run_md cap open chore/cap 2026-10-28T10:00
lead_session pc-cap-tasks < <(
  for n in $(seq 30); do hb_text user $((200 - n)) "SECRET-USER-TEXT-$n do not copy this instruction"; done
  for n in $(seq 12); do
    hb_use 12 "t$n" Bash '{"command":"x","run_in_background":true}'
    hb_result 12 "t$n" "Command running in background with ID: task$n. Output is being written to: /x"
  done
)
pc_run "$stop_fx"
pc_words="$(printf '%s' "$pc_out" | wc -w | tr -d ' ')"
(( pc_words <= 120 )) || { echo "FAIL: pre-compact.sh prints $pc_words words, over the 120 of the cap: $pc_out"; failures=$((failures + 1)); }
pc_has '12 background tasks' 'task1 (shell)'
pc_lacks 'user messages' 'SECRET-USER-TEXT'

# The same 8 MiB tail bounds the transcript read of the compaction hook.
stop_fixture pc-tail
tail_session pc-tail-session 9000
pc_run "$stop_fx"
pc_has 'a transcript over the tail bound' 'bnew (shell)'
pc_lacks 'a transcript over the tail bound' 'bold'
stop_fixture pc-tail-in
tail_session pc-tail-in-session 6500
pc_run "$stop_fx"
pc_has 'a task 6 MiB before the end' 'bold (shell)'
pc_has 'a task 6 MiB before the end' 'bnew (shell)'

# post-compact.sh: one line for each compaction, run-folder yes or no.
stop_fixture pc-post
pc_log="$stop_fx/.git/dirigible-compactions.log"
lead_session pc-post-session < <(hb_text user 3 x)
pc_in PostCompact "$stop_fx" 'The run is in .scratchpads/runs/2026-10-28-x. Next: S2.' | "$post_hook" 2>"$tmp/hb-err"
pc_in PostCompact "$stop_fx" 'A summary with no run folder.' | "$post_hook" 2>>"$tmp/hb-err"
printf '{"hook_event_name":"PostCompact","cwd":"%s","agent_id":"a7","compact_summary":"x .scratchpads/runs/y"}' "$stop_fx" | "$post_hook" 2>>"$tmp/hb-err"
[[ ! -s "$tmp/hb-err" && "$(wc -l < "$pc_log" 2>/dev/null | tr -d ' ')" == 3 ]] ||
  { echo "FAIL: post-compact.sh writes one line for each of 3 compactions: $(cat "$pc_log" 2>&1) $(cat "$tmp/hb-err")"; failures=$((failures + 1)); }
pc_lines="$(sed -E 's/^[0-9T:Z-]+ //' "$pc_log" 2>/dev/null)"
[[ "$pc_lines" == $'lead run-folder: yes\nlead run-folder: no\na7 run-folder: yes' ]] ||
  { echo "FAIL: post-compact.sh lines have the agent and the answer: $pc_lines"; failures=$((failures + 1)); }
[[ "$(head -n 1 "$pc_log" 2>/dev/null)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]] ||
  { echo "FAIL: post-compact.sh line does not start with a UTC time: $(head -n 1 "$pc_log" 2>&1)"; failures=$((failures + 1)); }
printf 'not json' | "$post_hook" 2>"$tmp/hb-err"
[[ $? -eq 0 && ! -s "$tmp/hb-err" && "$(wc -l < "$pc_log" | tr -d ' ')" == 3 ]] ||
  { echo "FAIL: post-compact.sh on input that is not JSON adds a line or fails"; failures=$((failures + 1)); }
pc_in PostCompact "$tmp" 'x' | "$post_hook" 2>"$tmp/hb-err"
[[ $? -eq 0 && ! -s "$tmp/hb-err" ]] || { echo "FAIL: post-compact.sh outside a git checkout fails"; failures=$((failures + 1)); }

event_registered "$settings" PreCompact pre-compact.sh || { echo "FAIL: .claude/settings.json does not register pre-compact.sh for PreCompact"; failures=$((failures + 1)); }
event_registered "$settings" PostCompact post-compact.sh || { echo "FAIL: .claude/settings.json does not register post-compact.sh for PostCompact"; failures=$((failures + 1)); }
event_registered "$tmp/old-settings.json" PreCompact pre-compact.sh && { echo "FAIL: the PreCompact registration check passed a settings file with no pre-compact.sh"; failures=$((failures + 1)); }
event_timeout "$settings" PreCompact pre-compact.sh || { echo "FAIL: .claude/settings.json sets no timeout of 1 to 120 seconds on pre-compact.sh"; failures=$((failures + 1)); }


fi # pre-compact
[[ $failures -eq 0 ]] || exit 1
[[ -n "${HOOK_CASES:-}" ]] || echo "git-guardrails: all cases pass"
