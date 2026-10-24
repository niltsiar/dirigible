#!/bin/bash
# PreToolUse hook for the Agent, Workflow, SendMessage, and delegate_task tools: give the usage mode
# of docs/workflow/model-routing.md to the model as context, at every mode. The hook denies nothing,
# reads no field of its input, and always exits 0: a free-model job or the reflect agent can still
# start at stop. A failure of usage-mode.sh gives the normal text.
cat > /dev/null
here="$(cd "$(dirname "$0")" && pwd)"
mode="$("$here/../skills/deliver/scripts/usage-mode.sh" 2> /dev/null)" || mode=normal
case "$mode" in
    stop) text="Usage mode: stop. At 80 percent of the five-hour limit, stop at a safe point: start no new job, except the reflect agent and a job that the user approved past the stop. Write the handoff in run.md." ;;
    save) text="Usage mode: save. Use the save row of the mode table in docs/workflow/model-routing.md." ;;
    spend) text="Usage mode: spend. Use the spend row of the mode table in docs/workflow/model-routing.md." ;;
    *) text="Usage mode: normal. Use the tables of docs/workflow/model-routing.md." ;;
esac
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$text"
exit 0
