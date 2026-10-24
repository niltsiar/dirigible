#!/bin/bash
# Print the usage mode of the lead thread: stop, save, spend, or normal (docs/workflow/model-routing.md).
# Usage: usage-mode.sh
# It reads the five_hour row of ~/.claude/usage/limits.json (USAGE_LIMITS_FILE sets another file;
# USAGE_MODE_NOW sets the clock, in epoch seconds). The file is optional. Claude Code does not write
# it: a Claude Code mod of the user setup (a turn hook) writes it after each main-agent turn, so an
# in-process subagent does not update it. With no file, the mode is normal. The first rule that fits wins:
# - no file, no five_hour row, a resetsAt in the past (a new window), or a percentUsed that is not
#   a number or a resetsAt that is not an ISO date: normal.
# - percentUsed 80 or more: stop, also when the file is stale (a lead agent often starts with a stale file).
# - written_at more than 15 min ago, with a future resetsAt: save (the percent is out of date).
# - percentUsed 75 or more: save.
# - the reset is 60 min or less away, and percentUsed is 70 or less: spend.
# - else: normal.
# The numbers come from the highest rate on record: 54 % to 81 % in about 70 min of Opus work, so
# 25 % lasts about one hour.
set -euo pipefail

file="${USAGE_LIMITS_FILE:-$HOME/.claude/usage/limits.json}"
now="${USAGE_MODE_NOW:-$(date +%s)}"
command -v jq > /dev/null || { echo "usage-mode: jq is not installed" >&2; exit 2; }
[[ -f "$file" ]] || { echo normal; exit 0; }

jq -r --argjson now "$now" --argjson stale 900 --argjson save 75 --argjson stop 80 --argjson window 3600 --argjson spend 70 '
    ([.rate_limits[]? | select(.kind == "five_hour")] | first) as $row
    | if $row == null then "normal"
      else
        ($row.resetsAt | if type == "string" then try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null else null end) as $reset
        | if $reset == null or ($row.percentUsed | type) != "number" then "normal"
          elif $reset <= $now then "normal"
          elif $row.percentUsed >= $stop then "stop"
          elif $now - ((.written_at // 0) / 1000) > $stale then "save"
          elif $row.percentUsed >= $save then "save"
          elif $reset - $now <= $window and $row.percentUsed <= $spend then "spend"
          else "normal" end
      end' "$file"
