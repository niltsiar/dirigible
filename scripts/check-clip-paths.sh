#!/bin/bash
# Check that each clip file reader opens the name that poolFileName gives: a pool
# file can be `Clips/<stem>.wav` or `Clips/<stem>.flac` on disk, so a path built by hand misses the
# archived form. Two rules, each on the Swift files under Sources/, with no comment line:
# - A clip path: a line with `\(clipsFolderName)` or `clips.appending(path:` fails, outside
#   Sources/DirigibleCore/Session+Archive.swift (the resolver).
# - An open sink: a line of Sources/DirigibleAudio/Import, Render, or Transcribe with
#   `AVAudioFile(forReading:`, `openat(`, `open(` (no letter, `_`, or `.` before it),
#   `openChecked(`, or `openAudio(` fails. A sink that opens a pool file names its resolver
#   variable in its reason; each other sink names what it opens.
# scripts/check-clip-paths.allow lets a line pass: <path><TAB><trimmed line text><TAB><reason>, and
# a line that starts with # is a comment. One entry covers each line of that file with that text. An
# entry with no reason, or with no line, also fails, so the list stays true: a change of an allowed
# line needs its entry in the same commit.
# The rules match text, not data flow: a path built another way (`appendingPathComponent`, a
# variable with another name) or a sink outside the three folders passes.
# Exit 1 with a `check-clip-paths:` line for each problem; exit 2 when the allow file cannot be
# read or the awk pass fails.
# Usage: scripts/check-clip-paths.sh [root]. `make check-slow-gates` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"
allow=scripts/check-clip-paths.allow
[[ ! -e "$allow" || -r "$allow" ]] || { echo "check-clip-paths: $allow cannot be read" >&2; exit 2; }
[[ -e "$allow" ]] || allow=/dev/null
files=()
if [[ -d Sources ]]; then
  while IFS= read -r file; do files+=("$file"); done < <(find Sources -type f -name '*.swift' | LC_ALL=C sort)
fi

status=0
problems="$(LC_ALL=C awk -v allow="$allow" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
FILENAME == allow {
  if ($0 ~ /^[ \t]*(#|$)/) next
  n = split($0, f, "\t")
  if (n < 3 || trim(f[3]) == "") { print allow ":" FNR ": an allow entry with no reason"; next }
  key = f[1] SUBSEP f[2]
  entry[key] = FNR
  next
}
{
  t = trim($0)
  if (substr(t, 1, 2) == "//") next
  kind = ""
  if (FILENAME != "Sources/DirigibleCore/Session+Archive.swift" &&
      (index(t, "\\(clipsFolderName)") || index(t, "clips.appending(path:"))) {
    kind = "a clip path built by hand"
  } else if (FILENAME ~ /^Sources\/DirigibleAudio\/(Import|Render|Transcribe)\// &&
      (index(t, "AVAudioFile(forReading:") || index(t, "openat(") || index(t, "openChecked(") ||
       index(t, "openAudio(") || t ~ /(^|[^A-Za-z_.])open\(/)) {
    kind = "an open sink with no allow entry"
  }
  if (kind == "") next
  key = FILENAME SUBSEP t
  if (key in entry) { used[key] = 1; next }
  print FILENAME ":" FNR ": " kind ": " t
}
END {
  for (key in entry) if (!(key in used)) {
    split(key, k, SUBSEP)
    print allow ":" entry[key] ": an allow entry that matches no line: " k[1] ": " k[2]
  }
}
' "$allow" "${files[@]+"${files[@]}"}")" || status=$?
if [[ $status -ne 0 ]]; then
  echo "check-clip-paths: awk failed with status $status" >&2
  exit 2
fi
[[ -n "$problems" ]] || exit 0
sed 's/^/check-clip-paths: /' <<<"$problems" >&2
exit 1
