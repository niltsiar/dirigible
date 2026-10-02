#!/bin/bash
# Print the change classes of the changed paths, the make targets that they need, and the risk.
# This script owns the path table and the risk floor (decision 0028). Docs name it, not the table.
# Usage: scripts/check-changed.sh               HEAD against the working tree and untracked files; the local targets
#        scripts/check-changed.sh <base>        also the commits since <base>; the targets before the push
#        scripts/check-changed.sh --paths [--push]   the paths from stdin
#        scripts/check-changed.sh --floor       print the risk floor paths
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
        Makefile | Support/* | scripts/bundle.sh | scripts/dmg.sh | scripts/test-dmg.sh | scripts/icon.sh | \
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

push=0 mode=git base=""
case "${1:-}" in
    --floor) printf '%s\n' $floor; exit 0 ;;
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

# Before the push, test-slow runs for risk, a changed slow test (a file with the gate of the
# Makefile), or a Makefile change (it owns the recipe). A push with Swift tests (check) also runs
# it when no `make test-slow` passed today on this clone: the recipe writes the date file.
if [[ $push == 1 ]]; then
    slow=no
    [[ $risk == yes ]] && slow=yes
    grep -qx Makefile <<<"$paths" && slow=yes
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    while IFS= read -r p; do
        [[ $p == Tests/* ]] && grep -qF 'environment["DIRIGIBLE_SLOW_TESTS"]' "$root/$p" 2>/dev/null && slow=yes
    done <<<"$paths"
    if [[ "$wanted" == *" check "* ]]; then
        date_file="$(git rev-parse --git-common-dir 2>/dev/null)/dirigible-slow-date" || date_file=/dev/null
        [[ "$(cat "$date_file" 2>/dev/null)" == "$(date +%F)" ]] || slow=yes
    fi
    [[ $slow == yes ]] && wanted+="test-slow "
fi

# check runs check-docs, check-fast, and test; check-fast runs check-docs. Drop what another target runs.
targets=""
for t in check-docs check-fast test check test-slow test-dmg; do
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
