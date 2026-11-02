#!/bin/bash
# PreToolUse hook for Bash: block git commands that discard work, skip checks, or bypass
# the pull request flow. Permission rules in settings.json match only command prefixes;
# this hook matches the flag anywhere in the whole command text, quoted text too. A quoted
# rule is still a rule, so the message tells the agent how to write text that is only data.
# Exit 2 blocks the command and shows the message to the agent.

# block <reason> [<way>]: with no way, the message names the deliver flow.
block() {
  echo "BLOCKED by .claude/hooks/git-guardrails.sh: '$COMMAND' $1. ${2:-This command can discard work or bypass the checks. Use the deliver flow: push the run branch and merge through a pull request.}" >&2
  echo "If the matched text is only data, write it with the Write tool, a decisions.tsv row with log-decision.sh --from <file>, or a commit message with git commit -F .scratchpads/commit-msg.txt." >&2
  exit 2
}

# block_merge: the merge block names the one route and has no data hint.
block_merge() {
  echo "BLOCKED by .claude/hooks/git-guardrails.sh: '$COMMAND' merges a pull request outside scripts/land.sh. Run scripts/land.sh \"<title>\" <body file>: it runs the governance check and the checks, then merges. If it stops, run the same command again." >&2
  exit 2
}

# matches <ere> <text>: 0 when a line of the text matches, as grep -qE does on a here-string. A
# pattern with ^ or $ anchors each line, so the text is read line by line.
matches() {
  local line
  while IFS= read -r line; do
    [[ "$line" =~ $1 ]] && return 0
  done <<< "$2"
  return 1
}

# plutil reads JSON and ships with every macOS; jq does not ship with macOS 14.
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat > "$input"
if ! COMMAND="$(plutil -extract tool_input.command raw -o - "$input" 2>/dev/null)"; then
  COMMAND="(unreadable hook input)"
  block "cannot be checked"
fi

# cut_bodies <sink|all>: print $COMMAND without the body and the end line of each heredoc that is
# data. A body is data when the first line is `cat` or `tee` with a redirect or a file argument to a
# plain file, and only the marker (or the marker and one `> file`) ends that line. In mode all, the
# body of python3, node, perl, or ruby with no -c or -e goes too: only the lock-value rule and the
# log-decision rule skip it, because an interpreter runs its body. One `cd <word> &&` before the
# first word is not part of that line. A body stays when the end line is missing or not exact, when
# the first line has a second marker, a here-string, a pipe, or another list, and when an unquoted
# marker has `$(` or a backtick in the body (the shell runs them). After a line that it can not
# read, it cuts no more.
cut_bodies() {
  local mode="$1" line head tail marker dash quoted body i j k n ones kind has_arg name w out="" cut
  local bt='`' lines=() ws=()
  local word="[^[:space:];&|<>()${bt}]+"
  local start_re='^(.*[^<])?<<(-?)[[:space:]]*(\\?[A-Za-z0-9_.-]+|'"'"'[A-Za-z0-9_.-]+'"'"'|"[A-Za-z0-9_.-]+")(.*)$'
  local sink_re="^[[:space:]]*(cat|tee)(([[:space:]]+$word)|([[:space:]]*>>?[[:space:]]*$word))*[[:space:]]*\$"
  local tail_re="^[[:space:]]*(>>?[[:space:]]*$word)?[[:space:]]*\$"
  local redirect_re="(^|[[:space:]])>>?[[:space:]]*$word"
  local interp_re='^[[:space:]]*(python3?|node|perl|ruby)([[:space:]]+-)?[[:space:]]*$'
  if [[ "$COMMAND" != *'<<'* ]]; then printf '%s' "$COMMAND"; return; fi
  while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done <<< "$COMMAND"
  n=${#lines[@]}
  i=0
  while ((i < n)); do
    line="${lines[i]}"
    out+="$line"$'\n'
    i=$((i + 1))
    [[ "$line" == *'<<'* ]] || continue
    ones="${line//[^<]/}"
    if ((${#ones} != 2)) || ! [[ "$line" =~ $start_re ]]; then
      while ((i < n)); do out+="${lines[i]}"$'\n'; i=$((i + 1)); done
      break
    fi
    head="${BASH_REMATCH[1]}" dash="${BASH_REMATCH[2]}" marker="${BASH_REMATCH[3]}" tail="${BASH_REMATCH[4]}"
    quoted=0
    [[ "$marker" == [\\\'\"]* ]] && quoted=1
    marker="${marker#\\}"
    marker="${marker#[\'\"]}"
    marker="${marker%[\'\"]}"
    j=$i
    while ((j < n)); do
      w="${lines[j]}"
      [[ -n "$dash" ]] && w="${w#"${w%%[!$'\t']*}"}"
      [[ "$w" == "$marker" ]] && break
      j=$((j + 1))
    done
    if ((j >= n)); then
      while ((i < n)); do out+="${lines[i]}"$'\n'; i=$((i + 1)); done
      break
    fi
    kind=none
    [[ "$head" =~ ^[[:space:]]*cd[[:space:]]+[^[:space:]\;\&\|\<\>]+[[:space:]]*\&\&(.*)$ ]] && head="${BASH_REMATCH[1]}"
    if [[ "$head" =~ $sink_re ]]; then
      name="${BASH_REMATCH[1]}"
    else
      name=""
    fi
    if [[ -n "$name" && "$tail" =~ $tail_re ]]; then
      if [[ "$head $tail" =~ $redirect_re ]]; then
        kind=sink
      elif [[ "$name" == tee ]]; then
        has_arg=0
        read -ra ws <<< "$head"
        for w in "${ws[@]}"; do [[ "$w" == tee || "$w" == -* || "$w" == *'>'* ]] || has_arg=1; done
        ((has_arg)) && kind=sink
      fi
    elif [[ "$head" =~ $interp_re && "$tail" =~ ^[[:space:]]*$ && "$mode" == all ]]; then
      kind=interpreter
    fi
    cut=0
    if [[ "$kind" != none ]]; then
      body=""
      for ((k = i; k < j; k++)); do body+="${lines[k]}"$'\n'; done
      if ((quoted)) || [[ "$body" != *'$('* && "$body" != *"$bt"* ]]; then cut=1; fi
    fi
    if ((cut)); then
      i=$((j + 1))
    else
      while ((i <= j)); do out+="${lines[i]}"$'\n'; i=$((i + 1)); done
    fi
  done
  printf '%s' "$out"
}
SINK_CUT="$(cut_bodies sink)"
DATA_CUT="$(cut_bodies all)"

# Join backslash-newline continuations, as the shell does. Make each run of tabs and spaces
# one space, so the patterns match `git<TAB>push` and `git  push` too.
joined="${SINK_CUT//\\$'\n'/ }"
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
)

# The only allowed change to the hooks path is the one `make setup` makes. A read with no value
# (`git [-C <dir>] config [get] [--local] [--worktree] [--get] [--get-all] [--show-origin]
# core.hooksPath [2>/dev/null]`, flags in any order) is allowed too, only as a whole command:
# `xargs git config core.hooksPath` is a write. The key matches in
# any case. Each command of a chain or a substitution is one line; a line that is not one of the
# two forms and names the key is a change. A direct write of .git/config is not checked.
hooks_key='[Cc][Oo][Rr][Ee]\.[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]'
if [[ "$joined" =~ $hooks_key ]]; then
  hooks_read='^ *git( +-C +[^ ]+)* +config( +get)?( +--(local|worktree|get|get-all|show-origin))* +core\.hookspath( +2>/dev/null)? *$'
  hooks_set='^ *git( +-C +[^ ]+)* +config( +--local)? +core\.hookspath +\.githooks *$'
  while IFS= read -r line; do
    [[ "$line" == *core.hookspath* && ! "$line" =~ $hooks_read && ! "$line" =~ $hooks_set ]] && block "changes core.hooksPath"
  done < <(sed -E "s/$hooks_key/core.hookspath/g" <<< "$joined" |
    tr -s '\t ' '  ' | awk '{ gsub(/&&|\|\||[;&|()`]/, "\n"); print }')
fi

# The joined text with one space for each run of tabs and spaces, the git global options removed,
# and the new lines kept, so `git -C <path>  commit` reads as `git commit` in the two chain rules.
chain_text() {
  tr -s '\t ' '  ' <<< "${1//\\$'\n'/ }" | sed -E "s/git( +-[Cc] +('[^']*'|\"[^\"]*\"|[^ ]+))+/git/g"
}
chained="$(chain_text "$SINK_CUT")"
if [[ "$DATA_CUT" == "$SINK_CUT" ]]; then chained_data="$chained"; else chained_data="$(chain_text "$DATA_CUT")"; fi

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
# in row text is data. log-decision.sh also counts only at a command start, after the same prefix
# words, so a read of the script (cat, sed -n, head) after a commit or a build passes. Limits: in
# quoted data, git commit, make, or swift after `;`, `|`, `&`, `(`, or a new line still blocks:
# write the row file with the Write tool and log it with
# log-decision.sh --from <file>. A command after another wrapper word (nice, nohup, caffeinate,
# xcrun) or after a quote character is not blocked.
word="('[^']*'|\"[^\"]*\"|[^[:space:]]+)"
start="(^|[;|&(]|"$'\n'") ?(\{ |! |if |then |do |else |while |[A-Za-z_][A-Za-z0-9_]*=$word |time |env |bash |[^[:space:]]*with-lock\.sh |[^[:space:]]*probe\.sh $word )*"
if [[ "$chained_data" =~ $start(git\ commit|make|swift)([[:space:]].*)?$start[^[:space:]]*log-decision\.sh ]]; then
  # Group 6 is optional, so the start before log-decision.sh can take a new line right after make.
  # Group 7 is that separator: it stays in the test below.
  middle="${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
  drop_safe_joins "${middle//||/}"
  if [[ "$stripped" =~ [\;\|\&]|$'\n' ]]; then
    block "logs a decisions.tsv row after git commit, make, or swift joined by ;, a new line, a pipe, or & (the row can come before the status). Run log-decision.sh in its own command after you read the status"
  fi
fi

# Only the check-changed recipe of the Makefile writes the pass stamp that land.sh reuses, so a
# direct write cannot skip the land check. A command that names the stamp file is blocked too.
if [[ "$NORMALIZED" == *dirigible-check-stamp* || "$NORMALIZED" == *'check-stamp.sh write'* ]]; then
  block "names the pass stamp or writes it (only make check-changed writes it; read it with scripts/check-stamp.sh read origin/main)"
fi
# Only a passing make test-slow or test-slow-push writes the slow-run date that
# scripts/check-changed.sh reads, so a direct write cannot skip the daily slow run. A command that
# names the date file is blocked too.
if [[ "$NORMALIZED" == *dirigible-slow-date* ]]; then
  block "names the slow-run date file (only a passing make test-slow or make test-slow-push writes it)"
fi
# mask_quoted_pipes <text>: print the text with each | inside single quotes as \003, so a quoted
# alternation (grep -E 'a|b') does not split a command. A single line with balanced quotes only; a
# substitution, $'..', and a new line keep the text as it is (the safe side: more splits).
mask_quoted_pipes() {
  if [[ "$1" != *\'* || "$1" != *'|'* || "$1" == *$'\n'* || "$1" == *'$('* || "$1" == *'`'* ||
    "$1" == *'<('* || "$1" == *'>('* || "$1" == *"\$'"* ]]; then
    printf '%s\n' "$1"
    return
  fi
  awk '{
    s = $0; n = length(s); out = ""; q = ""
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "\\" && q != "s") { out = out c substr(s, i + 1, 1); i++; continue }
      if (q == "") { if (c == "\047") q = "s"; else if (c == "\"") q = "d" }
      else if (q == "s") { if (c == "\047") q = ""; else if (c == "|") c = "\003" }
      else if (c == "\"") q = ""
      out = out c
    }
    print (q == "" ? out : s)
  }' <<< "$1"
}
# reads_only <name>: a command that names the file <name> must hold only reads. When no segment
# names <name>, the command is none of its business. Else each segment of the whole command (split
# on && || ; | a lone & and a new line; a \| or a quoted | does not split) is one of:
#   - the allowed assignment: one word NAME=VALUE, VALUE a path that holds <name>, with at most one
#     $(git rev-parse ...) and no other substitution, backtick, quote, ; & | < >;
#   - a `for X in ...` head, `do` (with or without a command after it), or `done`;
#   - a segment that names <name>: its first word is cat, grep, head, tail, wc, ls, stat, test, [,
#     rg, awk, sort (no -o), sed (with -n and no -i), or git grep, and no redirect path runs up to
#     the name (quotes and a $(...) part are part of the path, and the path stops at `*` and `[`);
#   - a segment that does not name <name>: `cd <one word>` with no redirect; one plain NAME=word
#     (word of letters, digits, and _./:@%+,=-) whose NAME is none of PATH, IFS, ENV, BASH_ENV,
#     CDPATH, SHELLOPTS, HOME, PAGER, RIPGREP_CONFIG_PATH, or a GIT_, LD_, or DYLD_ name, in any
#     case (the zsh arrays path and cdpath set PATH and CDPATH), because
#     such a name makes a read tool run another program; or a first word cat, ls, echo, test, [,
#     wc, grep, head, tail, or cut, with no < or > except 2>/dev/null and 2>&1.
# A substitution other than $(git rev-parse ...), $(cat ...), and $(ls ...), a backtick, <(, and >(
# block. An allowlist, because a list of write forms missed sed -i, dd of=, a variable, and a pipe
# into xargs. A path that starts with ../ or / and has no .git in it is a folder of that name (a
# worktree), not the file. The read tools awk, sed, rg, sort, and git grep can run a program.
reads_only() {
  local name="$1" line first second token named any=0 i rest assigned sep=$'\002' bar=$'\003'
  local redirect=">[>|]?[[:space:]]*[\"']?(\\\$\\([^)]*\\))?[^;&|[:space:]*[]*$1"
  local value="[\"']?(\\\$\\(git rev-parse [^()\`<>&;|]*\\))?[^][:space:]()\`\$<>&;|\"']*$1[^][:space:]()\`\$<>&;|\"']*[\"']?"
  local cd_form='^cd[[:space:]]+[^[:space:]<>]+$'
  local plain_assign='^([A-Za-z_][A-Za-z0-9_]*)=[A-Za-z0-9_./:@%+,=-]*$'
  local program_names='^(path|ifs|env|bash_env|cdpath|shellopts|home|pager|ripgrep_config_path|git_.*|ld_.*|dyld_.*)$'
  local -a segs=() kinds=()
  local name_re="[^[:space:]]*$name([^A-Za-z0-9_.-]|\$)" flag_o='(^|[[:space:]])-[a-zA-Z]*o' flag_i='(^|[[:space:]])-[a-zA-Z]*i' flag_n='(^|[[:space:]])-[a-zA-Z]*n'
  [[ "$MASKED" == *"${name%%.*}"* ]] || return 0
  while IFS= read -r line; do
    line="${line//$sep/&}"
    line="${line//$bar/|}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && segs+=("$line")
  done < <(sed -E "s/\\\\\\|/ /g; s/&>/${sep}>/g; s/>&/>${sep}/g" <<< "$MASKED" | awk '{ gsub(/&&|\|\||;|\||&/, "\n"); print }')
  for line in "${segs[@]}"; do
    named=0
    rest="$line"
    while [[ "$rest" =~ $name_re ]]; do
      token="${BASH_REMATCH[0]}"
      rest="${rest#*"$token"}"
      token="${token#[\"\']}"
      [[ -n "$token" && "$token" =~ ^(\.\./|/) && "$token" != *.git* ]] || named=1
    done
    kinds+=("$named")
    any=$((any + named))
  done
  [[ $any -eq 0 ]] && return 0
  for i in "${!segs[@]}"; do
    line="${segs[$i]}" named="${kinds[$i]}"
    rest="$(sed -E 's/\$\((git rev-parse|cat|ls) [^()`<>]*\)//g' <<< "$line")"
    [[ "$rest" == *'$('* || "$rest" == *'`'* || "$rest" == *'<('* || "$rest" == *'>('* ]] && return 1
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=$value$ ]] && continue
    [[ "$line" =~ ^for\ [A-Za-z_][A-Za-z0-9_]*\ in\  ]] && continue
    [[ "$line" == done || "$line" == do ]] && continue
    [[ "$line" == "do "* ]] && line="${line#do }"
    read -r first second _ <<< "$line"
    if [[ $named -eq 1 ]]; then
      case "$first" in
        cat | grep | head | tail | wc | ls | stat | test | '[' | rg | awk) ;;
        sort) [[ "$line" =~ $flag_o ]] && return 1 ;;
        sed) [[ "$line" =~ $flag_i ]] && return 1
          [[ "$line" =~ $flag_n ]] || return 1 ;;
        git) [[ "$second" == grep ]] || return 1 ;;
        *) return 1 ;;
      esac
      [[ "$line" =~ $redirect ]] && return 1
    else
      if [[ "$line" =~ $cd_form ]]; then
        continue
      elif [[ "$line" =~ $plain_assign ]]; then
        assigned="$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[1]}")"
        [[ "$assigned" =~ $program_names ]] && return 1
        continue
      fi
      case "$first" in
        cat | ls | echo | test | '[' | wc | grep | head | tail | cut) ;;
        *) return 1 ;;
      esac
      rest="${line//2>\/dev\/null/}"
      rest="${rest//2>&1/}"
      [[ "$rest" == *[\<\>]* ]] && return 1
    fi
  done
  return 0
}
MASKED="$(mask_quoted_pipes "$UNSPLIT")"
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
  block "names the build lock in a command that is not a read (run the build or test through scripts/with-lock.sh, which takes the lock and removes only a lock that it took; read the lock with ls or cat, joined only with cd or a plain assignment)"
fi
# Only scripts/verify-copy.sh start takes the screen lock and stop removes it, so a hand-written
# remove cannot free the screen for a second verify copy. A read is allowed.
if ! reads_only dirigible-screen; then
  block "names the screen lock of the verify copy in a command that is not a read (only scripts/verify-copy.sh start takes it and stop removes it; read it with ls or cat)"
fi
# Only scripts/test-hooks.sh appends to the hooks pass stamp, after a pass of the whole list, so a
# Bash command cannot write it to skip the hook tests. A read is allowed. This rule covers only the
# Bash tool, not the Edit and Write tools.
if ! reads_only dirigible-hooks-stamp; then
  block "names the hooks pass stamp in a command that is not a read (only scripts/test-hooks.sh appends to it after a pass; read it with cat or grep)"
fi
# run.md, plan.md, and analysis.md of a run change only with the Edit tool (AGENTS.md, Run ledger).
# run_file_write prints the name and exits 2 when a segment of $SINK_CUT (split on && || ; | & and a
# new line, outside quotes; an interpreter heredoc body stays with its segment) names one of them and
# holds a write form. A segment names the file when (^|[/"'[:space:]=])<name>([^A-Za-z0-9_.-]|$)
# matches, or when it uses a variable whose assignment in the command holds the name. Write forms,
# read with each quoted string that holds a space blanked (a printf row is data): sed or perl with
# -i, -i<suffix>, or --in-place; a > or >> redirect into the name or into such a variable; tee; rm;
# truncate; dd of=<name>; mv or cp without -n onto the name; python with -c, -, or a heredoc; node,
# perl, or ruby with -e, --eval, -, or a heredoc. The command word of sed, perl, tee, rm, truncate, dd,
# mv, and cp counts only at the start of a segment, after a prefix word (time, env, sudo, command,
# exec, nohup, nice, xargs, builtin) with its options (sudo -u root, nice -n 5, xargs -I{}), an
# assignment, do, then, and the like, so rg -n tee run.md reads. A list of write forms, not of
# reads: the names occur in many data texts (rows, briefs, rg patterns). Out of scope: a script file
# that holds the name (python3 fix.py), a write inside $(...), a backtick, sh -c, bash -c, find -exec, mv of a
# guarded file to another name, git checkout or restore, awk -i inplace, ed, sponge, and a variable
# of an earlier Bash call. python3 runs only when the text holds a name.
run_file_write() {
  [[ "$SINK_CUT" =~ (run|plan|analysis)\.md ]] || return 0
  printf '%s' "$SINK_CUT" | python3 -I -c '
import re, sys
text = sys.stdin.read().replace("\\\n", " ")
name_rx = re.compile(r"(^|[/\"\x27\s=])(run|plan|analysis)\.md([^A-Za-z0-9_.-]|$)")
marker_rx = re.compile(r"<<-?\s*[\x27\"\\]?(\w+)[\x27\"]?")
interp_rx = re.compile(r"(^|[\s;&|(])(python3?(?:\.\d+)?|node|perl|ruby)(\s|$)")
prefix = r"(?:time|env|sudo|command|exec|nohup|nice|xargs|builtin)(?:\s+(?:-[uCDEgIhLnPSstTUad]\s+\S+|-\S+))*\s"
word = r"(^(?:[\s({]|(?:do|then|else|if|while|!|\{)\s|" + prefix + r"|[A-Za-z_]\w*=\S*\s)*)"
def split_ops(line):
    parts, cur, q, i = [], "", "", 0
    while i < len(line):
        c = line[i]
        if q:
            cur += c
            if c == q:
                q = ""
            elif c == "\\" and q == "\"" and i + 1 < len(line):
                cur += line[i + 1]
                i += 1
        elif c in "\x27\"":
            q = c
            cur += c
        elif c == "\\" and i + 1 < len(line):
            cur += c + line[i + 1]
            i += 1
        elif c in ";|&":
            if c == "&" and (line[i + 1:i + 2] == ">" or line[i - 1:i] in (">", "<")):
                cur += c
            else:
                parts.append(cur)
                cur = ""
                if line[i + 1:i + 2] == c and c != ";":
                    i += 1
        else:
            cur += c
        i += 1
    parts.append(cur)
    return parts
def segments(text):
    lines, segs, i = text.split("\n"), [], 0
    while i < len(lines):
        line, body = lines[i], ""
        i += 1
        m = marker_rx.search(line)
        if m:
            j = i
            while j < len(lines) and lines[j].strip() != m.group(1):
                j += 1
            if j < len(lines):
                body = "\n".join(lines[i:j])
                i = j + 1
        parts = split_ops(line)
        owner = next((k for k, p in enumerate(parts) if "<<" in p), len(parts) - 1)
        segs += [(p, body if k == owner else "") for k, p in enumerate(parts) if p.strip()]
    return segs
def blank(m):
    return " \"\" " if re.search(r"\s", m.group(0)[1:-1]) else m.group(0)
gvars = {}
for m in re.finditer(r"\b([A-Za-z_]\w*)=(\"[^\"]*\"|\x27[^\x27]*\x27|[^\s;&|]*)", text):
    n = name_rx.search("=" + m.group(2).strip("\"\x27") + " ")
    if n:
        gvars[m.group(1)] = n.group(2) + ".md"
var_rx = r"\$\{?(%s)\b" % "|".join(gvars) if gvars else None
def named(s):
    m = name_rx.search(s)
    if m:
        return m.group(2) + ".md"
    m = var_rx and re.search(var_rx, s)
    return m and gvars[m.group(1)]
def writes(seg):
    if re.search(word + r"(sed|perl)\s", seg) and re.search(r"\s(-[A-Za-z]*i\S*|--in-place\S*)(\s|$)", seg):
        return True
    redir = r"(?<![<>&0-9])>>?\|?\s*[\"\x27]?(?:[^\s;|&<>]*/)?(run|plan|analysis)\.md(?![A-Za-z0-9_.-])"
    if re.search(redir, seg) or (var_rx and re.search(r"(?<![<>&0-9])>>?\|?\s*[\"\x27]?" + var_rx, seg)):
        return True
    if re.search(word + r"(tee|rm|truncate)\s", seg):
        return True
    m = re.search(r"\bof=\S*", seg)
    if re.search(word + r"dd\s", seg) and m and (name_rx.search(m.group(0) + " ") or (var_rx and re.search(var_rx, m.group(0)))):
        return True
    m = re.search(word + r"(mv|cp)\s+([^\n]*)", seg)
    if m:
        words = m.group(3).split()
        args = [w for w in words if not w.startswith("-")]
        keep = any(re.fullmatch(r"-[A-Za-z]*n[A-Za-z]*", w) for w in words if w.startswith("-"))
        if args and not keep and (name_rx.search(" " + args[-1] + " ") or (var_rx and re.search(var_rx, args[-1]))):
            return True
    m = interp_rx.search(seg)
    if m:
        flag = r"\s-[A-Za-z]*c(\s|$)" if m.group(2).startswith("python") else r"\s(-[A-Za-z]*e|--eval)(\s|$)"
        return bool(re.search(flag, seg) or re.search(r"\s-(\s|$)", seg) or "<<" in seg)
    return False
for head, body in segments(text):
    name = named(head + "\n" + body)
    if name and writes(re.sub(r"\"[^\"]*\"|\x27[^\x27]*\x27", blank, head)):
        print(name)
        sys.exit(2)
'
}
run_file="$(run_file_write)"
case $? in
  0) ;;
  2) block "names $run_file in a command that can write it (sed -i, a redirect, tee, rm, truncate, dd, mv, cp, or an interpreter)" "Read it with rg, cat, or the Read tool, and change it with the Edit tool (AGENTS.md, Run ledger)." ;;
  *) block "cannot be checked for a write of run.md, plan.md, or analysis.md (python3 failed)" ;;
esac
# Only with-lock.sh, bench.sh, bench-pairs.sh, and sanitize.sh set the lock reuse values: a value
# set by hand runs a build beside the holder of the lock.
if [[ "$chained_data" == *DIRIGIBLE_BUILD_LOCK=* || "$chained_data" == *DIRIGIBLE_LOCKED_SCRIPT=* ]]; then
  block "sets a lock reuse value by hand (DIRIGIBLE_BUILD_LOCK or DIRIGIBLE_LOCKED_SCRIPT); run the command through scripts/with-lock.sh and wait for the lock"
fi

# A repo hook test runs in its lock-free form, scripts/with-lock.sh make test-hooks HOOK_TESTS='<names>'
# (header of scripts/with-lock.sh). That call takes no lock and also runs a test that the Makefile list
# does not hold. A bare run adds load to a push check (DLV-157/flake), also in the run-only mode of
# with-lock.sh, which takes no lock. A with-lock.sh call that takes the lock holds a slot of the 2-tree
# cap for 200 s or more (DLV-206/cost). Each segment of the chain (split on ; & | ( and a backtick) is
# read from its start, after the prefix words (NAME=value, time, env, probe.sh <folder>, with-lock.sh,
# and the like). It blocks a shell word (sh, bash, zsh, with a path) with flags other than -n and then
# a .test.sh path, a bare .test.sh path, and scripts/test-hooks.sh (any path), also after with-lock.sh.
# It blocks make test-hooks (with or without HOOK_TESTS) unless with-lock.sh is in the prefix and
# scripts/lock-words.sh, which with-lock.sh also sources, classes the call as free (lock_make_words) or
# release (release_call). The check runs those functions in a subshell on the words after the
# with-lock.sh word, with the BASE, MAKEFLAGS, and DIRIGIBLE_HOOKS_ALL words before it as their
# environment, and evals no command text. bash -n, make -n outside a with-lock.sh call, and a .test.sh
# path under .scratchpads/ pass. A segment of only NAME=value words runs no command, so it passes; a
# later segment that runs $NAME (after an optional shell word) of a name set to a .test.sh path or to
# test-hooks.sh blocks, across ;, &&, ||, and a new line.
# Misses: a path in a variable that the command does not assign, bash -c, a wrapper word that the
# prefix does not hold (nice, nohup, caffeinate), and a quoted prefix value with a space
# (MAKEFLAGS="-s BASE=x"), which hides BASE from the hook.
# The segments are read from the text with each separator inside a quoted string, and each data
# heredoc body, masked, so quoted data that names a test file after ( or ; is not a command. A
# heredoc body is data when no word before the marker is a shell or an interpreter (sh, bash, python3,
# node, ssh, make, source, and the like) and only a > file follows the marker; an unquoted body with
# $( or a backtick stays code. The text of a $(...) or a backtick pair inside double quotes stays code.
# A # at the start of a word, outside quotes, starts a comment that ends at the next new line: the mask
# blanks it, so a quote mark in a comment opens no string and hides no command on a later line.
# The text read is the one that keeps the body of an interpreter heredoc (it runs the body).
# By then chain_text has made each run of tabs one space, so the end line of a <<- heredoc may have
# leading spaces.
mask_quoted_data() {
  python3 -I -c '
import re
import sys

text = sys.stdin.read()
n = len(text)
out = []
SQ = chr(39)
FREE = re.compile(r"[;&|()`\n]")
CODE = re.compile(r"(?:(?:ba|z|da|k)?sh|python[0-9.]*|node|perl|ruby|php|osascript|eval|source|ssh|make|\.)")
TAIL = re.compile(r"\s*(>>?\s*[^\s;&|<>()`]+)?\s*")
HERE = re.compile(r"<<(-?)[ \t]*(\\?[A-Za-z0-9_.-]+|" + SQ + r"[A-Za-z0-9_.-]+" + SQ + r"|\"[A-Za-z0-9_.-]+\")")


def neutral(chunk):
    return FREE.sub(" ", chunk)


def single(i):
    j = text.find(SQ, i + 1)
    if j < 0:
        out.append(text[i:])
        return n
    out.append(SQ + neutral(text[i + 1 : j]) + SQ)
    return j + 1


def ansi(i):
    j = i + 2
    while j < n and text[j] != SQ:
        j += 2 if text[j] == "\\" else 1
    if j >= n:
        out.append(text[i:])
        return n
    out.append("$" + SQ + neutral(text[i + 2 : j]) + SQ)
    return j + 1


def double(start):
    mark = len(out)
    out.append("\"")
    i = start + 1
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append(neutral(text[i : i + 2]))
            i += 2
        elif c == "\"":
            out.append(c)
            return i + 1
        elif text.startswith("$(", i):
            out.append("$(")
            i = scan(i + 2, ")")
            if i < n:
                out.append(")")
            i += 1
        elif c == "`":
            out.append(c)
            i = scan(i + 1, "`")
            if i < n:
                out.append(c)
            i += 1
        else:
            out.append(neutral(c))
            i += 1
    del out[mark:]
    out.append(text[start:])
    return n


def bodies(i, pending):
    for marker, dash, quoted, data in pending:
        pos = i
        while True:
            end = text.find("\n", pos)
            end = n if end < 0 else end
            line = text[pos:end]
            if (line.lstrip(" ") if dash else line) == marker:
                break
            if end >= n:
                return i
            pos = end + 1
        after = min(end + 1, n)
        body = text[i:pos]
        if not (data and (quoted or ("$(" not in body and "`" not in body))):
            out.append(text[i:after])
        i = after
    return i


def word_start(i):
    if i == 0:
        return True
    if text[i - 1] not in " \t\n;&|()<>`":
        return False
    k = i - 1
    while k > 0 and text[k - 1] == "\\":
        k -= 1
    return (i - 1 - k) % 2 == 0


def scan(i, end):
    depth = 0
    seg = ""
    pending = []
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append(text[i : i + 2])
            seg += "x"
            i += 2
        elif c == SQ:
            i = single(i)
            seg += "x"
        elif c == "\"":
            i = double(i)
            seg += "x"
        elif text.startswith("$" + SQ, i):
            i = ansi(i)
            seg += "x"
        elif text.startswith("$(", i):
            out.append("$(")
            i = scan(i + 2, ")")
            if i < n:
                out.append(")")
            i += 1
            seg = ""
        elif text.startswith("<<", i) and not text.startswith("<<<", i) and HERE.match(text, i):
            m = HERE.match(text, i)
            raw = m.group(2)
            line_end = text.find("\n", m.end())
            rest = text[m.end() : n if line_end < 0 else line_end]
            code = any(CODE.fullmatch(w.rsplit("/", 1)[-1]) for w in seg.split())
            data = not code and bool(TAIL.fullmatch(rest))
            pending.append((raw.lstrip("\\").strip(SQ + "\""), bool(m.group(1)), raw[0] in "\\" + SQ + "\"", data))
            out.append(m.group(0))
            seg += m.group(0)
            i = m.end()
        elif c == "#" and word_start(i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append("#" + " " * (j - i - 1))
            i = j
        elif c == "\n":
            out.append(c)
            seg = ""
            i += 1
            if pending:
                i = bodies(i, pending)
                pending = []
        elif c == end and depth == 0:
            return i
        elif c in ";&|()`":
            if end == ")" and c == "(":
                depth += 1
            elif end == ")" and c == ")":
                depth -= 1
            out.append(c)
            seg = ""
            i += 1
        else:
            out.append(c)
            seg += c
            i += 1
    return n


scan(0, None)
sys.stdout.write("".join(out))
' || block "cannot be checked for a hook test run (python3 failed)"
}

# A background lock job needs a Bash timeout of 7200000 (AGENTS.md, Commands): the Bash tool stops a
# background call at 30 min by default and the result of a land, a push check, or a mutation pass is
# lost. A string test for a lock word opens the rule, so a Bash call with no lock word makes no read
# of the two keys. Each segment of the chain (the masked text of the hook test rule below) is read from
# its start, after the prefix words. A lock job has a with-lock.sh word in the prefix; or land.sh,
# mutation-pass.sh, swift-test.sh, test-shards.sh, bench.sh, bench-pairs.sh, sanitize.sh, loop.sh,
# make, or swift as the first word; or a shell word (sh, bash, zsh) with a file or a quoted command.
# make with one target that takes no lock (check-docs, check-fast, lint, format: AGENTS.md, Commands)
# and no other word but a redirection is no lock job. Misses: a
# wrapper word that the prefix does not hold (nice, nohup, caffeinate) and a path in a variable.
bg_gate='\.sh([^[:alnum:]]|$)|(^|[^[:alnum:]_.-])((ba|z|da)?sh|make|swift)([^[:alnum:]_.-]|$)'
if [[ "$chained" =~ $bg_gate ]]; then
  background="$(plutil -extract tool_input.run_in_background raw -o - "$input" 2>/dev/null)" || background=""
  limit="$(plutil -extract tool_input.timeout raw -o - "$input" 2>/dev/null)" || limit=""
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  if [[ "$background" == true ]] && ((10#$limit < 7200000)); then
    bg_pre="(\{ |! |if |then |do |else |while |export |[A-Za-z_][A-Za-z0-9_]*=$word |time |env |[^[:space:]]*probe\.sh $word |[^[:space:]]*with-lock\.sh )*"
    bg_shell="^([^[:space:]]*/)?(ba|z|da)?sh(([[:space:]]+-[A-Za-z]+)*)[[:space:]]+[^-<[:space:]]"
    bg_free_make="^([^[:space:]]*/)?make[[:space:]]+(check-docs|check-fast|lint|format)(([[:space:]]+[0-9]*|[[:space:]]*)>>?[[:space:]]*[^[:space:]>)}\"]*)*[[:space:])}\"]*$"
    bg_segments="$(mask_quoted_data <<< "$chained")" || exit 2
    for sep in ';' '&' '|' '(' '`'; do bg_segments="${bg_segments//"$sep"/$'\n'}"; done
    while IFS= read -r segment; do
      [[ "$segment" =~ ^[[:space:]]?($bg_pre)(.*)$ ]] || continue
      prefix="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
      read -ra words <<< "$rest"
      lock_job=""
      [[ "$prefix" == *with-lock.sh* ]] && lock_job=1
      case "${words[0]:+${words[0]##*/}}" in
        land.sh|mutation-pass.sh|swift-test.sh|test-shards.sh|bench.sh|bench-pairs.sh|sanitize.sh|loop.sh|swift) lock_job=1 ;;
        make) [[ "$rest" =~ $bg_free_make ]] || lock_job=1 ;;
      esac
      [[ "$rest" =~ $bg_shell ]] && lock_job=1
      if [[ -n "$lock_job" ]]; then
        block "runs a lock job in the background with a Bash timeout under 7200000" "A background Bash call stops at 30 min by default. The lead: set the Bash timeout to 7200000 (AGENTS.md, Commands). A subagent: run the step in the foreground for 10 min or less, or return to the lead."
      fi
    done <<< "$bg_segments"
  fi
fi

test_path="[\"']?([^[:space:]\"']*)\.test\.sh[\"']?([[:space:])}<>]|\$)"
hooks_path="[\"']?([^[:space:]\"']*/)?test-hooks\.sh[\"']?([[:space:])}<>]|\$)"
quote_re="^([^'\"]*)('[^']*'|\"[^\"]*\")(.*)\$"
# unmask_lock_quotes <text>: sets lock_text to the text with each quoted string as with-lock.sh gets it:
# an empty value after = stays empty, a string with a space or a $ becomes one non-empty word (Q), and
# any other string becomes its text ('make' gives make).
unmask_lock_quotes() {
  local text="$1" head quoted inner
  lock_text=""
  while [[ "$text" =~ $quote_re ]]; do
    head="${BASH_REMATCH[1]}" quoted="${BASH_REMATCH[2]}" text="${BASH_REMATCH[3]}"
    inner="${quoted:1:${#quoted}-2}"
    if [[ -z "$inner" && "$head" != *= ]] || [[ "$inner" =~ [[:space:]\$] ]]; then inner=Q; fi
    lock_text+="$head$inner"
  done
  lock_text+="$text"
}
make_hooks="^([^[:space:]]*/)?make(([[:space:]]+[^[:space:]]+)*)[[:space:]]+test-hooks([[:space:])}<>]|\$)"
test_pre="(\{ |! |if |then |do |else |while |[A-Za-z_][A-Za-z0-9_]*=$word |time |env |[^[:space:]]*probe\.sh $word |[^[:space:]]*with-lock\.sh )*"
lock_way="The one form is scripts/with-lock.sh make test-hooks HOOK_TESTS='<names>', which takes no lock (the header of scripts/with-lock.sh)."
if [[ "$chained" == *.test.sh* || "$chained" == *test-hooks* ]]; then
  test_segments="$(mask_quoted_data <<< "$chained")" || exit 2
  for sep in ';' '&' '|' '(' '`'; do test_segments="${test_segments//"$sep"/$'\n'}"; done
  assign_seg="^[[:space:]]*(\{ |! |if |then |do |else |while )*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=$word[[:space:]]*)+\$"
  assigned=""
  while IFS= read -r segment; do
    if [[ "$segment" =~ $assign_seg ]]; then
      rem="$segment"
      while [[ "$rem" =~ ([A-Za-z_][A-Za-z0-9_]*)=($word)(.*)$ ]]; do
        aname="${BASH_REMATCH[1]}" aval="${BASH_REMATCH[2]}" rem="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
        if [[ "$aval" =~ ^$test_path && "${BASH_REMATCH[1]}" != *.scratchpads/* ]]; then assigned+=" $aname:t"
        elif [[ "$aval" =~ ^$hooks_path ]]; then assigned+=" $aname:h"; fi
      done
      continue
    fi
    [[ "$segment" =~ ^[[:space:]]?($test_pre)(.*)$ ]] || continue
    prefix="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
    in_lock=""
    [[ "$prefix" == *with-lock.sh* ]] && in_lock=1
    if [[ "$rest" =~ ^([^[:space:]]*/)?(ba|z|da)?sh(([[:space:]]+-[A-Za-z]+)*)[[:space:]]+(.*)$ ]]; then
      [[ "${BASH_REMATCH[3]}" == *n* ]] && continue
      rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
    fi
    if [[ "$rest" =~ ^$test_path && "${BASH_REMATCH[1]}" != *.scratchpads/* ]]; then
      block "runs a repo hook test outside the key tree of scripts/test-hooks.sh" "$lock_way"
    fi
    if [[ "$rest" =~ ^$hooks_path ]]; then
      block "runs scripts/test-hooks.sh outside its lock-free form" "$lock_way"
    fi
    for aent in $assigned; do
      aname="${aent%:*}"
      use_re="^[\"']?[\$]([{]${aname}[}]|${aname})[\"']?([[:space:])}<>]|\$)"
      [[ "$rest" =~ $use_re ]] || continue
      [[ "$aent" == *:t ]] && block "runs a repo hook test outside the key tree of scripts/test-hooks.sh (through a variable)" "$lock_way"
      block "runs scripts/test-hooks.sh outside its lock-free form (through a variable)" "$lock_way"
    done
    if [[ -z "$in_lock" && "$rest" =~ $make_hooks ]]; then
      words=" ${BASH_REMATCH[2]} "
      [[ "$words" == *" -n "* || "$words" == *" --dry-run "* ]] && continue
      block "runs scripts/test-hooks.sh outside its lock-free form (make test-hooks)" "$lock_way"
    fi
    if [[ -n "$in_lock" && "$rest" =~ $make_hooks ]]; then
      lock_words_file="$(dirname "$0")/../../scripts/lock-words.sh"
      [[ -f "$lock_words_file" ]] ||
        block "cannot check a with-lock.sh make test-hooks call: scripts/lock-words.sh, the lock-free make words that scripts/with-lock.sh also reads, is missing" "$lock_way"
      unmask_lock_quotes "$segment"
      lock_text="${lock_text%%[<>)\}]*}"
      [[ "$lock_text" =~ ^(.*[[:space:]])[0-9]+$ ]] && lock_text="${BASH_REMATCH[1]}"
      read -ra lock_all <<< "$lock_text"
      lock_env=() lock_args=() lock_seen=""
      for lock_arg in "${lock_all[@]}"; do
        if [[ -n "$lock_seen" ]]; then lock_args+=("$lock_arg")
        elif [[ "${lock_arg##*/}" == with-lock.sh ]]; then lock_seen=1
        elif [[ "$lock_arg" =~ ^(BASE|MAKEFLAGS|DIRIGIBLE_HOOKS_ALL)= ]]; then lock_env+=("$lock_arg")
        fi
      done
      if [[ -z "$lock_seen" ]] || ! (
        unset BASE MAKEFLAGS DIRIGIBLE_HOOKS_ALL
        for lock_arg in ${lock_env[@]+"${lock_env[@]}"}; do export "$lock_arg"; done
        . "$lock_words_file"
        { lock_make_words "${lock_args[@]}" && [[ "$lock_goal" == test-hooks ]]; } || release_call "${lock_args[@]}"
      ); then
        block "runs scripts/test-hooks.sh outside its lock-free form (make test-hooks with a word that takes the lock)" "$lock_way"
      fi
    fi
  done <<< "$test_segments"
fi

# A subagent never runs a lock wait with no limit: after a second exit 75 it returns to the lead,
# which runs the wait in the background (AGENTS.md, Commands). The input of a subagent holds
# agent_id; the input of the lead does not. The wait has no limit with WITH_LOCK_MAX_WAIT set to
# zeros, with a with-lock.sh call of land.sh, make dmg, or make check-changed with BASE (a word,
# or a BASE= word before it), and with mutation-pass.sh (it wraps itself). Each segment of the
# chain is read from its start, after the prefix words (NAME=value, export, env, time, bash,
# with-lock.sh, sh -c or bash -c with its quote), so text in a quote of rg or echo is data. A
# bench and a flake loop pass: a slice runs a bench in the foreground.
agent=""
if [[ "$chained_data" == *WITH_LOCK_MAX_WAIT* || "$chained_data" == *with-lock.sh* || "$chained_data" == *mutation-pass.sh* ]]; then
  agent="$(plutil -extract agent_id raw -o - "$input" 2>/dev/null)" || agent=""
fi
if [[ -n "$agent" ]]; then
  agent_way="After a second exit 75, return to the lead: the lead runs the unlimited wait in the background."
  shell_c="([^[:space:]]*/)?(ba|z|da)?sh( +-[A-Za-z]+)* +-[A-Za-z]*c +[\"']?"
  agent_pre="(\{ |! |if |then |do |else |while |export |[A-Za-z_][A-Za-z0-9_]*=$word |time |env |$shell_c|bash |[^[:space:]]*with-lock\.sh )*"
  agent_start="(^|[;|&(]|"$'\n'") ?$agent_pre"
  if [[ "$chained_data" =~ ${agent_start}WITH_LOCK_MAX_WAIT=[\"\']?0+[\"\']?([^0-9A-Za-z_.\"\'-]|$) ]]; then
    block "sets WITH_LOCK_MAX_WAIT=0 in a subagent" "$agent_way"
  fi
  base_env=""
  while IFS= read -r segment; do
    [[ "$segment" =~ ^[[:space:]]?($agent_pre)(.*)$ ]] || continue
    prefix="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
    [[ "$prefix" =~ (^|[[:space:]])BASE=[^[:space:]] ]] && base_env=1
    read -ra words <<< "$rest"
    [[ ${#words[@]} -gt 0 ]] || continue
    [[ "${words[0]}" == BASE=?* ]] && base_env=1
    wait_goal="" wait_base="$base_env"
    case "${words[0]##*/}" in
      mutation-pass.sh) wait_goal=1 ;;
      land.sh) [[ "$prefix" == *with-lock.sh* ]] && wait_goal=1 ;;
      make)
        [[ "$prefix" == *with-lock.sh* ]] || continue
        for goal in "${words[@]:1}"; do
          goal="${goal//[\)\"\'\`]/}"
          case "$goal" in dmg) wait_goal=1 ;; check-changed) has_check=1 ;; BASE=?*) wait_base=1 ;; esac
        done
        [[ -n "${has_check:-}" && -n "$wait_base" ]] && wait_goal=1
        has_check=""
        ;;
    esac
    if [[ -n "$wait_goal" ]]; then
      block "runs a with-lock.sh call with no wait limit in a subagent (a land, a push check, make dmg, or a mutation pass)" "$agent_way"
    fi
  done < <(awk '{ gsub(/&&|\|\||[;&|(`]/, "\n"); print }' <<< "$chained_data")
fi

osascript_re='[Oo][Ss][Aa][Ss][Cc][Rr][Ii][Pp][Tt]'
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
if [[ "$COMMAND" =~ $osascript_re ]] && tr '\n\t' '  ' <<< "$COMMAND" | tr -s ' ' | tr '[:upper:]' '[:lower:]' |
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
if [[ "$COMMAND" =~ $osascript_re ]] && tr '\n\t' '  ' <<< "$COMMAND" | tr -s ' ' | tr '[:upper:]' '[:lower:]' | awk '
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
if matches '(^|[^[:alnum:]_.-])(killall( |$)|pkill( +-[^ ]+)* +-[a-zA-Z]*x)' "$NORMALIZED"; then
  block "quits each process with a name (killall, pkill -x), so it also quits the copy of the user, with its unsaved work" \
    "Find the PID with pgrep, record the PID of the process that the probe started, and quit only that PID (kill <pid>)."
fi

# Only .scratchpads/commit-msg.txt and - (stdin from a heredoc) pass as a message source. Any other
# path (absolute, relative, ~, $HOME, a run folder file) can name the file of another work tree, so a
# commit takes the message of another agent; git -C changes the directory first, so the relative path
# is per tree. A - whose stdin is a < file or a pipe is such a file too. commit-files.awk reads the
# text (the rules of the match are in its header), after mask_quoted_data has cut each data heredoc
# body (a commit message that quotes a rule is data) and masked the separators in quoted strings.
commit_files() {
  awk -v brief=0 -f "$(dirname "$0")/commit-files.awk"
}
if [[ "$NORMALIZED" == *"git commit"* ]]; then
  masked="$(mask_quoted_data <<< "$UNSPLIT")" || exit 2
  while IFS= read -r file; do
    if [[ "$file" == $'\001' ]]; then
      block "has more than one message file option, and git reads the last one" \
        "Pass one message file: write .scratchpads/commit-msg.txt in the work tree that commits and run git commit -F .scratchpads/commit-msg.txt (or git commit -F - with a heredoc)."
    fi
    if [[ "$file" == $'\002' ]]; then
      block "reads the commit message from stdin with a < file, a pipe, or no heredoc, and the file can belong to another work tree" \
        "Write .scratchpads/commit-msg.txt in the work tree that commits and run git commit -F .scratchpads/commit-msg.txt, or pass the text in a heredoc on the commit: git commit -F - <<'EOF'."
    fi
    [[ "$file" == "'" || "$file" == '"' ]] && continue
    file="${file#[\'\"]}"
    file="${file%[\'\"]}"
    if [[ "$file" != .scratchpads/commit-msg.txt && "$file" != - ]]; then
      block "reads a commit message file other than .scratchpads/commit-msg.txt, which can be the file of another work tree" \
        "Write .scratchpads/commit-msg.txt in the work tree that commits and pass that relative path (git commit -F .scratchpads/commit-msg.txt), or pass the message on stdin (git commit -F - with a heredoc)."
    fi
  done < <(commit_files <<< "$masked")
fi

# tccutil_user_id <text>: 0 when a line with tccutil reset still names the app ID of the user after
# each verify copy ID is cut (one pass, as sed s///g).
tccutil_user_id() {
  local line rest out copy_re='com\.delineas\.dirigible\.verify-[0-9a-f]+' tccutil_re='(^|[^[:alnum:]_.-])tccutil +reset( |$)'
  while IFS= read -r line; do
    [[ "$line" =~ $tccutil_re ]] || continue
    out="" rest="$line"
    while [[ "$rest" =~ $copy_re ]]; do
      out+="${rest%%"${BASH_REMATCH[0]}"*}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    [[ "$out$rest" == *com.delineas.dirigible* ]] && return 0
  done <<< "$1"
  return 1
}
# A privacy reset of com.delineas.dirigible removes the grants of each build of the user (VER-084:
# one reset removed 11 records). Only the ID of the verify copy, com.delineas.dirigible.verify-<hash>,
# may be reset.
if tccutil_user_id "$NORMALIZED"; then
  block "resets the privacy grants of the app ID of the user (com.delineas.dirigible), and so of each build of the user" \
    "Reset only the copy of the check: scripts/verify-copy.sh stop runs tccutil reset All with the copy ID, and scripts/verify-copy.sh id prints it."
fi

# A reset with no bundle ID removes the grants of every app (Zoom and Teams too), and a bundle ID
# from a variable or a substitution can name the ID of the user. Both block.
if [[ "$NORMALIZED" == *tccutil* ]]; then
  reset_re='(^|[^[:alnum:]_.-])tccutil +reset( [^;&|]*)?($|[;&|])'
  while IFS= read -r line; do
    while [[ "$line" =~ $reset_re ]]; do
      reset="${BASH_REMATCH[0]}"
      # The leading "a" stands for the text already read, so ^ and the character before tccutil
      # match as in grep -o.
      line="a${line#*"$reset"}"
      rest="${reset#*reset}"
      read -ra words <<< "${rest%[;&|]}"
      if [[ ${#words[@]} -lt 2 || "${words[1]}" == *[\$\`]* ]]; then
        block "resets the privacy grants of every app (tccutil reset with no bundle ID, or with a bundle ID that holds \$ or a backtick)" \
          "Reset only the copy of the check: scripts/verify-copy.sh stop runs tccutil reset All with the copy ID, and scripts/verify-copy.sh id prints it."
      fi
    done
  done < <(sed -E 's/[0-9]*>&[0-9-]*//g' <<< "$NORMALIZED")
fi

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if matches "$pattern" "$NORMALIZED"; then
    block "matches '$pattern'"
  fi
done

# A pull request merges only through scripts/land.sh. The hook sees only the Bash command text, so
# the gh call inside land.sh passes. The api path blocks with a PUT only (the GET is a read); a query
# or an alias can hold ; or |, so those two forms read the text before the chain split. The route
# (a command that starts with scripts/land.sh or git commit, after NAME=value, env, and with-lock.sh
# words) may hold merge words in its title or message, so the rule skips it, unless it has a
# substitution. A ; or | inside its quotes splits it, and the rest blocks.
route='^ *(\{ )?([A-Za-z_][A-Za-z0-9_]*=[^ ]+ |env |[^ ]*with-lock\.sh )*(\./)?(scripts/land\.sh|git commit)( |$)'
is_route() { [[ "$1" =~ $route && "$1" != *'$('* && "$1" != *'`'* && "$1" != *'<('* ]]; }
merge_text=""
while IFS= read -r line; do is_route "$line" || merge_text+="$line"$'\n'; done <<< "$NORMALIZED"
flat="${UNSPLIT//$'\n'/ }"
if [[ "$NORMALIZED" != *$'\n'* ]] && is_route "$UNSPLIT"; then flat=""; fi
# Drop the repo flags of gh (-R <repo>, --repo <repo>) before or after pr, api, or alias, so
# `gh -R o/r pr merge` reads as `gh pr merge`. One pass drops the flags of one position.
drop_repo_flags() {
  local text="$1" next
  [[ "$text" == *gh* ]] || { printf '%s\n' "$text"; return; }
  while next="$(sed -E 's/(^|[^[:alnum:]_-])(gh( +(pr|api|alias))?)( +(-R[ =]?|--repo[ =])[^ ]+)+/\1\2/g' <<< "$text")"; [[ "$next" != "$text" ]]; do text="$next"; done
  printf '%s\n' "$text"
}
merge_text="$(drop_repo_flags "$merge_text")"
flat="$(drop_repo_flags "$flat")"
# merge_put <text>: 0 when a line is a gh api call to a pulls/<n>/merge path with a PUT (any case).
merge_put() {
  local line api_re='gh api .*pulls/[^/ ]+/merge' put_re='(-[Xx] ?[Pp][Uu][Tt]|--[Mm][Ee][Tt][Hh][Oo][Dd][ =][Pp][Uu][Tt])'
  while IFS= read -r line; do
    [[ "$line" =~ $api_re && "$line" =~ $put_re ]] && return 0
  done <<< "$1"
  return 1
}
if matches 'gh pr merge( |$)' "$merge_text" ||
  merge_put "$merge_text" ||
  matches 'gh api .*(mergePullRequest|enablePullRequestAutoMerge)' "$flat" ||
  matches 'gh alias set .*(pr merge|pulls/[^/ ]+/merge|mergePullRequest|enablePullRequestAutoMerge)' "$flat"; then
  block_merge
fi

# A release tag comes only from scripts/tag-release.sh, which checks the version order against the
# tags of origin and removes its own stale local tag. A git tag command at a command start with an
# argument blocks, unless it lists or verifies the tags (tag_reads) and makes, deletes, or moves
# none. A push of --tags, refs/tags/, or a v<digit> name blocks.
tag_way="Tag a release with scripts/tag-release.sh <version> <commit> <message>: only the tags of origin decide a refusal, and the script removes its own stale local tag."
# tag_reads <arguments of git tag>: 0 when they only list or verify tags. -l, --list, --points-at,
# --contains, --merged, -n, and -v list or verify with a name too. --sort, --format, and --column
# make a tag when a name follows and no list flag does, so they read only with no name.
tag_reads() {
  local rest="$1" word
  local change_re='(^| )(-[a-zA-Z]*[adsfmF][a-zA-Z]*|--delete|--annotate|--sign|--force|--message|--file)( |=|$)'
  local list_re='(^| )(-l[n0-9]*|--list|--points-at|--contains|--no-contains|--merged|--no-merged|-n[0-9]*|-v|--verify)( |=|$)'
  local format_re='(^| )--(sort|format|column)( |=|$)'
  [[ "$rest" =~ $change_re ]] && return 1
  [[ "$rest" =~ $list_re ]] && return 0
  rest="$(sed -E "s/--(sort|format)=(\"[^\"]*\"|'[^']*')//g" <<< "$rest")"
  for word in $rest; do [[ "$word" == -* ]] || return 1; done
  [[ "$rest" =~ $format_re ]]
}
tag_push_re="(^|[ (])git push( .*)? (--tags|[^ ]*refs/tags/|[\"']?v[0-9])"
while IFS= read -r line; do
  if [[ "$line" =~ (^|[ \(])git\ tag(\ |$)(.*) ]]; then
    rest="${BASH_REMATCH[3]}"
    if [[ -n "${rest// /}" ]] && ! tag_reads "$rest"; then
      block "makes, deletes, or moves a tag by hand" "$tag_way"
    fi
  fi
  if [[ "$line" =~ $tag_push_re ]]; then
    block "pushes a tag by hand" "$tag_way"
  fi
done <<< "$NORMALIZED"

exit 0
