#!/bin/bash
# Check that bundle.sh refuses a bundle path outside build/ before it builds or deletes
# anything. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
failures=0

for path in /private/tmp/dirigible-guard.app build/../dirigible-guard.app; do
    output="$("$here/bundle.sh" "$path" 2>&1)"
    status=$?
    if [[ $status -ne 2 ]] || ! grep -qF "bundle.sh: the bundle path must be build/<name>.app" <<<"$output"; then
        echo "FAIL: bundle.sh accepted a path outside build/: $path (exit $status)"
        failures=$((failures + 1))
    fi
done

[[ $failures -eq 0 ]] && echo "bundle.test.sh: all checks passed"
exit "$failures"
