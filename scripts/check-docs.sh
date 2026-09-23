#!/bin/bash
# Check the structure of the docs that plans and reviews depend on.
# Usage: scripts/check-docs.sh [repo root]. `make check` runs it.
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)}"
fail=0
err() { echo "check-docs: $*" >&2; fail=1; }

# Every research file has a date and cites its sources.
for f in "$root"/docs/research/*.md; do
    [[ -e "$f" ]] || continue
    grep -q '^Date: [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' "$f" || err "${f#"$root"/}: no 'Date: YYYY-MM-DD' line"
    grep -q '^## Sources' "$f" || err "${f#"$root"/}: no '## Sources' section"
done

exit "$fail"
