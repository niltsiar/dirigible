#!/bin/bash
# PostCompact hook: append one line to dirigible-compactions.log in the git common dir:
# `<time> <agent id or lead> run-folder: yes|no`. The answer is yes when the compaction summary holds a
# .scratchpads/runs/ path. A reader counts the summaries that lost the run folder (19 of 140 did when
# the log was missing). Input that does not parse, and a cwd outside a git checkout, add no line. The
# hook always exits 0.
python3 -I -c '
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

try:
    hook = json.loads(sys.argv[1])
    cwd = hook["cwd"]
    summary = hook.get("compact_summary")
    summary = summary if isinstance(summary, str) else ""
    done = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True, timeout=10)
    if done.returncode != 0 or not done.stdout.strip():
        sys.exit(0)
    agent = hook.get("agent_id") or "lead"
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = stamp + " " + str(agent) + " run-folder: " + ("yes" if ".scratchpads/runs/" in summary else "no") + "\n"
    with open(os.path.join(done.stdout.strip(), "dirigible-compactions.log"), "a", encoding="utf-8") as handle:
        handle.write(line)
except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
    pass
' "$(cat)"
exit 0
