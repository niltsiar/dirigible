#!/bin/bash
# PostToolUse hook for mcp__t3-code__delegate_task and mcp__t3-code__task_cancel, and UserPromptSubmit
# hook: keep the delegate_task records of dirigible-lock-agents in the git common dir (or
# $DIRIGIBLE_LOCK_AGENTS), which agent-guard.sh writes and the release-wait rule of
# git-guardrails.sh reads (AGT-152).
# - PostToolUse of delegate_task: the first taskId of tool_response (a JSON string, or a list of text
#   blocks; the form "taskId": "<id>", with or without spaces at the colon) goes into the key field of
#   the record whose file name is the tool_use_id. When the first "status" of that text is completed
#   or failed (a mode wait call returns the end state, and no end text follows), the record goes.
# - UserPromptSubmit: each line of prompt that starts with the end text of a child,
#   Delegated task <taskId> (<title>) [completed]: or [failed]:, removes the record of that taskId.
#   Another state, such as [running], keeps it.
# - PostToolUse of task_cancel: tool_input.taskId removes the record of that taskId.
# A remove compares the whole key field with the taskId as a fixed string: real taskIds have a
# prefix pair (<id> and <id>-2) and can hold a dot.
# The hook prints nothing, because the stdout of UserPromptSubmit goes into the context, and it
# exits 0 on each input. An input with no end text and neither tool name exits before any other
# process starts, so a plain prompt costs one cat.

input="$(cat)"
case "$input" in
  *'Delegated task '* | *mcp__t3-code__delegate_task* | *mcp__t3-code__task_cancel*) ;;
  *) exit 0 ;;
esac
# get <key path>: the raw value at the path, or nothing. plutil reads JSON and ships with macOS.
get() { plutil -extract "$1" raw -o - - <<< "$input" 2>/dev/null; }
dt=mcp__t3-code__delegate_task
if [[ -n "${DIRIGIBLE_LOCK_AGENTS:-}" ]]; then rec_dir="$DIRIGIBLE_LOCK_AGENTS"
else rec_dir="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/dirigible-lock-agents" || exit 0; fi
[[ -d "$rec_dir" ]] || exit 0

# remove <taskId>: delete each delegate_task record whose key field equals the taskId.
remove() {
  local rec t tool key
  for rec in "$rec_dir"/*; do
    [[ -f "$rec" ]] || continue
    IFS=$'\t' read -r t tool key _ < "$rec" || true
    [[ "$tool" == "$dt" && "$key" == "$1" ]] && rm -f "$rec"
  done
}

event="$(get hook_event_name)"
if [[ "$event" == UserPromptSubmit ]]; then
  end_re='^Delegated task ([^[:space:]]+) \(.*\) \[(completed|failed)\]:'
  while IFS= read -r line; do
    [[ "$line" =~ $end_re ]] && remove "${BASH_REMATCH[1]}"
  done <<< "$(get prompt)"
  exit 0
fi
[[ "$event" == PostToolUse ]] || exit 0
tool="$(get tool_name)"
if [[ "$tool" == mcp__t3-code__task_cancel ]]; then
  id="$(get tool_input.taskId)"
  [[ -n "$id" ]] && remove "$id"
  exit 0
fi
[[ "$tool" == "$dt" ]] || exit 0
use_id="$(get tool_use_id)"
[[ "$use_id" =~ ^[A-Za-z0-9_-]+$ && -f "$rec_dir/$use_id" ]] || exit 0
task_re='"taskId"[[:space:]]*:[[:space:]]*"([^"]+)"'
id="" text=""
if [[ "$(plutil -type tool_response - <<< "$input" 2>/dev/null)" == array ]]; then
  n="$(get tool_response)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  for ((i = 0; i < n; i++)); do
    text="$(get "tool_response.$i.text")"
    [[ "$text" =~ $task_re ]] && { id="${BASH_REMATCH[1]}"; break; }
  done
else
  text="$(get tool_response)"
  [[ "$text" =~ $task_re ]] && id="${BASH_REMATCH[1]}"
fi
[[ -n "$id" ]] || exit 0
IFS=$'\t' read -r t r_tool key path desc < "$rec_dir/$use_id" || true
[[ "$r_tool" == "$dt" ]] || exit 0
status_re='"status"[[:space:]]*:[[:space:]]*"([a-z_]+)"'
if [[ "$text" =~ $status_re ]] && [[ "${BASH_REMATCH[1]}" == completed || "${BASH_REMATCH[1]}" == failed ]]; then
  rm -f "$rec_dir/$use_id"
  exit 0
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$t" "$r_tool" "${id//[$'\t\n']/ }" "$path" "$desc" > "$rec_dir/.$use_id.tmp" &&
  mv "$rec_dir/.$use_id.tmp" "$rec_dir/$use_id"
exit 0
