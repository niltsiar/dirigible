#!/bin/bash
# Check that seen.sh prints each line of learnings.md and learnings-archive.md that holds a cause
# key, with its file; prints nothing and exits 0 for a key with no match; does not match a longer
# key; and exits 2 for a class that is not on the `Failure classes:` line of synthesizer.md, or
# for a key that is not <prefix>-<nnn>/<class> or NEW-<prefix>-<slug>/<class>. Each case runs in a
# temporary repo with fixture files. Run by `make test-hooks`.
set -uo pipefail
seen="$(cd "$(dirname "$0")" && pwd)/seen.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
repo="$tmp/repo"
mkdir -p "$repo/.scratchpads"
git -C "$repo" init -q
printf '%s\n' \
  '- 2026-09-01 seen-once run-a DLV-016/hook: the guardrail blocked a heredoc.' \
  '- 2026-09-02 seen-once run-b NEW-DLV-probe-app/probe: a probe left the app open.' \
  '- 2026-09-03 seen-once run-c XDLV-016/hook: a longer key.' > "$repo/.scratchpads/learnings.md"
printf '%s\n' \
  '- 2026-08-01 run-z DLV-016/hook: an older line (abc1234).' \
  '- 2026-08-02 run-z DLV-016/hooks: another class.' > "$repo/.scratchpads/learnings-archive.md"

run() { (cd "$repo" && "$seen" "$@"); }

out="$(run DLV-016/hook)"; code=$?
want=$'learnings.md:1:- 2026-09-01 seen-once run-a DLV-016/hook: the guardrail blocked a heredoc.\nlearnings-archive.md:1:- 2026-08-01 run-z DLV-016/hook: an older line (abc1234).'
[[ $code -eq 0 ]] || fail "match: exit $code"
[[ "$out" == "$want" ]] || fail "match: output differs: $out"

out="$(run NEW-DLV-probe/probe)"; code=$?
[[ $code -eq 0 && -z "$out" ]] || fail "no match: exit $code, output: $out"

out="$(run NEW-DLV-probe-app/probe)"; code=$?
[[ $code -eq 0 && "$out" == learnings.md:2:* ]] || fail "NEW key: exit $code, output: $out"

run DLV-016/bogus > /dev/null 2>&1; code=$?
[[ $code -eq 2 ]] || fail "class not on the Failure classes line: expected exit 2, got $code"

for bad in dlv-016/hook DLV-16/hook DLV-016 NEW-DLV-Probe/hook NEW-DLV-probe_app/hook 'DLV-016/hook x' ''; do
  run "$bad" > /dev/null 2>&1; code=$?
  [[ $code -eq 2 ]] || fail "bad key '$bad': expected exit 2, got $code"
done

[[ $failures -eq 0 ]] && echo "seen tests: all passed"
exit $((failures > 0))
