#!/bin/bash
# Append one row to the decisions.tsv of a run. The script writes the ts column from the clock,
# so no agent types or estimates a time.
# Usage: log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>
set -euo pipefail

[[ $# -eq 6 ]] || { echo "usage: log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>" >&2; exit 2; }
file="$1/decisions.tsv"
[[ -f "$file" ]] || { echo "no decisions.tsv in $1; open the run with new-run.sh" >&2; exit 2; }
shift

# A tab or a line break in a field would break the TSV columns. Change each one to a space.
row="$(date +%FT%R)"
for field in "$@"; do
    row+=$'\t'"$(printf '%s' "$field" | tr '\t\n\r' '   ')"
done
printf '%s\n' "$row" >> "$file"
