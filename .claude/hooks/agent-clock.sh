#!/bin/bash
# PreToolUse hook for each tool: refuse the tool calls of a subagent after 90 active minutes
# (AGENT_CLOCK_MIN sets the limit for tests). A long agent costs most of its tokens in replies with a
# large context, and the lead cannot see its age. Exit 2 blocks the call and shows the message to the
# agent, which writes its handoff in run.md and calls SubagentHandback.
# Active minutes are the sum of the gaps between the `timestamp` values of the subagent transcript
# (<session transcript without .jsonl>/subagents/agent-<agent_id>.jsonl), each gap at most 15 min,
# so an idle night counts 15 min. The sum is a substring scan of each line, not a JSON parse of each
# line. The hook exits 0 in bash, before Python starts, when the input has no "agent_id": the lead
# never gets a refusal.
# Past the limit these calls pass, so the agent can write its handoff and hand back:
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
import re
import sys
from datetime import datetime

GAP_MAX = 15 * 60
PASS_TOOLS = {"Read", "ToolSearch", "TaskStop", "SubagentHandback"}
GIT_PASS = {"status", "diff", "log", "add", "commit"}
LOG_DECISION = ".claude/skills/deliver/scripts/log-decision.sh"


def active_minutes(path):
    total, prev = 0.0, None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            start = line.find("\"timestamp\":\"")
            if start < 0:
                continue
            start += len("\"timestamp\":\"")
            try:
                at = datetime.fromisoformat(line[start:line.index("\"", start)].replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            if prev is not None:
                total += min(max(at - prev, 0.0), GAP_MAX)
            prev = at
    return total / 60


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
        minutes = active_minutes(path) if path else 0.0
    except OSError:
        return
    if minutes <= limit:
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
    print(
        f"BLOCKED by .claude/hooks/agent-clock.sh: this agent has run {minutes:.0f} active minutes, over the limit of {limit:g} "
        "(docs/workflow/model-routing.md). Write the handoff in run.md (next step, each check result from its log), "
        "commit with git add <paths> && git commit -F .scratchpads/commit-msg.txt, or leave the working tree as it is, then call SubagentHandback.",
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
