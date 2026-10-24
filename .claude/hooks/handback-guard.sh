#!/bin/bash
# PreToolUse hook for SubagentHandback: refuse a hand-back while a background task of the agent
# runs. A report that the agent hands back before a task ends comes back as a second report, and
# the first one is lost on a wait of the lead. Exit 2 blocks the call and shows the message to the
# agent, which stops each task with TaskStop and calls SubagentHandback again.
# The hook input has no task list, so background-tasks.py reads the transcript of the agent. It
# starts a task at the result text of a background Bash, Monitor, or async Agent call, and ends it
# at a notification with a status, a Monitor expiry, a child hand-back, or a TaskStop call (the
# texts are in its header). The hook refuses only SubagentHandback, only in a subagent, and only
# for an id with a start and no end. It passes every input that it cannot read: no agent_id (the
# lead), no transcript file, input that is not JSON, and a start or end text that a newer Claude
# Code changed. A refusal with no way out would lose the report.
here="$(cd "$(dirname "$0")" && pwd)"
input="$(cat)"
running="$(python3 -I -c '
import importlib.util
import json
import sys

try:
    hook = json.loads(sys.argv[1])
except ValueError:
    sys.exit(0)
if not isinstance(hook, dict) or hook.get("tool_name") != "SubagentHandback":
    sys.exit(0)
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("background_tasks", sys.argv[2])
tasks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tasks)
path = tasks.subagent_path(hook)
for task, kind in (tasks.running_tasks(path) if path else {}).items():
    print(task, kind)
' "$input" "$here/background-tasks.py" 2>/dev/null)" || exit 0
[[ -n "$running" ]] || exit 0
names="" stops=""
while read -r id kind; do
  names+="${names:+, }$id ($kind)"
  stops+="${stops:+, }TaskStop $id"
done <<< "$running"
echo "BLOCKED by .claude/hooks/handback-guard.sh: background tasks still run: $names. Stop each one with $stops, then call SubagentHandback again. Wait for a task only when the report needs its result. Never stop a task with pkill -f." >&2
exit 2
