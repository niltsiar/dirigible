#!/bin/bash
# Check that each target of the package treats every compiler warning as an error (SE-0480 in
# Package.swift) and has no setting that hides a warning: an exception for one warning, a second
# setting back to warnings, or an unsafe flag. dump-package lists only the targets of this package,
# so the settings of a dependency stay its own.
# Usage: scripts/check-warnings.sh [package root]. `make check` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

json="$(swift package --package-path "$root" dump-package 2>/dev/null)"
problems="$(jq -r '
  .targets[] | .name as $target | (.settings // []) as $settings
  | (if any($settings[]; .kind.treatAllWarnings._0? == "error" and .condition == null) then empty
     else "\($target): no treatAllWarnings(as: .error) for every configuration" end),
    ($settings[] | .kind | keys[0] as $kind
     | select($kind == "treatWarning" or $kind == "unsafeFlags"
         or ($kind == "treatAllWarnings" and .treatAllWarnings._0 != "error"))
     | "\($target): a \($kind) setting can hide a warning")' <<<"$json")"

[[ -z "$problems" ]] || { sed 's/^/check-warnings: /' <<<"$problems" >&2; exit 1; }
