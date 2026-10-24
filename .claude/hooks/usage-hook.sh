#!/bin/bash
# PreToolUse hook for the Agent, Workflow, SendMessage, and delegate_task tools: give the usage mode
# of docs/workflow/model-routing.md as context. It denies nothing and exits 0 at every mode. At stop,
# a free-model job, the reflect agent, and a job that the user approved can still start.
cat > /dev/null
here="$(cd "$(dirname "$0")" && pwd)"
mode="$("$here/../skills/deliver/scripts/usage-mode.sh" 2> /dev/null)" || mode=normal
case "$mode" in
    stop) text="Usage mode: stop. Start no new job, except a free-model job, the reflect agent, and a job that the user approved past the stop. Stop at a safe point and write the handoff in run.md." ;;
    save) text="Usage mode: save. Use the save row of the mode table in docs/workflow/model-routing.md." ;;
    spend) text="Usage mode: spend. Use the spend row of the mode table in docs/workflow/model-routing.md." ;;
    *) text="Usage mode: normal. Use the tables of docs/workflow/model-routing.md." ;;
esac
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$text"
exit 0
