#!/bin/bash
# Print the change classes of the changed paths, the make targets that they need, and the risk.
# This script owns the path table and the risk floor (decision 0028). Docs name it, not the table.
# In the git modes, the content of a change can also give the class: a change of only comment
# lines is class comments, and a Makefile change of only comment lines is class docs (comment_only).
# Usage: scripts/check-changed.sh               HEAD against the working tree and untracked files; the local targets
#        scripts/check-changed.sh <base>        also the commits since <base>; the targets before the push.
#          After a pass stamp S of <base> (check-stamp.sh read), it prints `stamp: delta <S>` first,
#          and the targets of the paths changed since S only; classes and risk stay those of <base>.
#        scripts/check-changed.sh --paths [--push] <<<$'<path>\n<path>'   the paths from stdin only
#        scripts/check-changed.sh --floor       print the risk floor paths
#        scripts/check-changed.sh --wait-load <targets>   wait for a normal load and no test of another tree
# `make check-changed [BASE=<base>]` runs the targets. It fails closed: a git error exits nonzero.
# With FILTER (test names, for the tdd loop of a slice), the local target test becomes
# test-filter. FILTER before the push exits 1: the push runs the full targets.
set -euo pipefail

# The risk floor. A change to one of these paths prints `risk: yes`, unless the change is
# comment-only. A path that ends in / is a folder. check-changed.test.sh fails when a floor path does not exist.
floor="Sources/DirigibleAudio/ Sources/DirigibleCore/SessionReader.swift Sources/DirigibleCore/SessionWriter.swift Sources/DirigibleCore/PackageLock.swift"

class_of() {
    local f
    for f in $floor; do
        case "$1" in "$f"*) [[ "$f" == */ || "$1" == "$f" ]] && { echo sources-risk; return; } ;; esac
    done
    case "$1" in
        Makefile | Support/* | scripts/bundle.sh | scripts/sign-app.sh | scripts/guide-html.swift | scripts/dmg.sh | scripts/test-dmg.sh | scripts/icon.sh | \
            Tests/DirigibleTests/AppBundleTests.swift | Tests/DirigibleTests/DiskImageTests.swift) echo bundle ;;
        scripts/* | .claude/hooks/* | .claude/skills/*/scripts/* | .claude/workflows/* | .claude/settings.json | .githooks/*) echo tooling ;;
        docs/* | README.md | AGENTS.md | CLAUDE.md | CODING_STANDARDS.md | .claude/skills/*.md | .claude/agents/*) echo docs ;;
        Tests/*) echo tests ;;
        Sources/*) echo sources ;;
        *) echo build ;;
    esac
}

# The Swift text with no blank line and no // line. A line with /* or */ stays: a block comment
# can end in a // line.
swift_code() { awk '{ t = $0; sub(/^[ \t]+/, "", t) } t == "" { next } t ~ /^\/\// && t !~ /\/\*|\*\// { next } { print }'; }

# The Makefile text with no blank line and no comment line that make skips: a line that starts
# with # after spaces (a tab makes a recipe line), with no $ and no \ at the end. A line after a
# line that ends in \ stays.
make_code() { awk '{ c = prev; prev = /\\$/ } !c && /^ *$/ { next } !c && /^ *#/ && !/\$/ && !/\\$/ { next } { print }'; }

# A change of only comment lines: the text at $from and the file on disk are equal after the
# filter of the file. A new, deleted, or untracked file is not. A file with a line that matches
# the guard keeps its path class.
comment_only() {
    local old filter guard
    [[ -n "$from" && -f "$1" ]] || return 1
    case "$1" in
        # ponytail: a // line in a multi-line string is text, so a file with """ keeps its path class.
        Sources/*.swift | Tests/*.swift) filter=swift_code guard='"""' ;;
        # A # line in a define body is value text.
        Makefile) filter=make_code guard='(^|[[:space:]])define([[:space:]]|$)' ;;
        *) return 1 ;;
    esac
    old="$(git show "$from:$1" 2>/dev/null)" || return 1
    ! grep -qE "$guard" <<<"$old" && ! grep -qE "$guard" "$1" || return 1
    [[ "$($filter <<<"$old")" == "$($filter <"$1")" ]]
}

# The targets of a class: the local column (push=0) or the before-the-push column (push=1).
targets_of() {
    case "$1:$push" in
        docs:*) echo check-docs ;;
        comments:* | tooling:*) echo check-fast ;;
        tests:0 | sources:0 | sources-risk:0) echo test ;;
        bundle:0 | build:0) echo check ;;
        tests:1 | sources:1 | sources-risk:1 | build:1) echo check ;;
        bundle:1) echo check test-dmg ;;
    esac
}

# A build or a test in another worktree makes timing tests fail (DLV-157). Before a target other
# than check-docs and check-fast, wait until the 1-minute load is under CHECK_LOAD_MAX (default:
# the core count) and no swiftpm-testing-helper of another tree runs (its command line does not
# hold <root>/.build/). Read both each 10 s. After CHECK_LOAD_WAIT seconds (default 300, so the
# wait and the tests of a slice fit in one 600 s Bash call), run the tests anyway. The lines go
# to stderr.
wait_load() {
    local rest=" $* " t max load other why stop root waited=0 limit="${CHECK_LOAD_WAIT:-300}"
    for t in check-docs check-fast none; do rest="${rest// $t / }"; done
    [[ -n "${rest// /}" ]] || return 0
    max="${CHECK_LOAD_MAX:-$(sysctl -n hw.ncpu)}"
    root="$(git rev-parse --show-toplevel)"
    while :; do
        load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
        # pgrep and grep exit 1 with no match, so the pipeline stays in a condition (set -e).
        if other="$(pgrep -lf '/swiftpm-testing-helper ' | grep -vF "$root/.build/")"; then
            # The command line names the tree of the helper, so a stale helper can be stopped.
            other="${other%%$'\n'*}"
            other="pid ${other/ /: }"
            why="a test of another tree runs ($other)" stop="a test of another tree runs after $waited s ($other)"
        elif awk -v l="$load" -v m="$max" 'BEGIN { exit !(l < m) }'; then
            echo "check-changed: load $load, under $max: run the tests" >&2
            return 0
        else
            why="load $load, not under $max (CHECK_LOAD_MAX)" stop="load $load after $waited s, not under $max"
        fi
        if ((waited >= limit)); then
            echo "check-changed: $stop: run the tests" >&2
            return 0
        fi
        echo "check-changed: $why: wait 10 s, up to $limit s (CHECK_LOAD_WAIT)" >&2
        sleep 10
        waited=$((waited + 10))
    done
}

push=0 mode=git base="" from=""
case "${1:-}" in
    --floor) printf '%s\n' $floor; exit 0 ;;
    --wait-load) shift; wait_load "$@"; exit 0 ;;
    --paths)
        mode=stdin
        [[ "${2:-}" == --push ]] && push=1
        if (($# > push + 1)); then
            echo "usage: scripts/check-changed.sh --paths [--push] <<<\$'<path>\\n<path>' (the paths come from stdin)" >&2
            exit 2
        fi
        ;;
    "") ;;
    *) base="$1" push=1 ;;
esac

if [[ -n "${FILTER:-}" && $push == 1 ]]; then
    echo "check-changed: FILTER is for the tdd loop of a slice; the push check runs with no FILTER" >&2
    exit 1
fi

if [[ $mode == stdin ]]; then
    paths="$(cat)"
else
    cd "$(git rev-parse --show-toplevel)"
    # --no-renames lists the old path of a move too, so a moved floor file stays risk: yes.
    committed=""
    [[ -n "$base" ]] && committed="$(git diff --name-only --no-renames "$base...HEAD")"
    worktree="$(git diff --name-only --no-renames HEAD)"
    untracked="$(git ls-files --others --exclude-standard)"
    paths="$committed"$'\n'"$worktree"$'\n'"$untracked"
    # The old side of the content check: the fork point of the branch, or HEAD.
    from=HEAD
    [[ -n "$base" ]] && from="$(git merge-base "$base" HEAD)"
fi
paths="$(grep -v '^$' <<<"$paths" | sort -u || true)"
if [[ -z "$paths" && $push == 1 ]]; then
    echo "check-changed: no changed paths against ${base:-the paths of stdin}" >&2
    exit 1
fi

# classify <paths>: sets found (the classes) and kept (the paths that keep their path class; the
# push rule for test-slow-push reads only them). comment_only reads the old side at $from.
classify() {
    local p c
    found=" " kept=""
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if comment_only "$p"; then
            c=comments
            [[ $p == Makefile ]] && c=docs
        else
            c="$(class_of "$p")" kept+="$p"$'\n'
        fi
        [[ "$found" == *" $c "* ]] || found+="$c "
    done <<<"$1"
}
classify "$paths"

classes="" risk=no
for c in docs comments tooling tests sources sources-risk bundle build; do
    [[ "$found" == *" $c "* ]] || continue
    classes+=" $c"
    [[ $c == sources-risk ]] && risk=yes
done

# The delta: after a pass stamp S of this base, only the paths changed since S (the working tree
# too) pick the targets, with the content against S.
if [[ -n "$base" ]] && stamp="$("$(dirname "$0")/check-stamp.sh" read "$base")"; then
    from="${stamp%% *}"
    echo "stamp: delta $from"
    classify "$(git diff --name-only --no-renames "$from")"$'\n'"$untracked"
fi
wanted=" "
for c in $found; do
    for t in $(targets_of "$c"); do wanted+="$t "; done
done

# Before the push, test-slow-push runs for risk, a changed slow test (a file with the gate of the
# Makefile), or a Makefile change (it owns the recipe). A push with Swift tests (check) also runs
# it when no slow run passed today on this clone: the recipe writes the date file. A changed file
# of PUSH_SKIP (the Makefile line) adds test-slow-push and the word PUSH_RUN=<names> (sorted, joined
# with commas) after the targets: the recipe then also runs the slow tests of those files.
run=""
if [[ $push == 1 ]]; then
    slow=no
    skip="$(sed -n 's/^PUSH_SKIP = //p' "$(dirname "$0")/../Makefile")"
    [[ "$found" == *" sources-risk "* ]] && slow=yes
    grep -qx Makefile <<<"$kept" && slow=yes
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    while IFS= read -r p; do
        [[ $p == Tests/* ]] && grep -qF 'environment["DIRIGIBLE_SLOW_TESTS"]' "$root/$p" 2>/dev/null && slow=yes
        for n in $skip; do [[ $p == Tests/*/"$n.swift" ]] && slow=yes run+="$n"$'\n'; done
    done <<<"$kept"
    if [[ "$wanted" == *" check "* ]]; then
        date_file="$(git rev-parse --git-common-dir 2>/dev/null)/dirigible-slow-date" || date_file=/dev/null
        [[ "$(cat "$date_file" 2>/dev/null)" == "$(date +%F)" ]] || slow=yes
    fi
    [[ $slow == yes ]] && wanted+="test-slow-push "
fi

# check runs check-docs, check-fast, and test; check-fast runs check-docs. Drop what another target runs.
targets=""
for t in check-docs check-fast test check test-slow-push test-dmg; do
    [[ "$wanted" == *" $t "* ]] || continue
    case "$t" in check-docs | check-fast | test) [[ "$wanted" == *" check "* ]] && continue ;; esac
    [[ $t == check-docs && "$wanted" == *" check-fast "* ]] && continue
    targets+=" $t"
done

[[ -n "$run" ]] && targets+=" PUSH_RUN=$(sort -u <<<"${run%$'\n'}" | paste -sd, -)"
classes="${classes# }" targets="${targets# }"
[[ -n "${FILTER:-}" && " $targets " == *" test "* ]] && targets="$(sed -E 's/(^| )test( |$)/\1test-filter\2/' <<<"$targets")"
echo "classes: ${classes:-none}"
echo "targets: ${targets:-none}"
echo "risk: $risk"
