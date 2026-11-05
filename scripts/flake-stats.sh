#!/bin/bash
# Print the flake and shard-time numbers of push-check logs: one header line, one tab-separated line
# for each log, and summary lines. Reads files only.
# Usage: scripts/flake-stats.sh <push-check log>...
#        scripts/flake-stats.sh --last <n> [<runs folder>]
# --last reads each logs/push-check*.log of the <n> run folders whose newest push-check log is
# newest (by mtime). The default runs folder is .scratchpads/runs of the main checkout (the parent
# of the git common dir), so a call from a worktree reads the shared ledger.
# Columns:
#   log          the path as given.
#   mtime        the mtime of the log, as YYYY-MM-DDTHH:MM.
#   tests        <n> of the last line "test-shards: <n> of <m> tests in <s> s".
#   suite_s      <s> of that line.
#   slowest_s    the highest "Test run with ... after <x> seconds" value in a "test-shards: shard
#                <name> (" section, rounded.
#   start_load   the first "check-changed: load <l>, under <m>: run the tests" value.
#   end_load     the first "check-changed: load <l>" value after the summary line, else "-".
#   class        idle when start_load and end_load are each under the count of shards (the names in
#                "test-shards: shard <name> ("), loaded when either is at or over it. A load that
#                is "-" is left out of the test; with no load, the class is "-".
#   reruns       the lines "run-checks: rerun <i> of <n>:".
#   flake_lines  the lines "run-checks: flake:".
#   flake_names  the names on those lines.
#   red          the lines "run-checks: red after".
#   lost         the lines with "the test process ended before its report".
# A log with no summary line has "-" in tests, suite_s, slowest_s, and class.
# The summary lines: the totals of the rows, then for idle and for loaded the count of logs and the
# median of slowest_s (the lower middle value for an even count; "-" with none).
# scripts/flake-stats.test.sh tests it.
set -euo pipefail
usage="usage: scripts/flake-stats.sh <push-check log>...
       scripts/flake-stats.sh --last <n> [<runs folder>]"
logs=()
if [[ "${1:-}" == --last ]]; then
    [[ $# -le 3 && "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "$usage" >&2; exit 2; }
    runs="${3:-}"
    if [[ -z "$runs" ]]; then
        common="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)"
        runs="$(dirname "$common")/.scratchpads/runs"
    fi
    folders="$(for d in "$runs"/*/logs; do
        newest="$(stat -f %m "$d"/push-check*.log 2>/dev/null | sort -rn | sed -n 1p || true)"
        [[ -z "$newest" ]] || printf '%s\t%s\n' "$newest" "$d"
    done | sort -rn | sed -n "1,${2}p" | cut -f2)"
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        for f in "$d"/push-check*.log; do logs+=("$f"); done
    done <<<"$folders"
else
    [[ $# -ge 1 && "$1" != -* ]] || { echo "$usage" >&2; exit 2; }
    logs=("$@")
fi

rows="$(for log in ${logs[@]+"${logs[@]}"}; do
    awk -v name="$log" -v mtime="$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M' "$log")" '
        BEGIN { tests = "-"; suite = "-"; sl = "-"; el = "-"; slowest = -1; done = 0; cur = ""; shards = 0
                reruns = 0; flakes = 0; names = 0; red = 0; lost = 0 }
        /^check-changed: load [0-9.]+, under [0-9.]+: run the tests/ && sl == "-" { sl = $3; sub(/,/, "", sl) }
        /^test-shards: shard [^ ]+ \(/ { cur = $3; if (!(cur in seen)) { seen[cur] = 1; shards++ } }
        cur != "" && /Test run with [0-9]+ tests?.* (passed|failed) after [0-9.]+ seconds/ {
            x = $0; sub(/.* after /, "", x); sub(/ seconds.*/, "", x); if (x + 0 > slowest) slowest = x + 0 }
        /^test-shards: [0-9]+ of [0-9]+ tests in [0-9]+ s$/ { tests = $2; suite = $(NF - 1); done = 1; cur = "" }
        done && el == "-" && /^check-changed: load / { el = $3; sub(/,/, "", el) }
        /^run-checks: rerun [0-9]+ of [0-9]+:/ { reruns++ }
        /^run-checks: flake:/ { flakes++; n = $0; sub(/^run-checks: flake: /, "", n); sub(/ passed on rerun.*/, "", n); names += split(n, a, " ") }
        /^run-checks: red after/ { red++ }
        /the test process ended before its report/ { lost++ }
        END {
            class = "-"; slow = "-"
            if (tests == "-") suite = "-"
            else {
                if (slowest >= 0) slow = sprintf("%.0f", slowest)
                if (shards > 0 && (sl != "-" || el != "-")) {
                    class = "idle"
                    if (sl != "-" && sl + 0 >= shards) class = "loaded"
                    if (el != "-" && el + 0 >= shards) class = "loaded"
                }
            }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", name, mtime, tests, suite, slow, sl, el, class, reruns, flakes, names, red, lost
        }' "$log"
done)"

printf 'log\tmtime\ttests\tsuite_s\tslowest_s\tstart_load\tend_load\tclass\treruns\tflake_lines\tflake_names\tred\tlost\n'
[[ -z "$rows" ]] || printf '%s\n' "$rows"
awk -F'\t' '
    function median(arr, n,   i, j, t) {
        for (i = 2; i <= n; i++) { t = arr[i]; for (j = i - 1; j >= 1 && arr[j] + 0 > t + 0; j--) arr[j + 1] = arr[j]; arr[j + 1] = t }
        return arr[int((n + 1) / 2)]
    }
    NF { n++; r += $9; f += $10; k += $11; x += $12; y += $13
      if ($8 == "idle" || $8 == "loaded") { c[$8]++; if ($5 != "-") { m[$8]++; v[$8, m[$8]] = $5 } } }
    END {
        printf "flake-stats: %d logs, %d reruns, %d flake lines, %d flake names, %d red, %d lost\n", n, r, f, k, x, y
        split("idle loaded", classes, " ")
        for (i = 1; i <= 2; i++) {
            cl = classes[i]; cnt = m[cl] + 0
            for (j = 1; j <= cnt; j++) tmp[j] = v[cl, j]
            printf "flake-stats: %s %d logs, median slowest shard %s s\n", cl, c[cl] + 0, cnt ? median(tmp, cnt) : "-"
        }
    }' <<<"$rows"
