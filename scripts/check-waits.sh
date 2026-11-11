#!/bin/bash
# Check that no Swift file under Tests/ calls `.wait(timeout:` (a raw DispatchSemaphore or
# DispatchGroup wait), unless scripts/check-waits.allow names the file with a reason. A hold of
# product work goes through `Gate` (Tests/DirigibleAudioTests/Support.swift): `Gate(limit:)` has no
# default, so the compiler names each limit, and a raw wait has a wall limit that expires when a
# loaded test runs slow. An allow line is <path><TAB><reason>, and a line that starts with # is a
# comment. An entry with no reason, or for a file with no raw wait, also fails, so the list stays
# true. A line under Tests/ with `"quarantine:` and no FLAKE word also fails: each quarantine of a
# flaky test names its FLAKE item (flake-triage.md, Time box). A Swift file under Tests/ with
# `isIntermittent: true` and no such `"quarantine:` line with a FLAKE word also fails. The match is
# one line: a call split over two lines passes.
# In a git work tree, two more gates compare the Swift files with the reference: HEAD (the empty
# tree before the first commit), or, with BASE set, the merge base of BASE and HEAD, the commit
# that the rest of the push check compares with. No BASE and no merge base exits 2. The count gate:
# a Swift file under Tests/ or Sources/ with more wall-clock lines (the terms r1 below, a comment
# line counts) than at the reference, and over its cap in scripts/check-waits.counts, fails. A
# counts line is `mode warn`, `mode fail`, or <path><TAB><cap><TAB><reason>. The first line that is
# no comment is the mode; with no file or no mode line, the mode is fail and no cap counts. In mode
# warn the count gate prints `check-waits: warning: ` lines and does not change the exit. A cap
# line with no reason, with no whole number, or over the count of its file is a count gate line
# too. More lines with `isIntermittent`, `"quarantine:`, or `.disabled(` (each counted on its own)
# in all Swift files under Tests/ than at the reference fails in each mode, with no cap: a flaky
# test moves to the real-time tier (flake-triage.md, Time box), and no commit adds a quarantine of
# any form. The gate compares the total, so a rename or a split of a file that keeps the lines passes.
# The debug-only member gate: a line under Tests/ outside `#if DEBUG` that names `.<member>` fails
# when Sources/ declares that member (a var, let, func, or case at type level, not private) only in
# a debug branch: `#if DEBUG`, `#if DEBUG && <flag>`, or the `#else` of `#if !DEBUG`.
# scripts/bench.sh builds the tests with no DEBUG, so such a use stops the bench build. The gate
# matches names, not types. It does not see: a debug-only name that a release declaration in
# Sources/ also has; a use with no dot, a key path, or a use through a typealias or protocol; a
# debug-only type, init, or subscript; a member under `#if DEBUG || <flag>`. A debug-only name used
# as `.name` on another type in Tests/ also fails: put that test in `#if DEBUG`, or give the member
# a unique name. In a git work tree the gate runs only when a Swift file under Sources/ or Tests/
# differs from the reference; outside a work tree it always runs.
# Usage: scripts/check-waits.sh [root]. `make check-slow-gates` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
allow="$root/scripts/check-waits.allow"
problems=""
entries=""
# nomatch <label> <command>...: run it. Status 1 is "no match"; any other nonzero status stops the script.
nomatch() {
  local label="$1" s=0
  shift
  "$@" || s=$?
  [[ $s -le 1 ]] || { echo "check-waits: $label failed with status $s" >&2; exit 2; }
}
# tests_grep <grep option>... <pattern>: `grep -r` over the Swift files of Tests/; nothing to find when the folder is absent.
tests_grep() { [[ -d "$root/Tests" ]] || return 0; (cd "$root" && nomatch grep grep -r --include='*.swift' "$@" Tests); }
hits="$(tests_grep -nF '.wait(timeout:' | sort)"

if [[ -f "$allow" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    file="${line%%$'\t'*}"
    reason=""
    [[ "$line" == *$'\t'* ]] && reason="${line#*$'\t'}"
    entries+="$file"$'\n'
    if [[ -z "${reason//[[:space:]]/}" ]]; then
      problems+="$file: an allow entry with no reason"$'\n'
    elif ! grep -qxF "$file" <(cut -d: -f1 <<<"$hits"); then
      problems+="$file: an allow entry for a file with no raw wait"$'\n'
    fi
  done <"$allow"
fi

while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  file="${hit%%:*}"
  grep -qxF "$file" <<<"$entries" || problems+="$file:$(cut -d: -f2 <<<"$hit"): a raw .wait(timeout: with no allow entry; hold product work with Gate"$'\n'
done <<<"$hits"

quarantined="$(tests_grep -nF '"quarantine:' | sort)"
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  grep -qw 'FLAKE' <<<"${hit#*:*:}" || problems+="${hit%%:*}:$(cut -d: -f2 <<<"$hit"): a \"quarantine: marker with no FLAKE word; name its FLAKE item"$'\n'
done <<<"$quarantined"

intermittent="$(tests_grep -lF 'isIntermittent: true' | sort)"
while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  grep -F '"quarantine:' "$root/$file" | grep -qw 'FLAKE' ||
    problems+="$file: an isIntermittent: true with no \"quarantine: marker that has a FLAKE word; name its FLAKE item"$'\n'
done <<<"$intermittent"

# The debug-only member gate. Three passes, each over a short file list from `git grep`, so a tree
# with no match reads no file (awk must not read standard input):
# 1. The Sources/ files with an `#if ... DEBUG` line: the names declared at type level in a debug branch.
# 2. The Tests/ files that name one: each use outside a debug branch.
# 3. The Sources/ files that declare a name that pass 2 kept: a name with a release declaration is dropped.
awk_lib='
function isdebug(c) {
  return (c ~ /^DEBUG$/ || (c ~ /(^|[^!A-Za-z_])DEBUG([^A-Za-z_]|$)/ && c ~ /&&/ && c !~ /\|\|/))
}
function directive(line,   c) {
  if (line ~ /^[ \t]*#if[ \t]/) {
    c = line; sub(/^[ \t]*#if[ \t]+/, "", c); sub(/[ \t]*\/\/.*$/, "", c)
    n++; br[n] = isdebug(c); inv[n] = (c ~ /^!DEBUG$/); return 1
  }
  if (line ~ /^[ \t]*#elseif[ \t]/) {
    c = line; sub(/^[ \t]*#elseif[ \t]+/, "", c); sub(/[ \t]*\/\/.*$/, "", c)
    br[n] = isdebug(c); inv[n] = 0; return 1
  }
  if (line ~ /^[ \t]*#else/) { br[n] = inv[n]; inv[n] = 0; return 1 }
  if (line ~ /^[ \t]*#endif/) { n--; return 1 }
  return 0
}
function indebug(   i) { for (i = 1; i <= n; i++) if (br[i]) return 1; return 0 }
'
awk_decl='
function strip(s) {
  if (index(s, "\"")) gsub(/"([^"\\]|\\.)*"/, "\"\"", s)
  if (index(s, "/")) {
    while (match(s, /[(,=#][ \t]*\/([^\/ \t*\\]|\\.)([^\/\\]|\\.)*\//)) s = substr(s, 1, RSTART) "\"\"" substr(s, RSTART + RLENGTH)
    sub(/\/\/.*$/, "", s)
  }
  return s
}
BEGIN {
  k = split(names, N, " ")
  for (i = 1; i <= k; i++) { K[N[i]] = 1; relre = relre (i > 1 ? "|" : "") N[i] }
  relre = "(var|let|func|case)[ \t]+(" relre ")([^A-Za-z0-9_]|$)"
}
FNR == 1 { n = 0; depth = 0; head = "" }
{
  if (index($0, "#") && $0 ~ /^[ \t]*#(if|else|endif)/ && directive($0)) { head = ""; next }
  hasb = index($0, "{") || index($0, "}")
  t = strip($0)
  prev = head
  head = (t ~ /^[ \t]*$|[{}][ \t]*$/) ? "" : head " " t
  if (want == "rel" && !hasb && $0 !~ relre) next
  top = depth == 0 ? "type" : stack[depth]
  if (top == "type" && (want == "dbg" || $0 ~ relre) && t !~ /(^|[ \t])(private|fileprivate)[ \t]/ &&
      match(t, /^[ \t]*((@[A-Za-z_]+|public|internal|package|private\(set\)|fileprivate\(set\)|static|class|final|nonisolated|mutating|override|lazy|weak|unowned|dynamic)[ \t]+)*(var|let|func|case)[ \t]+[A-Za-z_][A-Za-z_0-9]*/)) {
    d = substr(t, RSTART, RLENGTH); sub(/.*[ \t]/, "", d)
    if (want == "dbg" ? indebug() : (!indebug() && (d in K))) out[d] = 1
  }
  if (hasb) {
    b = t; gsub(/[^{}]/, "", b)
    u = (t ~ /^[ \t]*\{[ \t]*$/) ? prev : t
    sub(/(^|[ \t])class[ \t]+(func|var|let|subscript)([^A-Za-z_0-9]|$)/, " ", u)
    kind = (u ~ /(^|[ \t])(struct|class|enum|actor|extension|protocol)[ \t]+[A-Za-z_]/) ? "type" : "code"
    for (i = 1; i <= length(b); i++) { if (substr(b, i, 1) == "{") stack[++depth] = kind; else if (depth > 0) depth-- }
  }
}
END { for (d in out) print d }
'
awk_use='
function nocomment(s,   p, q, head) {
  p = 0
  while ((q = index(substr(s, p + 1), "//")) > 0) {
    p += q; head = substr(s, 1, p - 1)
    if (gsub(/"/, "\"", head) % 2 == 0) return substr(s, 1, p - 1)
  }
  return s
}
BEGIN {
  k = split(names, N, " "); re = "\\.(" N[1]
  for (j = 2; j <= k; j++) re = re "|" N[j]
  re = re ")([^A-Za-z_0-9]|$)"
}
FNR == 1 { n = 0 }
{
  if (index($0, "#") && $0 ~ /^[ \t]*#(if|else|endif)/ && directive($0)) next
  if ($0 !~ re || indebug()) next
  t = $0; gsub(/"([^"\\]|\\[^(])*"/, "\"\"", t); t = nocomment(t)
  for (j = 1; j <= k; j++) if (t ~ ("\\." N[j] "([^A-Za-z_0-9]|$)")) print FILENAME ":" FNR ":" N[j]
}
'
# debug_list <extended regex> <folder>: the Swift files under <folder> with a match, one per line.
debug_list() { nomatch 'git grep' env LC_ALL=C git -C "$root" grep --no-index -lE "$1" -- "$2/*.swift" | sort; }
# debug_awk <file list> <awk argument>...: awk over the listed files, which are relative to the root.
debug_awk() {
  local list="$1" files=() file s
  shift
  while IFS= read -r file; do
    if [[ -n "$file" ]]; then files+=("$file"); fi
  done <<<"$list"
  [[ ${#files[@]} -gt 0 ]] || return 0
  (cd "$root" && LC_ALL=C awk "$@" "${files[@]}") || { s=$?; echo "check-waits: awk failed with status $s" >&2; return "$s"; }
}
debug_problems() {
  local list cand kept uses rel s
  list="$(debug_list '^[[:space:]]*#if[[:space:]].*DEBUG' Sources)" || return
  cand="$(debug_awk "$list" -v want=dbg "$awk_lib$awk_decl" | sort -u)" || return
  [[ -n "$cand" ]] || return 0
  list="$(debug_list "\\.($(paste -sd'|' - <<<"$cand"))([^A-Za-z0-9_]|\$)" Tests)" || return
  uses="$(debug_awk "$list" -v names="$(tr '\n' ' ' <<<"$cand")" "$awk_lib$awk_use")" || return
  [[ -n "$uses" ]] || return 0
  kept="$(cut -d: -f3 <<<"$uses" | sort -u)"
  list="$(debug_list "(var|let|func|case)[[:space:]]+($(paste -sd'|' - <<<"$kept"))([^A-Za-z0-9_]|\$)" Sources)" || return
  rel="$(debug_awk "$list" -v want=rel -v names="$(tr '\n' ' ' <<<"$kept")" "$awk_lib$awk_decl" | sort -u)" || return
  awk -F: -v released="$(tr '\n' ' ' <<<"$rel")" '
    BEGIN { k = split(released, R, " "); for (i = 1; i <= k; i++) skip[R[i]] = 1 }
    !($3 in skip) { print $1 ":" $2 ": ." $3 " is declared only under #if DEBUG; put the test in #if DEBUG (tdd skill, Guardrails)" }
  ' <<<"$uses" || { s=$?; echo "check-waits: awk failed with status $s" >&2; return "$s"; }
}

# r1: the wall-clock terms of a Swift file: a sleep, a clock read, a timer, or the real-time pace.
r1=('Task.sleep' 'Thread.sleep' 'usleep(' 'ContinuousClock.now' 'DispatchTime.now' 'asyncAfter' 'makeTimerSource' 'Timer.scheduled' 'pace: .realTime')
# The refused markers, each counted on its own in the Tests/ total.
markers=(isIntermittent '"quarantine:' '.disabled(')
# scan <commit, or - for the work tree>: one `git grep` for the r1 terms and the markers in all Swift
# files under Tests/ and Sources/, as "<path>:<line>:<text>". The work tree read includes untracked files.
# A fixed-string term is much faster than the same terms in one -E regex.
scan() {
  local at="$1" args=() term
  for term in "${r1[@]}" "${markers[@]}"; do args+=(-e "$term"); done
  if [[ "$at" == - ]]; then
    nomatch 'git grep' git -C "$root" grep -anF --untracked "${args[@]}" -- 'Tests/*.swift' 'Sources/*.swift'
  else
    nomatch 'git grep' git -C "$root" grep -anF "${args[@]}" "$at" -- 'Tests/*.swift' 'Sources/*.swift' | sed "s|^$at:||"
  fi
}
# tally <r1 or total> <scan output>: for r1, "<path>:<count>" of the lines with an r1 term, for each
# file with a match; for total, the number of lines under Tests/ with each marker, on one line.
tally() {
  LC_ALL=C awk -v want="$1" -v r1="$(printf '%s\t' "${r1[@]}")" -v mk="$(printf '%s\t' "${markers[@]}")" '
    BEGIN { nr = split(r1, R, "\t"); nm = split(mk, M, "\t"); nr--; nm-- }
    {
      i = index($0, ":"); path = substr($0, 1, i - 1); rest = substr($0, i + 1)
      text = substr(rest, index(rest, ":") + 1)
      if (want == "r1") {
        for (k = 1; k <= nr; k++) if (index(text, R[k])) { n[path]++; if (!(path in seen)) { seen[path] = 1; order[++files] = path } break }
      } else if (substr(path, 1, 6) == "Tests/") {
        for (k = 1; k <= nm; k++) if (index(text, M[k])) total[k]++
      }
    }
    END {
      if (want == "r1") for (f = 1; f <= files; f++) print order[f] ":" n[order[f]]
      else { for (k = 1; k <= nm; k++) line = line (k > 1 ? " " : "") (total[k] + 0); print line }
    }' <<<"$2"
}
# rises <reference counts> <work tree counts>: "<path>:<now>:<before>" for each file with more.
rises() {
  awk -F: 'FILENAME == ARGV[1] { before[$1] = $2; next } $2 + 0 > before[$1] + 0 { print $1 ":" $2 ":" before[$1] + 0 }' \
    <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

swift_changed=outside-a-work-tree swift_new=""
if [[ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
  if [[ -n "${BASE:-}" ]]; then
    ref="$(git -C "$root" merge-base "$BASE" HEAD 2>/dev/null)" || { echo "check-waits: no merge base of $BASE and HEAD" >&2; exit 2; }
    label="merge-base $BASE"
  elif ref="$(git -C "$root" rev-parse -q --verify HEAD)"; then
    label=HEAD
  else
    ref="$(git -C "$root" hash-object -t tree /dev/null)"
    label="the empty tree"
  fi
  swift_changed="$(git -C "$root" diff --no-renames --name-only "$ref" -- 'Sources/*.swift' 'Tests/*.swift')"
  swift_new="$(git -C "$root" ls-files --others --exclude-standard -- 'Sources/*.swift' 'Tests/*.swift')"
  mode=fail caps=""
  counts="$root/scripts/check-waits.counts"
  if [[ -f "$counts" ]]; then
    first="$(awk '!/^[[:space:]]*(#|$)/ { print; exit }' "$counts")"
    read -r word value rest <<<"$first"
    if [[ "$word" == mode ]]; then
      if [[ ("$value" == warn || "$value" == fail) && -z "$rest" ]]; then
        mode="$value"
        caps="$(awk '!/^[[:space:]]*(#|$)/ { if (seen++) print }' "$counts")"
      else
        echo "check-waits: scripts/check-waits.counts: the mode is warn or fail" >&2
        exit 1
      fi
    fi
  fi

  scan_now="$(scan -)"
  scan_ref="$(scan "$ref")"
  now_r1="$(tally r1 "$scan_now")"
  ref_r1="$(tally r1 "$scan_ref")"
  gate=""
  while IFS=: read -r file n before; do
    [[ -n "$file" ]] || continue
    cap="$(awk -F'\t' -v f="$file" '$1 == f && $2 ~ /^[0-9]+$/ { print $2; exit }' <<<"$caps")"
    [[ -z "$cap" || $((10#$n)) -gt $((10#$cap)) ]] || continue
    gate+="$file: $n wall-clock lines, $before at $label; add $file<TAB>$n<TAB><reason> to scripts/check-waits.counts"$'\n'
  done < <(rises "$ref_r1" "$now_r1")
  while IFS=$'\t' read -r cpath ccap creason; do
    [[ -n "$cpath" ]] || continue
    if [[ -z "${creason//[[:space:]]/}" ]]; then
      gate+="$cpath: a cap line with no reason"$'\n'
    elif [[ ! "$ccap" =~ ^[0-9]+$ ]]; then
      gate+="$cpath: the cap $ccap is not a whole number"$'\n'
    else
      n="$(awk -F: -v f="$cpath" '$1 == f { print $2; exit }' <<<"$now_r1")"
      n="${n:-0}"
      [[ $((10#$ccap)) -le $((10#$n)) ]] ||
        gate+="$cpath: the cap $ccap is over its count $n; lower the cap to $n or remove the line"$'\n'
    fi
  done <<<"$caps"
  if [[ -n "$gate" ]]; then
    if [[ "$mode" == warn ]]; then sed 's/^/check-waits: warning: /' <<<"${gate%$'\n'}" >&2; else problems+="$gate"; fi
  fi

  # The Tests/ total of each refused marker against the reference: a move of a line is no rise.
  read -r -a now_totals <<<"$(tally total "$scan_now")"
  read -r -a ref_totals <<<"$(tally total "$scan_ref")"
  for i in "${!markers[@]}"; do
    marker="${markers[$i]}" n="${now_totals[$i]}" before="${ref_totals[$i]}"
    advice='a flaky test moves to the real-time tier (flake-triage.md, Time box)'
    [[ "$marker" != '.disabled(' ]] ||
      advice='a new disabled test; move a flaky test to the real-time tier (flake-triage.md), or gate a test with .enabled(if:)'
    [[ $n -le $before ]] || problems+="Tests/: $n $marker lines, $before at $label; $advice"$'\n'
  done
fi

if [[ -n "$swift_changed$swift_new" ]]; then
  debug_found="$(debug_problems)"
  [[ -z "$debug_found" ]] || problems+="$debug_found"$'\n'
fi

problems="$(sed '/^$/d' <<<"$problems")"
[[ -z "$problems" ]] || { sed 's/^/check-waits: /' <<<"$problems" >&2; exit 1; }
