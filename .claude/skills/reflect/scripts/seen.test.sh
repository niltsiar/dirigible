#!/bin/bash
# Check that seen.sh prints each line of a lesson page or an item page of the wiki that holds a
# cause key, with its page and line number, from any folder; skips the front matter of a page, except
# the title line of an item whose body has no line with the key;
# prints nothing and exits 0 for a key with no match; does not match a longer key; exits 2 for a
# class that is not on the `Failure classes:` line of synthesizer.md, or for a key that is not
# <prefix>-<nnn>/<class> or NEW-<prefix>-<slug>/<class>; and exits 1 with the wiki path,
# `scripts/wiki.py init`, and DIRIGIBLE_WIKI when there is no wiki. Each case runs on a temporary
# wiki that DIRIGIBLE_WIKI names. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
seen="$here/seen.sh"
wiki_tool="$(cd "$here/../../../.." && pwd)/scripts/wiki.py"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export DIRIGIBLE_WIKI="$tmp/wiki"
"$wiki_tool" init > /dev/null || fail 'wiki init'

lesson() {
  printf '%s\n' "$2" > "$tmp/lesson.txt"
  "$wiki_tool" lesson "$1" --from "$tmp/lesson.txt" > /dev/null || fail "lesson $1"
}
item() {
  printf '%s\n' "$1" "$2" '' "${@:3}" > "$tmp/item.txt"
  "$wiki_tool" add next --from "$tmp/item.txt" > /dev/null || fail "add $1"
}
lesson DLV-016/hook '- 2026-09-01 seen-once run-a DLV-016/hook: the guardrail blocked a heredoc.'
lesson NEW-DLV-probe-app/probe '- 2026-09-02 seen-once run-b NEW-DLV-probe-app/probe: a probe left the app open.'
lesson XDLV-016/hook '- 2026-09-03 seen-once run-c XDLV-016/hook: a longer key.'
# The title of this item holds the key, so a match in the front matter would show.
item 'Upkeep DLV-016/hook' 'a queued item' \
  '- upkeep DLV-016/hook: a queued item (earlier: lessons/DLV-016--hook.md:6).' \
  '- upkeep DLV-016/hooks: another class.'
# The backlog import form: the key is only in the title.
item 'Upkeep DLV-050/hook: a queued item' 'the body has no key' '- a body line.'

run() { (cd "${SEEN_CWD:-$tmp}" && "$seen" "$@"); }

out="$(run DLV-016/hook)"; code=$?
want=$'lessons/DLV-016--hook.md:6:- 2026-09-01 seen-once run-a DLV-016/hook: the guardrail blocked a heredoc.\nitems/0001.md:9:- upkeep DLV-016/hook: a queued item (earlier: lessons/DLV-016--hook.md:6).'
[[ $code -eq 0 ]] || fail "match: exit $code"
[[ "$out" == "$want" ]] || fail "match: output differs: $out"
# The wiki is the same from each folder.
out="$(SEEN_CWD="$here" run DLV-016/hook)"; code=$?
[[ $code -eq 0 && "$out" == "$want" ]] || fail "other folder: exit $code, output: $out"

# A key only in the title of an item prints the title line; a key in the title and the body prints the body lines only.
out="$(run DLV-050/hook)"; code=$?
[[ $code -eq 0 && "$out" == 'items/0002.md:3:title: "Upkeep DLV-050/hook: a queued item"' ]] || fail "title only: exit $code, output: $out"

out="$(run NEW-DLV-probe/probe)"; code=$?
[[ $code -eq 0 && -z "$out" ]] || fail "no match: exit $code, output: $out"

out="$(run NEW-DLV-probe-app/probe)"; code=$?
[[ $code -eq 0 && "$out" == lessons/NEW-DLV-probe-app--probe.md:6:* ]] || fail "NEW key: exit $code, output: $out"

run DLV-016/bogus > /dev/null 2>&1; code=$?
[[ $code -eq 2 ]] || fail "class not on the Failure classes line: expected exit 2, got $code"

for bad in dlv-016/hook DLV-16/hook DLV-016 NEW-DLV-Probe/hook NEW-DLV-probe_app/hook 'DLV-016/hook x' ''; do
  run "$bad" > /dev/null 2>&1; code=$?
  [[ $code -eq 2 ]] || fail "bad key '$bad': expected exit 2, got $code"
done

# With no wiki, the script exits 1, names the path, `init`, and DIRIGIBLE_WIKI, and makes no wiki.
out="$(DIRIGIBLE_WIKI="$tmp/missing" run DLV-016/hook 2> "$tmp/err")"; code=$?
[[ $code -eq 1 && -z "$out" ]] || fail "no wiki: exit $code, output: $out"
for need in "$tmp/missing" 'scripts/wiki.py init' DIRIGIBLE_WIKI; do
  grep -qF -- "$need" "$tmp/err" || fail "no wiki: the message lacks '$need': $(cat "$tmp/err")"
done
[[ ! -e "$tmp/missing" ]] || fail 'no wiki: seen.sh made a wiki'

[[ $failures -eq 0 ]] && echo "seen tests: all passed"
exit $((failures > 0))
