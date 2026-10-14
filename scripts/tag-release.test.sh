#!/bin/bash
# Check scripts/tag-release.sh against a bare origin in a temporary folder: it refuses a version
# that is not higher than the newest tag of origin (equal, lower, sort -V order), a commit off
# origin/main, a commit that does not hold the newest tag, and a bad version; a pass leaves an
# annotated tag on origin; a failed push leaves no local tag, and a retry passes.
# scripts/bundle.test.sh runs it, so make test-hooks runs it.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/tag-release.sh"
version_sh="$(dirname "$script")/version.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# No global hook, signing, or name of the caller reaches the test repos.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n[core]\n\thooksPath = /dev/null\n' > "$tmp/gitconfig"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1

# setup <case>: origin.git (bare) and work (a clone) with the commits one and two on main.
setup() {
    d="$tmp/$1"
    mkdir -p "$d"
    git init -q --bare "$d/origin.git"
    git clone -q "$d/origin.git" "$d/work" 2>/dev/null
    git -C "$d/work" commit -q --allow-empty -m one
    git -C "$d/work" commit -q --allow-empty -m two
    git -C "$d/work" push -q origin HEAD:main
    one="$(git -C "$d/work" rev-parse HEAD~1)" two="$(git -C "$d/work" rev-parse HEAD)"
}
# origin_tag <version> <commit>: an annotated tag on origin only; the local copy is deleted, so the
# script must read origin.
origin_tag() {
    git -C "$d/work" tag -a "v$1" -m old "$2" && git -C "$d/work" push -q origin "v$1" \
        && git -C "$d/work" tag -d "v$1" >/dev/null
}
run() { out="$(cd "$d/work" && "$script" "$1" "$2" msg 2>&1)"; code=$?; }
no_tag() {
    git -C "$d/work" rev-parse -q --verify "refs/tags/v$1" >/dev/null && fail "$2: a local tag v$1"
    git -C "$d/origin.git" rev-parse -q --verify "refs/tags/v$1" >/dev/null && fail "$2: an origin tag v$1"
}
refused() { # refused <case> <version> <commit> <code> <text>
    local before
    before="$(git -C "$d/origin.git" rev-parse -q --verify "refs/tags/v$2")"
    run "$2" "$3"
    [[ $code -eq $4 ]] || fail "$1: exit $code, expected $4: $out"
    grep -q -- "$5" <<<"$out" || fail "$1: the output does not name '$5': $out"
    if [[ -n "$before" ]]; then # the equal case: origin keeps its tag, and no local copy comes back
        [[ "$(git -C "$d/origin.git" rev-parse -q --verify "refs/tags/v$2")" == "$before" ]] || fail "$1: the origin tag changed"
        git -C "$d/work" rev-parse -q --verify "refs/tags/v$2^{commit}" | grep -qx "$3" && fail "$1: a local tag v$2 on the commit"
    else
        no_tag "$2" "$1"
    fi
}

setup lower && origin_tag 0.3.8.1 "$one"
refused 'a lower fourth number' 0.3.7.1 "$two" 1 'not higher than the newest tag v0.3.8.1'
refused 'an equal version' 0.3.8.1 "$two" 1 'not higher than the newest tag v0.3.8.1'

setup order && origin_tag 0.3.10 "$one"
refused 'sort -V: 0.3.9 is lower than 0.3.10' 0.3.9 "$two" 1 'v0.3.10'

setup pass && origin_tag 0.3.8.1 "$one"
run 0.3.8.2 "$two"
[[ $code -eq 0 ]] || fail "a higher fourth number: exit $code: $out"
[[ "$(git -C "$d/origin.git" cat-file -t refs/tags/v0.3.8.2 2>&1)" == tag ]] || fail 'the origin tag is not annotated'
[[ "$(git -C "$d/origin.git" rev-parse 'v0.3.8.2^{commit}' 2>&1)" == "$two" ]] || fail 'the origin tag is not on the commit'
[[ "$("$version_sh" "$d/work")" == 0.3.8.2 ]] || fail "version.sh does not print 0.3.8.2: $("$version_sh" "$d/work")"
git -C "$d/work" commit -q --allow-empty -m three && git -C "$d/work" push -q origin HEAD:main
run 0.3.8.10 "$(git -C "$d/work" rev-parse HEAD)"
[[ $code -eq 0 ]] || fail "sort -V: 0.3.8.10 over 0.3.8.2: exit $code: $out"

setup first
run 0.3.9 "$two"
[[ $code -eq 0 ]] || fail "no tag on origin yet: exit $code: $out"

setup earlier && origin_tag 0.3.8.1 "$two"
refused 'a commit before the newest tag' 0.3.9 "$one" 1 'does not hold v0.3.8.1'

setup side
git -C "$d/work" checkout -q -b side && git -C "$d/work" commit -q --allow-empty -m side
refused 'a commit off origin/main' 0.3.9 "$(git -C "$d/work" rev-parse HEAD)" 1 'not on origin/main'

setup bad
for v in 0.3 0.3.8.2.1 v0.3.8 '0.3.x'; do refused "the bad version $v" "$v" "$two" 2 'bad version'; done

# A failed push leaves no local tag, so the retry of the same version passes.
setup push && origin_tag 0.3.8.1 "$one"
git -C "$d/origin.git" config core.hooksPath hooks
printf '#!/bin/sh\nexit 1\n' > "$d/origin.git/hooks/pre-receive" && chmod +x "$d/origin.git/hooks/pre-receive"
run 0.3.8.2 "$two"
[[ $code -ne 0 ]] || fail "a refused push: exit 0: $out"
no_tag 0.3.8.2 'a refused push'
rm "$d/origin.git/hooks/pre-receive"
run 0.3.8.2 "$two"
[[ $code -eq 0 ]] || fail "the retry after a refused push: exit $code: $out"

# A local tag that origin does not have is not the newest tag.
setup local && origin_tag 0.3.8.1 "$one"
git -C "$d/work" tag -a v0.9.0 -m stale "$one"
run 0.3.8.2 "$two"
[[ $code -eq 0 ]] || fail "a local-only v0.9.0 counted as the newest tag: exit $code: $out"

[[ $failures -eq 0 ]] && echo "tag-release tests: all passed"
exit $((failures > 0))
