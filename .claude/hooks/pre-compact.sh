#!/bin/bash
# PreCompact hook: print what the compaction summary must keep. Claude Code appends the stdout of this
# hook to the compaction instructions, so a summary keeps the run state.
# The text is 120 words or fewer. It holds a fixed list of what to keep, then the facts of the open run
# of cwd (open-run.py): its folder, branch, and worktree, the first unticked line of run.md, and the
# running background tasks of the last 4 MiB of the transcript (background-tasks.py). It copies no message of the user:
# the compaction model keeps the instructions of the user in its own summary. With no open run the
# text is the list alone. The hook always exits 0.
here="$(cd "$(dirname "$0")" && pwd)"
input="$(cat)"
python3 -I -c '
import importlib.util
import json
import os
import sys

here = sys.argv[2]
sys.dont_write_bytecode = True


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def cut(text, words):
    parts = text.split()
    return " ".join(parts[:words]) + (" ..." if len(parts) > words else "")


out = "Keep in the summary: the instructions of the user, the run folder, the branch, the worktree path, the first unticked slice, and the background task IDs."
try:
    hook = json.loads(sys.argv[1])
    cwd = hook.get("cwd")
    transcript = hook.get("transcript_path")
    open_run = load("open_run", "open-run.py")
    found = open_run.open_run(cwd) if isinstance(cwd, str) else None
    if found:
        folder, how = found
        branch = open_run.run_branch(folder)
        guess = " (a guess: the newest row)" if how == "newest row" else ""
        out += " Run folder: " + cut(folder, 1) + guess + "."
        out += " Branch: " + (branch or "none") + "."
        out += " Worktree: " + (open_run.worktree_of(cwd, branch) or "none") + "."
        out += " First unticked: " + cut(open_run.first_unticked(folder), 25) + "."
    if isinstance(transcript, str):
        tasks = load("background_tasks", "background-tasks.py").running_tasks(transcript, tail=4 << 20)
        if tasks:
            ids = [task + " (" + kind + ")" for task, kind in tasks.items()]
            out += " Background tasks: " + ", ".join(ids[:12]) + (" and " + str(len(ids) - 12) + " more" if len(ids) > 12 else "") + "."
except Exception:
    pass
print(cut(out, 120))
' "$input" "$here"
exit 0
