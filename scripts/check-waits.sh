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
# a Swift file under Tests/ or Sources/ with more wall-clock lines (the regex r1 below, a comment
# line counts) than at the reference, and over its cap in scripts/check-waits.counts, fails. A
# counts line is `mode warn`, `mode fail`, or <path><TAB><cap><TAB><reason>. The first line that is
# no comment is the mode; with no file or no mode line, the mode is fail and no cap counts. In mode
# warn the count gate prints `check-waits: warning: ` lines and does not change the exit. A cap
# line with no reason, with no whole number, or over the count of its file is a count gate line
# too. More lines with `isIntermittent`, `"quarantine:`, or `.disabled(` (each counted on its own)
# in all Swift files under Tests/ than at the reference fails in each mode, with no cap: a flaky
# test moves to the real-time tier (flake-triage.md, Time box), and no commit adds a quarantine of
# any form. The gate compares the total, so a rename or a split of a file that keeps the lines passes.
# Usage: scripts/check-waits.sh [root]. `make check-slow-gates` runs it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
allow="$root/scripts/check-waits.allow"
problems=""
entries=""
hits="$(cd "$root" && { grep -rnF --include='*.swift' '.wait(timeout:' Tests 2>/dev/null || true; } | sort)"

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

while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  grep -qw 'FLAKE' <<<"${hit#*:*:}" || problems+="${hit%%:*}:$(cut -d: -f2 <<<"$hit"): a \"quarantine: marker with no FLAKE word; name its FLAKE item"$'\n'
done < <(cd "$root" && { grep -rnF --include='*.swift' '"quarantine:' Tests 2>/dev/null || true; } | sort)

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  grep -F '"quarantine:' "$root/$file" | grep -qw 'FLAKE' ||
    problems+="$file: an isIntermittent: true with no \"quarantine: marker that has a FLAKE word; name its FLAKE item"$'\n'
done < <(cd "$root" && { grep -rlF --include='*.swift' 'isIntermittent: true' Tests 2>/dev/null || true; } | sort)

# count_lines <commit, or - for the work tree> <-E or -F> <pattern> <pathspec>...: "<path>:<count>"
# for each file with a match. The work tree read includes untracked files.
count_lines() {
  local at="$1" kind="$2" pattern="$3"
  shift 3
  if [[ "$at" == - ]]; then
    git -C "$root" grep --untracked -c "$kind" -e "$pattern" -- "$@" || true
  else
    git -C "$root" grep -c "$kind" -e "$pattern" "$at" -- "$@" | sed "s|^$at:||" || true
  fi
}
# rises <reference counts> <work tree counts>: "<path>:<now>:<before>" for each file with more.
rises() {
  awk -F: 'FILENAME == ARGV[1] { before[$1] = $2; next } $2 + 0 > before[$1] + 0 { print $1 ":" $2 ":" before[$1] + 0 }' \
    <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

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

  # The regex r1 of a wall-clock term in a Swift file: a sleep, a clock read, a timer, or the real-time pace.
  r1='Task\.sleep|Thread\.sleep|usleep\(|ContinuousClock\.now|DispatchTime\.now|asyncAfter|makeTimerSource|Timer\.scheduled|pace: \.realTime'
  now_r1="$(count_lines - -E "$r1" 'Tests/*.swift' 'Sources/*.swift')"
  ref_r1="$(count_lines "$ref" -E "$r1" 'Tests/*.swift' 'Sources/*.swift')"
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
  total() { count_lines "$1" -F "$2" 'Tests/*.swift' | awk -F: '{ n += $NF } END { print n + 0 }'; }
  for marker in isIntermittent '"quarantine:' '.disabled('; do
    n="$(total - "$marker")" before="$(total "$ref" "$marker")"
    advice='a flaky test moves to the real-time tier (flake-triage.md, Time box)'
    [[ "$marker" != '.disabled(' ]] ||
      advice='a new disabled test; move a flaky test to the real-time tier (flake-triage.md), or gate a test with .enabled(if:)'
    [[ $n -le $before ]] || problems+="Tests/: $n $marker lines, $before at $label; $advice"$'\n'
  done
fi

problems="$(sed '/^$/d' <<<"$problems")"
[[ -z "$problems" ]] || { sed 's/^/check-waits: /' <<<"$problems" >&2; exit 1; }
