#!/bin/bash
# Print the usage mode of the lead thread: save, spend, or normal (docs/workflow/model-routing.md).
# Usage: usage-mode.sh
# It reads the five_hour row of ~/.claude/usage/limits.json (USAGE_LIMITS_FILE sets another file;
# USAGE_MODE_NOW sets the clock, in epoch seconds). Claude Code writes the file at the end of each
# turn of the main agent, so an in-process subagent does not update it. The first rule that fits wins:
# - no file, no five_hour row, or a resetsAt in the past (a new window): normal.
# - written_at more than 15 min ago, with a future resetsAt: save (the percent is out of date).
# - percentUsed 75 or more: save.
# - the reset is 60 min or less away, and percentUsed is 70 or less: spend.
# - else: normal.
# The numbers come from the highest rate on record: 54 % to 81 % in about 70 min of Opus work, so
# 25 % lasts about one hour. usage-mode.test.sh tests it.
set -euo pipefail

file="${USAGE_LIMITS_FILE:-$HOME/.claude/usage/limits.json}"
now="${USAGE_MODE_NOW:-$(date +%s)}"
command -v jq > /dev/null || { echo "usage-mode: jq is not installed" >&2; exit 2; }
[[ -f "$file" ]] || { echo normal; exit 0; }

jq -r --argjson now "$now" --argjson stale 900 --argjson save 75 --argjson window 3600 --argjson spend 70 '
    ([.rate_limits[]? | select(.kind == "five_hour")] | first) as $row
    | if $row == null then "normal"
      else
        ($row.resetsAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $reset
        | if $reset <= $now then "normal"
          elif $now - ((.written_at // 0) / 1000) > $stale then "save"
          elif $row.percentUsed >= $save then "save"
          elif $reset - $now <= $window and $row.percentUsed <= $spend then "spend"
          else "normal" end
      end' "$file"
