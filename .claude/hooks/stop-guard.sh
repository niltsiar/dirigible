#!/bin/bash
# Stop hook of the lead: log a turn end that can leave the loop idle. It never blocks.
# A shell with no Monitor wakes nobody when it ends, so the loop stood idle for hours (AGT-119/tool).
# The hook reads the lead transcript with background-tasks.py (its header has the start and end
# texts) and appends one line to dirigible-stop-shadow.log in the git common dir:
# - Rule A: the running tasks are only shells: `<time> would-block-shell <ids>: <reason>`.
# - Rule B: no task runs, an open run (open-run.py) has an unticked phase, and its run.md has no
#   `waits: user` line: `<time> would-block <run> via <how>: <phase>`.
# A Monitor or an agent among the tasks, no transcript, a cwd outside a git checkout, and
# stop_hook_active true (another Stop hook blocked this stop) add no line.
# After 20 lines of both rules, or 14 days after the first line, the hook appends one `done` line,
# then no line. A reader reads the log and decides on a block: a replay of the lead transcripts found
# that a block on rule A stops most turn ends while one long shell lives.
# The hook runs at each lead turn, so its work is bounded: it reads the log first and ends on `done`
# before it reads the transcript, it reads only the last 4 MiB of the transcript, and settings.json
# sets a timeout.
# The hook always exits 0, so a changed text of a newer Claude Code fails open.
here="$(cd "$(dirname "$0")" && pwd)"
input="$(cat)"
python3 -I -c '
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone

here = sys.argv[2]
sys.dont_write_bytecode = True


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


try:
    hook = json.loads(sys.argv[1])
except ValueError:
    sys.exit(0)
if not isinstance(hook, dict) or hook.get("stop_hook_active"):
    sys.exit(0)
cwd = hook.get("cwd")
if not isinstance(cwd, str):
    sys.exit(0)
open_run = load("open_run", "open-run.py")
common = open_run.git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
if not common:
    sys.exit(0)
log = os.path.join(common, "dirigible-stop-shadow.log")
try:
    with open(log, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
except OSError:
    lines = []
if any(line.split()[1:2] == ["done"] for line in lines):
    sys.exit(0)
transcript = hook.get("transcript_path")
tasks = load("background_tasks", "background-tasks.py").running_tasks(transcript, tail=4 << 20) if isinstance(transcript, str) else {}
if tasks:
    if set(tasks.values()) != {"shell"}:
        sys.exit(0)
    entry = "would-block-shell " + ",".join(tasks) + ": only background shells run, no Monitor"
else:
    found = open_run.open_run(cwd)
    if not found:
        sys.exit(0)
    folder, how = found
    phase, waits = open_run.run_state(folder)
    if not phase or waits:
        sys.exit(0)
    entry = "would-block " + os.path.basename(folder) + " via " + how + ": " + phase
now = datetime.now(timezone.utc)
first = None
if lines:
    try:
        first = datetime.strptime(lines[0].split()[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        pass
if len(lines) >= 20 or (first and (now - first).days >= 14):
    entry = "done"
try:
    with open(log, "a", encoding="utf-8") as handle:
        handle.write(now.strftime("%Y-%m-%dT%H:%M:%SZ") + " " + entry + "\n")
except OSError:
    pass
' "$input" "$here"
exit 0
