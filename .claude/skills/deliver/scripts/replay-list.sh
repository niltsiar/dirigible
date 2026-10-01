#!/bin/bash
# List the killed control logs that a change since <base> can affect, for the replay after a
# Phase 7 fix (mutation-controls.md). Run it in the repo, at the commit to replay.
# Usage: replay-list.sh <controls folder> <base commit>
# A log is listed when `git diff --name-only --no-renames <base> HEAD` has its mutated file
# (`# mutation of`, `# in`) or a killing test file: a .swift file under Tests/ that declares a
# type or defines a func whose name contains a name of the `# test:` line. The names come from
# `--filter <arg>` (a suite, a func, or a regex: split on | and /, parentheses removed) and from
# `scripts/bench.sh <name>`. Each line is the log, then the changed files that it matched.
# The script fails open: a log with a name that resolves to no file is listed with `unresolved`.
# A `killed (hang)` result counts as killed. Only the logs at the top of the folder count, not the
# *.orig copies or the logs under replay*/. replay-list.test.sh tests it.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: replay-list.sh <controls folder> <base commit>" >&2; exit 2; }
folder="${1%/}" base="$2"
[[ -d "$folder" ]] || { echo "replay-list: no folder $folder" >&2; exit 2; }
abs="$(cd "$folder" && pwd)"
cd "$(git rev-parse --show-toplevel)"
changed="$(git diff --name-only --no-renames "$base" HEAD)"
[[ -n "$changed" ]] || exit 0

# The names of a test line, one for each line.
names_of() {
    {
        grep -oE -- "--filter[= ]+('[^']*'|\"[^\"]*\"|[^ ]+)" <<<"$1" | sed -E 's/^--filter[= ]+//' || true
        grep -oE "scripts/bench\.sh +('[^']*'|\"[^\"]*\"|[^ ]+)" <<<"$1" | sed -E 's|^scripts/bench\.sh +||' || true
    } | tr -d "'\"()" | tr '|/' '\n\n' | grep -v '^$' || true
}

for log in "$abs"/*.log; do
    [[ -f "$log" ]] && grep -q '^# result: killed' "$log" || continue
    files="$(sed -n -E 's/^# (mutation of|in) //p' "$log")"
    names="$(names_of "$(sed -n 's/^# test: //p' "$log")")"
    unresolved=no
    [[ -n "$names" ]] || unresolved=yes
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # A part that is not a name (a regex with .* or [) resolves to no file.
        [[ "$name" =~ ^[A-Za-z0-9_]+$ ]] || { unresolved=yes; continue; }
        hits="$(grep -rlE --include='*.swift' "(struct|class|enum|actor|extension|func)[[:space:]]+[A-Za-z0-9_]*$name" Tests 2>/dev/null || true)"
        [[ -n "$hits" ]] || { unresolved=yes; continue; }
        files+=$'\n'"$hits"
        # The other files of a suite hold its helpers: add each file that declares a top-level
        # type of a hit file.
        for type in $(sed -n -E '/^[^[:space:]\/]/s/.*(^|[^A-Za-z0-9_])(struct|class|enum|actor|extension)[[:space:]]+([A-Za-z0-9_]+).*/\3/p' $hits | sort -u); do
            files+=$'\n'"$(grep -rlE --include='*.swift' "(struct|class|enum|actor|extension)[[:space:]]+$type([^A-Za-z0-9_]|$)" Tests || true)"
        done
    done <<<"$names"
    matched="$(grep -xF -f <(printf '%s\n' "$changed") <<<"$files" | sort -u | paste -sd' ' - || true)"
    [[ $unresolved == yes ]] && matched="${matched:+$matched }unresolved"
    [[ -n "$matched" ]] && echo "$folder/$(basename "$log") $matched"
done
exit 0
