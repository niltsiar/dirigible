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
hooks_rest="$(sed -E 's/[Cc][Oo][Rr][Ee]\.[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]/core.hookspath/g' <<< "$joined" |
  tr -s '\t ' '  ' | awk '{ gsub(/&&|\|\||[;&|()`]/, "\n"); print }' |
  grep -vE '^ *git( +-C +[^ ]+)* +config( +get)?( +--(local|worktree|get|get-all|show-origin))* +core\.hookspath( +2>/dev/null)? *$' |
  grep -vE '^ *git( +-C +[^ ]+)* +config( +--local)? +core\.hookspath +\.githooks *$')"
if grep -q 'core\.hookspath' <<< "$hooks_rest"; then
  block "changes core.hooksPath"
fi

# The joined text with one space for each run of tabs and spaces, the git global options removed,
# and the new lines kept, so `git -C <path>  commit` reads as `git commit` in the two chain rules.
chain_text() {
  tr -s '\t ' '  ' <<< "${1//\\$'\n'/ }" | sed -E "s/git( +-[Cc] +('[^']*'|\"[^\"]*\"|[^ ]+))+/git/g"
}
chained="$(chain_text "$SINK_CUT")"
chained_data="$(chain_text "$DATA_CUT")"

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
if grep -qE 'dirigible-check-stamp|check-stamp\.sh write' <<< "$NORMALIZED"; then
  block "names the pass stamp or writes it (only make check-changed writes it; read it with scripts/check-stamp.sh read origin/main)"
fi
# Only a passing make test-slow or test-slow-push writes the slow-run date that
# scripts/check-changed.sh reads, so a direct write cannot skip the daily slow run. A command that
# names the date file is blocked too.
if grep -qE 'dirigible-slow-date' <<< "$NORMALIZED"; then
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
  while IFS= read -r line; do
    line="${line//$sep/&}"
    line="${line//$bar/|}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] && segs+=("$line")
  done < <(sed -E "s/\\\\\\|/ /g; s/&>/${sep}>/g; s/>&/>${sep}/g" <<< "$MASKED" | awk '{ gsub(/&&|\|\||;|\||&/, "\n"); print }')
  for line in "${segs[@]}"; do
    named=0
    while IFS= read -r token; do
      token="${token#[\"\']}"
      [[ -n "$token" && "$token" =~ ^(\.\./|/) && "$token" != *.git* ]] || named=1
    done < <(grep -oE "[^[:space:]]*$name([^A-Za-z0-9_.-]|\$)" <<< "$line")
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
        sort) grep -qE '(^|[[:space:]])-[a-zA-Z]*o' <<< "$line" && return 1 ;;
        sed) grep -qE '(^|[[:space:]])-[a-zA-Z]*i' <<< "$line" && return 1
          grep -qE '(^|[[:space:]])-[a-zA-Z]*n' <<< "$line" || return 1 ;;
        git) [[ "$second" == grep ]] || return 1 ;;
        *) return 1 ;;
      esac
      grep -qE "$redirect" <<< "$line" && return 1
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
if grep -qE 'DIRIGIBLE_(BUILD_LOCK|LOCKED_SCRIPT)=' <<< "$chained_data"; then
  block "sets a lock reuse value by hand (DIRIGIBLE_BUILD_LOCK or DIRIGIBLE_LOCKED_SCRIPT); run the command through scripts/with-lock.sh and wait for the lock"
fi

# A repo .test.sh runs through scripts/with-lock.sh (AGENTS.md, Commands): a bare run takes no lock
# and adds load to a push check (DLV-157/flake). Each segment of the chain (split on ; & | ( and a
# backtick) is read from its start, after the prefix words (NAME=value, time, env, probe.sh <folder>,
# and the like). It blocks a shell word (sh, bash, zsh, with a path) with flags other than -n and then
# a .test.sh path, and a bare .test.sh path. A with-lock.sh word in the prefix, bash -n, and a path
# under .scratchpads/ pass. Misses: a path in a variable, bash -c, and a wrapper word that the prefix
# does not hold (nice, nohup, caffeinate).
test_path="[\"']?([^[:space:]\"']*)\.test\.sh[\"']?([[:space:])}<>]|\$)"
test_pre="(\{ |! |if |then |do |else |while |[A-Za-z_][A-Za-z0-9_]*=$word |time |env |[^[:space:]]*probe\.sh $word |[^[:space:]]*with-lock\.sh )*"
test_segments="$chained_data"
for sep in ';' '&' '|' '(' '`'; do test_segments="${test_segments//"$sep"/$'\n'}"; done
while IFS= read -r segment; do
  [[ "$segment" =~ ^[[:space:]]?($test_pre)(.*)$ ]] || continue
  prefix="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  [[ "$prefix" == *with-lock.sh* ]] && continue
  if [[ "$rest" =~ ^([^[:space:]]*/)?(ba|z|da)?sh(([[:space:]]+-[A-Za-z]+)*)[[:space:]]+(.*)$ ]]; then
    [[ "${BASH_REMATCH[3]}" == *n* ]] && continue
    rest="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
  fi
  if [[ "$rest" =~ ^$test_path && "${BASH_REMATCH[1]}" != *.scratchpads/* ]]; then
    block "runs a repo .test.sh with no lock" "Run it through the lock: scripts/with-lock.sh make test-hooks HOOK_TESTS='<names>' (AGENTS.md, Commands). A bare run adds load to the push checks of the other worktrees."
  fi
done <<< "$test_segments"

# A subagent never runs a lock wait with no limit: after a second exit 75 it returns to the lead,
# which runs the wait in the background (AGENTS.md, Commands). The input of a subagent holds
# agent_id; the input of the lead does not. The wait has no limit with WITH_LOCK_MAX_WAIT set to
# zeros, with a with-lock.sh call of land.sh, make dmg, or make check-changed with BASE (a word,
# or a BASE= word before it), and with mutation-pass.sh (it wraps itself). Each segment of the
# chain is read from its start, after the prefix words (NAME=value, export, env, time, bash,
# with-lock.sh, sh -c or bash -c with its quote), so text in a quote of rg or echo is data. A
# bench and a flake loop pass: a slice runs a bench in the foreground.
agent="$(plutil -extract agent_id raw -o - "$input" 2>/dev/null)" || agent=""
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
# the directory first, so the relative path is per tree. Only the first -F or --file after each
# git commit of a line counts, up to the first ; & | , or sentence end outside quotes (agent-guard.sh
# has the same function).
commit_files() {
  awk '{
    s = $0
    while ((i = index(s, "git commit")) > 0) {
      s = substr(s, i + 10)
      chunk = s
      if ((j = index(s, "git commit")) > 0) chunk = substr(s, 1, j - 1)
      q = ""
      for (k = 1; k <= length(chunk); k++) {
        c = substr(chunk, k, 1)
        if (q != "") { if (c == q) q = "" }
        else if (c == "\"" || c == "\047") q = c
        else if (c ~ /[;&|,]/ || (c == "." && substr(chunk, k + 1, 1) == " ")) { chunk = substr(chunk, 1, k - 1); break }
      }
      if (match(chunk, /(^| )(-F ?|--file[= ])[^ ]+/)) {
        t = substr(chunk, RSTART, RLENGTH)
        sub(/^ ?(-F ?|--file[= ])/, "", t)
        print t
      }
    }
  }'
}
while IFS= read -r file; do
  file="${file#[\'\"]}"
  file="${file%[\'\"]}"
  if [[ "$file" == *commit-msg.txt || "$file" == *.scratchpads/* ]] && [[ "$file" != .scratchpads/commit-msg.txt ]]; then
    block "reads a commit message file that can be the file of another work tree; write .scratchpads/commit-msg.txt in the work tree that commits and pass that relative path"
  fi
done < <(commit_files <<< "$NORMALIZED")

# A privacy reset of com.delineas.dirigible removes the grants of each build of the user (VER-084:
# one reset removed 11 records). Only the ID of the verify copy, com.delineas.dirigible.verify-<hash>,
# may be reset.
if grep -E '(^|[^[:alnum:]_.-])tccutil +reset( |$)' <<< "$NORMALIZED" |
  sed -E 's/com\.delineas\.dirigible\.verify-[0-9a-f]+//g' | grep -q 'com\.delineas\.dirigible'; then
  block "resets the privacy grants of the app ID of the user (com.delineas.dirigible), and so of each build of the user" \
    "Reset only the copy of the check: scripts/verify-copy.sh stop runs tccutil reset All with the copy ID, and scripts/verify-copy.sh id prints it."
fi

# A reset with no bundle ID removes the grants of every app (Zoom and Teams too), and a bundle ID
# from a variable or a substitution can name the ID of the user. Both block.
while IFS= read -r reset; do
  rest="${reset#*reset}"
  read -ra words <<< "${rest%[;&|]}"
  if [[ ${#words[@]} -lt 2 || "${words[1]}" == *[\$\`]* ]]; then
    block "resets the privacy grants of every app (tccutil reset with no bundle ID, or with a bundle ID that holds \$ or a backtick)" \
      "Reset only the copy of the check: scripts/verify-copy.sh stop runs tccutil reset All with the copy ID, and scripts/verify-copy.sh id prints it."
  fi
done < <(sed -E 's/[0-9]*>&[0-9-]*//g' <<< "$NORMALIZED" |
  grep -oE '(^|[^[:alnum:]_.-])tccutil +reset( [^;&|]*)?($|[;&|])')

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if grep -qE -- "$pattern" <<< "$NORMALIZED"; then
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
if [[ "$(wc -l <<< "$NORMALIZED")" -eq 1 ]] && is_route "$UNSPLIT"; then flat=""; fi
# Drop the repo flags of gh (-R <repo>, --repo <repo>) before or after pr, api, or alias, so
# `gh -R o/r pr merge` reads as `gh pr merge`. One pass drops the flags of one position.
drop_repo_flags() {
  local text="$1" next
  while next="$(sed -E 's/(^|[^[:alnum:]_-])(gh( +(pr|api|alias))?)( +(-R[ =]?|--repo[ =])[^ ]+)+/\1\2/g' <<< "$text")"; [[ "$next" != "$text" ]]; do text="$next"; done
  printf '%s\n' "$text"
}
merge_text="$(drop_repo_flags "$merge_text")"
flat="$(drop_repo_flags "$flat")"
if grep -qE 'gh pr merge( |$)' <<< "$merge_text" ||
  grep -E 'gh api .*pulls/[^/ ]+/merge' <<< "$merge_text" | grep -qiE -- '(-X ?PUT|--method[ =]PUT)' ||
  grep -qE 'gh api .*(mergePullRequest|enablePullRequestAutoMerge)' <<< "$flat" ||
  grep -qE 'gh alias set .*(pr merge|pulls/[^/ ]+/merge|mergePullRequest|enablePullRequestAutoMerge)' <<< "$flat"; then
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
  ! grep -qE '(^| )(-[a-zA-Z]*[adsfmF][a-zA-Z]*|--delete|--annotate|--sign|--force|--message|--file)( |=|$)' <<< "$rest" || return 1
  ! grep -qE '(^| )(-l[n0-9]*|--list|--points-at|--contains|--no-contains|--merged|--no-merged|-n[0-9]*|-v|--verify)( |=|$)' <<< "$rest" || return 0
  rest="$(sed -E "s/--(sort|format)=(\"[^\"]*\"|'[^']*')//g" <<< "$rest")"
  for word in $rest; do [[ "$word" == -* ]] || return 1; done
  grep -qE '(^| )--(sort|format|column)( |=|$)' <<< "$rest"
}
while IFS= read -r line; do
  if [[ "$line" =~ (^|[ \(])git\ tag(\ |$)(.*) ]]; then
    rest="${BASH_REMATCH[3]}"
    if [[ -n "${rest// /}" ]] && ! tag_reads "$rest"; then
      block "makes, deletes, or moves a tag by hand" "$tag_way"
    fi
  fi
  if grep -qE "(^|[ (])git push( .*)? (--tags|[^ ]*refs/tags/|[\"']?v[0-9])" <<< "$line"; then
    block "pushes a tag by hand" "$tag_way"
  fi
done <<< "$NORMALIZED"

exit 0
