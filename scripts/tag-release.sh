#!/bin/bash
# Put an annotated release tag v<version> on a commit of origin/main and push it
# (docs/requirements/releases.md, Versions). User rule 2026-10-13: a lower version never ships.
# Usage: scripts/tag-release.sh <version> <commit> <message>
# - <version> is 3 or 4 numbers with dots, with no v (0.3.9, 0.3.8.2); else it exits 2.
# - It exits 1 with no tag for a version that is not higher (sort -V) than the newest v<digit> tag
#   of origin, for a commit that is not on origin/main, for a commit that does not hold the
#   commit of the newest tag (a higher version holds the code of each lower one), and for a commit
#   that already has a v<digit> tag (one commit has one version). It reads the
#   tags of origin with git ls-remote, so a local tag that origin does not have does not count.
# - The tag is annotated, because scripts/version.sh ignores a lightweight tag. Before the push,
#   git describe --exact-match of the commit must print the tag. When that check or the push
#   fails, a trap removes the local tag, so a retry of the same version works.
# scripts/tag-release.test.sh tests it (scripts/bundle.test.sh runs the test).
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: scripts/tag-release.sh <version> <commit> <message>" >&2; exit 2; }
version="$1" commit="$2" message="$3"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]] ||
    { echo "tag-release: bad version $version (3 or 4 numbers with dots, no v)" >&2; exit 2; }

git fetch -q --tags origin
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
held="$(git tag --points-at "$commit" --list 'v[0-9]*' | head -1)"
[[ -z "$held" ]] || { echo "tag-release: $commit already has the tag $held; one commit has one version" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$version" >/dev/null &&
    { echo "tag-release: a local tag v$version that origin does not have exists; remove it with git tag -d v$version, then run again" >&2; exit 1; }

made=""
trap '[[ -z "$made" ]] || git tag -d "v$version" >/dev/null 2>&1' EXIT
git tag -a "v$version" -m "$message" "$commit"
made=1
[[ "$(git describe --match 'v[0-9]*' --exact-match "$commit" 2>/dev/null)" == "v$version" ]] ||
    { echo "tag-release: git describe does not print v$version for $commit (another tag on the commit?)" >&2; exit 1; }
git push -q origin "refs/tags/v$version"
made=""
echo "tagged v$version on $(git rev-parse --short "$commit") (newest before: ${newest:-none})"
