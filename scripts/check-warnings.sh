#!/bin/bash
# Check that each target of the package treats every Swift warning as an error (SE-0480 in
# Package.swift), that each target with a .c file in its folder also treats every C warning as an
# error, that each target with a .cpp, .cc, or .mm file in its folder treats every C++ warning as
# an error, and that no target has a setting that hides a warning: an exception for one warning, a
# disabled warning, a second setting back to warnings, or an unsafe flag. dump-package lists only
# the targets of this package, so the settings of a dependency stay its own.
# Usage: scripts/check-warnings.sh [package root]. `make check` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

json="$(swift package --package-path "$root" dump-package)"
strict() { printf 'any($settings[]; .tool == "%s" and .kind.treatAllWarnings._0? == "error" and .condition == null)' "$1"; }
problems="$(jq -r '
  .targets[] | .name as $target | (.settings // []) as $settings
  | (if '"$(strict swift)"' then empty
     else "\($target): no treatAllWarnings(as: .error) for every configuration" end),
    ($settings[] | .kind | keys[0] as $kind
     | select($kind == "treatWarning" or $kind == "unsafeFlags" or $kind == "disableWarning"
         or ($kind == "treatAllWarnings" and .treatAllWarnings._0 != "error"))
     | "\($target): the \($kind) setting can hide a warning")' <<<"$json")"

# A target folder is its path, else Sources/<name>, or Tests/<name> for a test target.
while IFS=$'\t' read -r target folder c_strict cxx_strict; do
  if [[ "$c_strict" == false ]] && [[ -n "$(find "$root/$folder" -name '*.c' -print -quit 2>/dev/null)" ]]; then
    problems+=$'\n'"$target: no treatAllWarnings(as: .error) for C"
  fi
  if [[ "$cxx_strict" == false ]] && [[ -n "$(find "$root/$folder" \( -name '*.cpp' -o -name '*.cc' -o -name '*.mm' \) \
    -print -quit 2>/dev/null)" ]]; then
    problems+=$'\n'"$target: no treatAllWarnings(as: .error) for C++"
  fi
done < <(jq -r '.targets[] | (.settings // []) as $settings
  | [.name, (.path // (if .type == "test" then "Tests/" else "Sources/" end) + .name),
     ('"$(strict c)"' | tostring), ('"$(strict cxx)"' | tostring)] | @tsv' <<<"$json")

problems="$(sed '/^$/d' <<<"$problems")"
[[ -z "$problems" ]] || { sed 's/^/check-warnings: /' <<<"$problems" >&2; exit 1; }
