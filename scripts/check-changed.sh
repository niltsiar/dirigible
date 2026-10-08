#!/bin/bash
# Print the change classes of the changed paths, the make targets that they need, and the risk.
# This script owns the path table and the risk floor (decision 0028). Docs name it, not the table.
# Usage: scripts/check-changed.sh               HEAD against the working tree and untracked files; the local targets
#        scripts/check-changed.sh <base>        also the commits since <base>; the targets before the push
#        scripts/check-changed.sh --paths [--push]   the paths from stdin
#        scripts/check-changed.sh --floor       print the risk floor paths
#        scripts/check-changed.sh --wait-load <targets>   wait for a normal load and no test of another tree
# `make check-changed [BASE=<base>]` runs the targets. It fails closed: a git error exits nonzero.
# With FILTER (test names, for the tdd loop of a slice), the local target test becomes
# test-filter. FILTER before the push exits 1: the push runs the full targets.
set -euo pipefail

# The risk floor. A change to one of these paths always prints `risk: yes`. A path that ends
# in / is a folder. check-changed.test.sh fails when a floor path does not exist.
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
        docs/* | README.md | AGENTS.md | CLAUDE.md | .claude/skills/*.md | .claude/agents/*) echo docs ;;
        Tests/*) echo tests ;;
        Sources/*) echo sources ;;
        *) echo build ;;
    esac
}

# The targets of a class: the local column (push=0) or the before-the-push column (push=1).
targets_of() {
    case "$1:$push" in
        docs:*) echo check-docs ;;
        tooling:*) echo check-fast ;;
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

push=0 mode=git base=""
case "${1:-}" in
    --floor) printf '%s\n' $floor; exit 0 ;;
    --wait-load) shift; wait_load "$@"; exit 0 ;;
    --paths) mode=stdin; [[ "${2:-}" == --push ]] && push=1 ;;
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
fi
paths="$(grep -v '^$' <<<"$paths" | sort -u || true)"
if [[ -z "$paths" && $push == 1 ]]; then
    echo "check-changed: no changed paths against ${base:-the paths of stdin}" >&2
    exit 1
fi

found=" "
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    c="$(class_of "$p")"
    [[ "$found" == *" $c "* ]] || found+="$c "
done <<<"$paths"

classes="" wanted=" " risk=no
for c in docs tooling tests sources sources-risk bundle build; do
    [[ "$found" == *" $c "* ]] || continue
    classes+=" $c"
    [[ $c == sources-risk ]] && risk=yes
    for t in $(targets_of "$c"); do wanted+="$t "; done
done

# Before the push, test-slow-push runs for risk, a changed slow test (a file with the gate of the
# Makefile), or a Makefile change (it owns the recipe). A push with Swift tests (check) also runs
# it when no slow run passed today on this clone: the recipe writes the date file. A changed file
# of PUSH_SKIP (the Makefile line) runs test-slow, the full suite, in its place.
if [[ $push == 1 ]]; then
    slow=no full=no
    skip="$(sed -n 's/^PUSH_SKIP = //p' "$(dirname "$0")/../Makefile")"
    [[ $risk == yes ]] && slow=yes
    grep -qx Makefile <<<"$paths" && slow=yes
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    while IFS= read -r p; do
        [[ $p == Tests/* ]] && grep -qF 'environment["DIRIGIBLE_SLOW_TESTS"]' "$root/$p" 2>/dev/null && slow=yes
        for n in $skip; do [[ $p == Tests/*/"$n.swift" ]] && slow=yes full=yes; done
    done <<<"$paths"
    if [[ "$wanted" == *" check "* ]]; then
        date_file="$(git rev-parse --git-common-dir 2>/dev/null)/dirigible-slow-date" || date_file=/dev/null
        [[ "$(cat "$date_file" 2>/dev/null)" == "$(date +%F)" ]] || slow=yes
    fi
    if [[ $full == yes ]]; then wanted+="test-slow "; elif [[ $slow == yes ]]; then wanted+="test-slow-push "; fi
fi

# check runs check-docs, check-fast, and test; check-fast runs check-docs. Drop what another target runs.
targets=""
for t in check-docs check-fast test check test-slow test-slow-push test-dmg; do
    [[ "$wanted" == *" $t "* ]] || continue
    case "$t" in check-docs | check-fast | test) [[ "$wanted" == *" check "* ]] && continue ;; esac
    [[ $t == check-docs && "$wanted" == *" check-fast "* ]] && continue
    targets+=" $t"
done

classes="${classes# }" targets="${targets# }"
[[ -n "${FILTER:-}" && " $targets " == *" test "* ]] && targets="$(sed -E 's/(^| )test( |$)/\1test-filter\2/' <<<"$targets")"
echo "classes: ${classes:-none}"
echo "targets: ${targets:-none}"
echo "risk: $risk"
