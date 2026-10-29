#!/usr/bin/env python3
# Print the background tasks that a subagent still runs, one `<id> <kind>` line each. Read by
# handback-guard.sh and agent-clock.sh, so both hooks use one start and end rule.
# Usage: python3 -I background-tasks.py <subagent transcript>
# Claude Code writes no task list into a hook input, so the hooks read the transcript of the agent:
# <session transcript without .jsonl>/subagents/agent-<agent id>.jsonl (see subagent_path).
# A task starts with the result of a tool call whose text begins with one of these (Claude Code
# 2.1.302):
#   Command running in background with ID: <id>            (Bash with run_in_background)
#   Monitor started (task <id>, expires in <n>m            (Monitor)
#   Async agent launched successfully. ... agentId: <id>   (Agent, async)
# It ends with a <task-notification> that has a <status> (completed, failed, killed), a Monitor
# expiry event `[Monitor expired after`, the `[Subagent hand-back]` message of a child agent, a
# TaskStop call for its id, or, for a Monitor, a start older than its `expires in <n>m`. A Monitor
# event has no <status> and does not end the task. A changed text of a newer Claude Code makes
# no task start, so the hooks pass: they fail open. No file, no line that parses, or an unknown
# text prints nothing and exits 0.
# running_tasks(path, tail=n) reads only the last n bytes of the file and drops the line that the cut
# splits. The hooks of the lead turn pass 4 MiB, so the work stays bounded on a transcript of hundreds of
# MB; a task that starts before the tail is not found. With no tail the whole file is read.
import json
import re
import sys
import time
from datetime import datetime

START = [
    (re.compile(r"^Command running in background with ID: (\w+)"), "shell"),
    (re.compile(r"^Monitor started \(task (\w+)"), "monitor"),
    (re.compile(r"^Async agent launched successfully\..*?agentId: (\w+)", re.S), "agent"),
]
EXPIRY = re.compile(r"expires in (\d+)m")
ENDED = re.compile(r"<task-notification>\s*<task-id>(\w+)</task-id>(?:(?!</task-notification>).)*?<status>\w+</status>", re.S)
EXPIRED = re.compile(r"<task-id>(\w+)</task-id>\s*<summary>[^<]*</summary>\s*<event>\[Monitor expired after")
HANDED = re.compile(r"<agent-message from=\"(\w+)\">\s*\[Subagent hand-back\]")


def subagent_path(hook):
    """The transcript file of the subagent of a hook input, or None."""
    session = hook.get("transcript_path")
    agent = hook.get("agent_id")
    if not isinstance(session, str) or not isinstance(agent, str) or not agent or not session.endswith(".jsonl"):
        return None
    return session[: -len(".jsonl")] + "/subagents/agent-" + agent + ".jsonl"


def stamp(entry, now):
    try:
        return datetime.fromisoformat(str(entry.get("timestamp", "")).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return now


def read_lines(path, tail):
    """The lines of the file at `path`, or of its last `tail` bytes without the line that the cut splits."""
    with open(path, "rb") as handle:
        cut = 0
        if tail is not None:
            cut = max(0, handle.seek(0, 2) - tail)
            handle.seek(cut)
        lines = handle.read().decode("utf-8", errors="replace").splitlines()
    return lines[1:] if cut else lines


def running_tasks(path, now=None, tail=None):
    """The running tasks of the transcript at `path` as an id -> kind dict, in start order."""
    now = time.time() if now is None else now
    try:
        lines = read_lines(path, tail)
    except OSError:
        return {}
    uses, running, deadline = {}, {}, {}
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        message = entry.get("message")
        message = message if isinstance(message, dict) else {}
        content = message.get("content")
        if message.get("role") != "assistant":
            text = json.dumps(entry).replace("\\n", "\n").replace('\\"', '"')
            for task in ENDED.findall(text) + EXPIRED.findall(text) + HANDED.findall(text):
                running.pop(task, None)
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "tool_use":
                uses[block.get("id")] = block.get("name")
                if block.get("name") == "TaskStop":
                    running.pop(str((block.get("input") or {}).get("task_id")), None)
            elif block.get("type") == "tool_result" and uses.get(block.get("tool_use_id")) in ("Bash", "Monitor", "Agent"):
                body = block.get("content")
                text = body if isinstance(body, str) else "".join(b.get("text", "") for b in body or [] if isinstance(b, dict))
                for pattern, kind in START:
                    found = pattern.search(text)
                    if found:
                        running[found.group(1)] = kind
                        minutes = EXPIRY.search(text) if kind == "monitor" else None
                        if minutes:
                            deadline[found.group(1)] = stamp(entry, now) + 60 * int(minutes.group(1))
    return {task: kind for task, kind in running.items() if deadline.get(task, now + 1) > now}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: background-tasks.py <subagent transcript>")
    for task, kind in running_tasks(sys.argv[1]).items():
        print(task, kind)
