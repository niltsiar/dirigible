#!/bin/bash
# Append one row to the decisions.tsv of a run. The script writes the ts column from the clock,
# so no agent types or estimates a time.
# Usage: log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>
#        log-decision.sh <run folder> --from <file>
# With --from, the file has five lines: phase, decision, why, evidence, result. Use it when a
# field has text that the guardrail hook blocks in a command, for example the check and the commit.
set -euo pipefail

usage="usage: log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>
       log-decision.sh <run folder> --from <file>"
if [[ $# -eq 3 && "$2" == --from ]]; then
    [[ -f "$3" ]] || { echo "no file $3" >&2; exit 2; }
    fields=()
    while IFS= read -r line || [[ -n "$line" ]]; do fields+=("$line"); done < "$3"
    [[ ${#fields[@]} -eq 5 ]] || { echo "$3 has ${#fields[@]} lines; it must have five lines" >&2; exit 2; }
    set -- "$1" "${fields[@]}"
fi
[[ $# -eq 6 ]] || { echo "$usage" >&2; exit 2; }
file="$1/decisions.tsv"
[[ -f "$file" ]] || { echo "no decisions.tsv in $1; open the run with new-run.sh" >&2; exit 2; }
shift

# A tab or a line break in a field would break the TSV columns. Change each one to a space.
row="$(date +%FT%R)"
for field in "$@"; do
    row+=$'\t'"$(printf '%s' "$field" | tr '\t\n\r' '   ')"
done
printf '%s\n' "$row" >> "$file"
