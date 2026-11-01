#!/bin/bash
# PreToolUse hook for each tool: refuse the tool calls of a subagent after 90 active minutes
# (AGENT_CLOCK_MIN sets the limit for tests), and after a commit at 60 active minutes or more. A long
# agent costs most of its tokens in replies with a large context, and the lead cannot see its age.
# Exit 2 blocks the call and shows the message to the agent, which writes its handoff in run.md and
# calls SubagentHandback.
# Active minutes are the sum of the gaps between the `timestamp` values of the subagent transcript
# (<session transcript without .jsonl>/subagents/agent-<agent_id>.jsonl), each gap at most 15 min,
# so an idle night counts 15 min. The sum is a substring scan of each line, not a JSON parse of each
# line. The hook exits 0 in bash, before Python starts, when the input has no "agent_id": the lead
# never gets a refusal.
# The commit trigger: a Bash call with a git commit segment at 60 or more active minutes, after
# which the HEAD history of its work tree (the last `cd <path>` segment before the commit, else the
# `git -C <path>` of the segment, else the cwd of the entry) holds a commit whose committer time is
# from 2 s before the call to 2 s after its result, and whose author time is within 2 s of that
# (`--amend`: the committer time only). One `git log -n 20` call reads the history, and a failed
# call gives no trigger. The output text and the is_error flag of the command do not decide. A
# coordinator message (a user entry that starts with `The coordinator sent a message`) after the
# commit clears the trigger. The scan is the same pass as the sum: before 60 active minutes a line
# gets no more than its timestamp, and it skips api-request-blob lines.
# Past the limit, or after the trigger, these calls pass, so the agent can write its handoff and
# hand back:
#   - the tools Read, ToolSearch, TaskStop, and SubagentHandback;
#   - Edit and Write when `file_path` has a `/.scratchpads/` part (run.md, commit-msg.txt), so an
#     agent past the limit writes only its handoff files;
#   - Monitor and TaskOutput while the transcript has a running background task (background-tasks.py,
#     the parser that handback-guard.sh also uses), so a check that started before the limit can
#     finish and be read;
#   - a Bash command in which each segment is `cd <path>`, only NAME=value words, git status, diff,
#     log, add, or commit (`git -C <path>` and `git -c <key=value>` dropped, as git-guardrails.sh does),
#     or log-decision.sh by a path that ends in .claude/skills/deliver/scripts/log-decision.sh.
#     Segments split on &&, ||, ;, |, and new lines; each leading NAME=value word of a segment is
#     dropped. A command with $(, a backtick, <(, >(, or a lone & is refused.
# The hook passes every input that it cannot read: input that is not JSON, no transcript file, or
# no timestamp.
here="$(cd "$(dirname "$0")" && pwd)"
input="$(cat)"
[[ "$input" == *'"agent_id"'* ]] || exit 0
python3 -I -c '
import importlib.util
import json
import os
import re
import subprocess
import sys
from datetime import datetime

GAP_MAX = 15 * 60
COMMIT_MIN = 60
WINDOW = 2.0
BLOB = "{\"type\":\"api-request-blob\""
COORDINATOR = "The coordinator sent a message"
PASS_TOOLS = {"Read", "ToolSearch", "TaskStop", "SubagentHandback"}
GIT_PASS = {"status", "diff", "log", "add", "commit"}
LOG_DECISION = ".claude/skills/deliver/scripts/log-decision.sh"


def line_time(line):
    start = line.find("\"timestamp\":\"")
    if start < 0:
        return None
    start += len("\"timestamp\":\"")
    try:
        return datetime.fromisoformat(line[start:line.index("\"", start)].replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def commit_segment(command, cwd):
    """The work tree and the amend flag of the first git commit segment of a command, else None."""
    tree = None
    for segment in re.split(r"&&|\|\||;|\||\n", command):
        words = segment.split()
        while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=\S*", words[0]):
            words.pop(0)
        if not words:
            continue
        if words[0] == "cd":
            if len(words) == 2:
                tree = words[1]
            continue
        if words[0] != "git":
            continue
        rest, option_tree = words[1:], None
        while len(rest) >= 2 and rest[0] in ("-C", "-c"):
            if rest[0] == "-C":
                option_tree = rest[1]
            rest = rest[2:]
        if rest and rest[0] == "commit":
            where = tree or option_tree or cwd
            if not isinstance(where, str) or not where:
                return None
            return os.path.join(cwd or "", os.path.expanduser(where)), "--amend" in rest
    return None


def bash_calls(line):
    try:
        entry = json.loads(line)
        cwd = entry.get("cwd")
        return [
            (block["id"], block["input"]["command"], cwd)
            for block in entry["message"]["content"]
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash"
            and isinstance(block.get("input", {}).get("command"), str)
        ]
    except (ValueError, KeyError, TypeError, AttributeError):
        return []


def coordinator_entry(line):
    try:
        content = json.loads(line)["message"]["content"]
    except (ValueError, KeyError, TypeError):
        return False
    if isinstance(content, list):
        content = "".join(b.get("text", "") for b in content if isinstance(b, dict))
    return isinstance(content, str) and content.startswith(COORDINATOR)


def scan(path):
    """The active minutes of the transcript, and the Bash commit calls at COMMIT_MIN active minutes
    or more after the last coordinator message, each (time of the call, time of its result, work
    tree, amend flag). One pass: a line before COMMIT_MIN gets no more than its timestamp."""
    total, prev = 0.0, None
    pending, done = {}, []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            at = line_time(line)
            if at is None:
                continue
            if prev is not None:
                total += min(max(at - prev, 0.0), GAP_MAX)
            prev = at
            if total < COMMIT_MIN * 60 or line.startswith(BLOB):
                continue
            if COORDINATOR in line and "\"type\":\"user\"" in line:
                if coordinator_entry(line):
                    pending.clear()
                    done.clear()
            elif pending and "\"tool_use_id\":\"" in line:
                for key in [k for k in pending if "\"tool_use_id\":\"" + k + "\"" in line]:
                    start, tree, amend = pending.pop(key)
                    done.append((start, at, tree, amend))
            elif "\"name\":\"Bash\"" in line and "commit" in line and "\"type\":\"assistant\"" in line:
                for key, command, cwd in bash_calls(line):
                    found = commit_segment(command, cwd)
                    if found:
                        pending[key] = (at, found[0], found[1])
    return total / 60, done


def committed_in_window(calls):
    """True when the HEAD history of the work tree of a call holds a commit that the call made."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE")}
    history = {}
    for start, end, tree, amend in calls:
        if tree not in history:
            try:
                out = subprocess.run(
                    ["git", "-C", tree, "log", "-n", "20", "--format=%ct %at", "HEAD"],
                    capture_output=True, text=True, timeout=10, env=env,
                )
                history[tree] = out.stdout.splitlines() if out.returncode == 0 else []
            except (OSError, subprocess.SubprocessError):
                history[tree] = []
        for row in history[tree]:
            try:
                committed, authored = (float(w) for w in row.split())
            except ValueError:
                continue
            if start - WINDOW <= committed <= end + WINDOW and (amend or abs(committed - authored) <= WINDOW):
                return True
    return False


def segment_passes(segment):
    words = segment.split()
    while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=\S*", words[0]):
        words.pop(0)
    if not words:
        return True
    if words[0] == "cd":
        return len(words) <= 2
    if words[0].endswith(LOG_DECISION):
        return True
    if words[0] == "git":
        rest = words[1:]
        while len(rest) >= 2 and rest[0] in ("-C", "-c"):
            rest = rest[2:]
        return bool(rest) and rest[0] in GIT_PASS
    return False


def command_passes(command):
    if "$(" in command or "`" in command or "<(" in command or ">(" in command:
        return False
    joined = re.sub(r"[0-9]*>&[0-9-]*|&>>?|>&", "", command.replace("&&", ""))
    if "&" in joined:
        return False
    return all(segment_passes(s) for s in re.split(r"&&|\|\||;|\||\n", command) if s.strip())


def main():
    try:
        hook = json.loads(sys.argv[1])
    except ValueError:
        return
    if not isinstance(hook, dict) or not hook.get("agent_id"):
        return
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("background_tasks", sys.argv[2])
    tasks = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tasks)
    path = tasks.subagent_path(hook)
    try:
        limit = float(sys.argv[3])
    except ValueError:
        limit = 90.0
    try:
        minutes, calls = scan(path) if path else (0.0, [])
        over = minutes > limit
        if not over and (minutes < COMMIT_MIN or not committed_in_window(calls)):
            return
    except OSError:
        return
    tool = hook.get("tool_name")
    if tool in PASS_TOOLS:
        return
    if tool in ("Edit", "Write"):
        tool_input = hook.get("tool_input")
        file_path = tool_input.get("file_path") if isinstance(tool_input, dict) else None
        if isinstance(file_path, str) and "/.scratchpads/" in file_path:
            return
    if tool in ("Monitor", "TaskOutput") and tasks.running_tasks(path):
        return
    if tool == "Bash":
        tool_input = hook.get("tool_input")
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        if isinstance(command, str) and command_passes(command):
            return
    if over:
        reason = f"this agent has run {minutes:.0f} active minutes, over the limit of {limit:g} "
    else:
        reason = f"this agent made a commit after {COMMIT_MIN} active minutes (commit hand-off, {minutes:.0f} active minutes now) "
    print(
        f"BLOCKED by .claude/hooks/agent-clock.sh: {reason}"
        "(docs/workflow/model-routing.md). Write the handoff in run.md (next step, each check result from its log), "
        "Log each pending decisions.tsv row with .claude/skills/deliver/scripts/log-decision.sh <run folder> --from <file in .scratchpads/> "
        "(write that file under .scratchpads/ with the Write tool). "
        "Then commit with git add <paths> && git commit -F .scratchpads/commit-msg.txt, or leave the working tree as it is. "
        "Then call SubagentHandback.",
        file=sys.stderr,
    )
    sys.exit(2)


try:
    main()
except Exception:
    sys.exit(0)
' "$input" "$here/background-tasks.py" "${AGENT_CLOCK_MIN:-90}"
[[ $? -eq 2 ]] && exit 2
exit 0
