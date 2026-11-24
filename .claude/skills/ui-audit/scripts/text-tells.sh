#!/bin/bash
# Count the text patterns of a Localizable.strings table that the ui-audit skill treats as AI tells.
# Usage: bash text-tells.sh [<path of a .strings file>]
#   With no path, the script reads the English table of the checkout that holds it.
# Prints "values <n>" and then one "<pattern> <count>" line per pattern, in this order. Each count
# is the number of values that match: a value that has two tells counts in two patterns. A pattern
# reads the value part of a line only, never its key, except error_opener, which reads the values
# of the keys that start with "error.".
#   colon_fact            a fact after a colon: "No call track: the first track is chosen."
#   count_after_colon     a count after a colon at the end: "Clips changed: %lld."
#   two_sentences         two or more sentences
#   app_name_subject      the app name as the subject: "Dirigible did", "does", "sends", "keeps", ...
#   error_opener          an error that opens with "Dirigible cannot", "could not", or "did not"
#   contraction           a negative contraction ("Don't Save"); a good sign, not a tell
#   uncontracted_negation cannot, does not, did not, do not, is not, are not, could not
#   passive               "is", "are", "was", or "were" before a word that ends in -ed
#   because               a cause told in the text
#   middle_dot            a middle dot (U+00B7) as a separator
#   three_periods         "..." where the ellipsis character (U+2026) belongs
#   exclamation           a value that ends in an exclamation mark
# The counts are evidence for the audit, not a verdict: the skill grades the screenshots first.
set -u
command -v rg >/dev/null || { echo "text-tells: rg is missing" >&2; exit 2; }
f="${1:-$(cd "$(dirname "$0")/../../../.." && pwd)/Support/Resources/en.lproj/Localizable.strings}"
[[ -f "$f" ]] || { echo "text-tells: no such file: $f" >&2; exit 2; }
values() { sed -n 's/^"[^"]*" = "\(.*\)";$/\1/p' "$f"; }
error_values() { sed -n 's/^"error\.[^"]*" = "\(.*\)";$/\1/p' "$f"; }
# count <name> <source function> <rg pattern>
count() {
  local n rc
  n="$("$2" | rg -c -e "$3")"
  rc=$?
  case $rc in
    0) ;;
    1) n=0 ;;
    *) echo "text-tells: rg failed on the pattern $1" >&2; exit 2 ;;
  esac
  printf '%s %s\n' "$1" "$n"
}
printf 'values %s\n' "$(values | wc -l | tr -d ' ')"
count colon_fact values '[a-z]: [a-z%]'
count count_after_colon values ': %(lld|@)\.?$'
count two_sentences values '\. [A-Z%]'
count app_name_subject values 'Dirigible (did|does|sends|keeps|cannot|could)'
count error_opener error_values '^Dirigible (cannot|could not|did not)'
count contraction values "n't\\b"
count uncontracted_negation values '\b(cannot|does not|did not|do not|is not|are not|could not)\b'
count passive values '\b(is|are|was|were) [a-z]+ed\b'
count because values '\bbecause\b'
count middle_dot values '\x{00B7}'
count three_periods values '\.\.\.'
count exclamation values '!$'
