#!/bin/bash
# Put an annotated release tag v<version> on a commit of origin/main and push it
# (docs/requirements/releases.md, Versions). User rule 2026-10-13: a lower version never ships.
# Usage: scripts/tag-release.sh <version> <commit> <message>
# - <version> is 3 or 4 numbers with dots, with no v (0.3.9, 0.3.8.2); else it exits 2.
# - It exits 1 with no tag for a version that is not higher (sort -V) than the newest v<digit> tag
#   of origin, for a commit that is not on origin/main, for a commit that does not hold the
#   commit of the newest tag (a higher version holds the code of each lower one), and for a commit
#   that already has a v<digit> tag on origin (one commit has one version). Only the tags of
#   origin decide a refusal: it reads them with git ls-remote (the peeled refs for the tag of the
#   commit), and its tag fetch has --force, so a tag of origin replaces a local tag of the same
#   name. A local tag v<version> that origin does not have is a stale try: the script removes it
#   and goes on, so no git tag -d by hand is needed (the guardrail hook blocks it).
# - The tag is annotated, because scripts/version.sh ignores a lightweight tag. Before the push,
#   git describe --exact-match of the commit must print the tag. When that check or the push
#   fails, a trap removes the local tag, so a retry of the same version works.
# - A version 0.<r>.<n> with r of 4 or more needs a State in docs/requirements/features.md at the
#   commit that is done in Release <r> with n in its run list; else it exits 1. A version with
#   four numbers needs no row. After each tag, it prints one reminder: post the DMG to the
#   testers, and after the last run of a release, post the release summary.
# scripts/tag-release.test.sh tests it (scripts/bundle.test.sh runs the test).
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: scripts/tag-release.sh <version> <commit> <message>" >&2; exit 2; }
version="$1" commit="$2" message="$3"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]] ||
    { echo "tag-release: bad version $version (3 or 4 numbers with dots, no v)" >&2; exit 2; }

git fetch -q --tags --force origin
newest="$(git ls-remote --tags --refs origin | sed -n 's|.*refs/tags/v\([0-9][0-9.]*\)$|\1|p' | sort -V | tail -1)"
if [[ -n "$newest" ]]; then
    if [[ "$newest" == "$version" || "$(printf '%s\n%s\n' "$newest" "$version" | sort -V | tail -1)" != "$version" ]]; then
        echo "tag-release: $version is not higher than the newest tag v$newest of origin; a run that lands late takes the next fourth number on v$newest" >&2
        exit 1
    fi
fi
git merge-base --is-ancestor "$commit" origin/main ||
    { echo "tag-release: $commit is not on origin/main" >&2; exit 1; }
[[ -z "$newest" ]] || git merge-base --is-ancestor "refs/tags/v$newest^{commit}" "$commit" ||
    { echo "tag-release: $commit does not hold v$newest; tag a commit after it" >&2; exit 1; }
sha="$(git rev-parse --verify "$commit^{commit}")"
held="$(git ls-remote --tags origin | awk -v c="$sha" '$1 == c && $2 ~ /^refs\/tags\/v[0-9].*\^\{\}$/ { sub(/^refs\/tags\//, "", $2); sub(/\^\{\}$/, "", $2); print $2; exit }')"
[[ -z "$held" ]] || { echo "tag-release: $commit already has the tag $held on origin; one commit has one version" >&2; exit 1; }
if [[ "$version" =~ ^0\.([4-9]|[1-9][0-9]+)\.([0-9]+)$ ]]; then
    r="${BASH_REMATCH[1]}" n="${BASH_REMATCH[2]}"
    # A done State is `done, ` and parts `Release <r> run <n>` or `Release <r> runs <list>`, joined by
    # ` and Release `. A `; Later:` part and each (note) are cut first.
    git show "$commit:docs/requirements/features.md" 2>/dev/null | awk -F'|' -v r="$r" -v n="$n" '
        /^\| F[0-9]+ \|/ { s = $5; gsub(/^ +| +$/, "", s) }
        !/^\| F[0-9]+ \|/ || s !~ /^done, / { next }
        {
            sub(/; Later:.*/, "", s); gsub(/ [(][^)]*[)]/, "", s); sub(/^done, /, "", s)
            k = split(s, part, / and Release /)
            for (i = 1; i <= k; i++) {
                p = part[i]; sub(/^Release /, "", p)
                if (p !~ ("^" r " runs? ")) continue
                sub(/^[0-9]+ runs? /, "", p); gsub(/ and /, ", ", p)
                m = split(p, run, /, /)
                for (j = 1; j <= m; j++) if (run[j] == n) found = 1
            }
        }
        END { exit !found }' ||
        { echo "tag-release: no features.md row of $commit is done in Release $r run $n" >&2; exit 1; }
fi
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    git tag -d "v$version" >/dev/null
    echo "tag-release: removed the local tag v$version that origin does not have"
fi

made=""
trap '[[ -z "$made" ]] || git tag -d "v$version" >/dev/null 2>&1' EXIT
git tag -a "v$version" -m "$message" "$commit"
made=1
[[ "$(git describe --match 'v[0-9]*' --exact-match "$commit" 2>/dev/null)" == "v$version" ]] ||
    { echo "tag-release: git describe does not print v$version for $commit (another tag on the commit?)" >&2; exit 1; }
git push -q origin "refs/tags/v$version"
made=""
echo "tagged v$version on $(git rev-parse --short "$commit") (newest before: ${newest:-none})"
echo "tag-release: post the DMG to the testers; after the last run of a release, post the release summary"
