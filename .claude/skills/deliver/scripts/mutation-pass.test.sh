#!/bin/bash
# Check mutation-pass.sh with a fake python3 (in place of mutate.py) and a fake with-lock.sh in the
# tree. Check that it runs each mutant of the batch file once, in the tree, under one lock take,
# prints one result line for each mutant and the count line, stops the batch after a mutate.py
# exit 3 (a failed restore) or 130 (stopped), stops the running mutate.py and the batch on a TERM
# to the script (exit 130), and refuses a missing batch file, a tree with
# changes, a live mutate.py lock, a tree that is not a worktree root, and the main checkout.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/mutation-pass.sh"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$tmp/main"
# The fake with-lock.sh of the tree logs each take and passes the hold to its command, as the real
# one does with its hold variable.
mkdir -p "$tmp/main/scripts" "$tmp/bin"
cat > "$tmp/main/scripts/with-lock.sh" <<EOF
#!/bin/bash
echo take >> "$tmp/locks"
DIRIGIBLE_BUILD_LOCK=fake exec "\$@"
EOF
chmod +x "$tmp/main/scripts/with-lock.sh"
git -C "$tmp/main" add scripts
git -C "$tmp/main" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/main" worktree add -q "$tmp/tree" 2>/dev/null

# The fake python3 logs its old text (the result to give), its folder, and the lock hold. The old
# text sets the result: killed or survived (exit 0 or 1), exit3 (a failed restore), exit130, or
# hang (it writes its pid and waits; a TERM writes restored and exits 130, as mutate.py does).
cat > "$tmp/bin/python3" <<EOF
#!/bin/bash
[[ "\$1" == -I ]] || { echo "fake python3: no -I" >&2; exit 9; }
r="\$4"
echo "\$r \$PWD \${DIRIGIBLE_BUILD_LOCK:-none}" >> "$tmp/calls"
case "\$r" in
  killed) echo killed; exit 0 ;;
  survived) echo survived; exit 1 ;;
  exit3) echo "mutate: the restore of x failed; the copy is y" >&2; exit 3 ;;
  exit130) echo stopped; exit 130 ;;
  hang) trap 'echo restored >> "$tmp/restored"; echo stopped; exit 130' TERM
    echo \$\$ > "$tmp/hang.pid"; sleep 30 & wait ;;
esac
EOF
chmod +x "$tmp/bin/python3"

# batch <result>...: a batch file with one mutant for each result.
batch() {
  local r
  : > "$tmp/calls"; : > "$tmp/locks"
  for r in "$@"; do printf 'mutant Sources/x.swift %s new log build test\n' "$r"; done > "$tmp/batch.sh"
}
run() { out="$(PATH="$tmp/bin:$PATH" "$script" "$@" 2>&1)"; code=$?; }
calls() { cut -d' ' -f1 "$tmp/calls" | paste -sd' ' -; }

# Each mutant runs once, in the tree, under one lock take for the whole batch.
batch killed survived
run "$tmp/tree" "$tmp/batch.sh"
[[ $code -eq 0 ]] || fail "pass: exit $code: $out"
[[ "$(calls)" == 'killed survived' ]] || fail "pass: calls [$(calls)]"
[[ "$(cut -d' ' -f2 "$tmp/calls" | sort -u)" == "$tmp/tree" ]] || fail "pass: not in the tree: $(cat "$tmp/calls")"
[[ "$(wc -l < "$tmp/locks" | tr -d ' ')" == 1 ]] || fail "pass: lock takes [$(cat "$tmp/locks")]"
[[ "$(cut -d' ' -f3 "$tmp/calls" | paste -sd' ' -)" == 'fake fake' ]] || fail "pass: holds [$(cat "$tmp/calls")]"
grep -qx '1: killed' <<<"$out" || fail "pass: no line for mutant 1: $out"
grep -qx '2: survived' <<<"$out" || fail "pass: no line for mutant 2: $out"
grep -qx 'pass: 2 mutants; killed 1; survived 1; other 0' <<<"$out" || fail "pass: count line: $out"

# A failed restore or a stopped mutate.py stops the batch with its exit status.
for r in exit3 exit130; do
  batch killed "$r" killed
  run "$tmp/tree" "$tmp/batch.sh"
  [[ $code -eq ${r#exit} ]] || fail "$r: exit $code: $out"
  [[ "$(calls)" == "killed $r" ]] || fail "$r: calls [$(calls)]"
  grep -q 'mutation-pass: stopped after mutant 2' <<<"$out" || fail "$r: no stop line: $out"
done

# A TERM to the script (pkill -TERM -f mutation-pass.sh) stops the running mutate.py, which
# restores its file, and then the batch: the next mutant does not run.
batch hang killed
rm -f "$tmp/hang.pid" "$tmp/restored"
PATH="$tmp/bin:$PATH" "$script" "$tmp/tree" "$tmp/batch.sh" > "$tmp/out" 2>&1 &
pass=$!
for _ in $(seq 50); do [[ -s "$tmp/hang.pid" ]] && break; sleep 0.1; done
started=$SECONDS
kill -TERM "$pass"
wait "$pass"
code=$?
(( SECONDS - started < 10 )) || fail "TERM: the pass ran $((SECONDS - started)) s after the TERM"
[[ $code -eq 130 ]] || fail "TERM: exit $code: $(cat "$tmp/out")"
[[ -s "$tmp/restored" ]] || fail "TERM: the running mutant did not get the stop"
[[ "$(calls)" == hang ]] || fail "TERM: calls [$(calls)]"
grep -q 'mutation-pass: stopped after mutant 1' "$tmp/out" || fail "TERM: no stop line: $(cat "$tmp/out")"
kill "$(cat "$tmp/hang.pid" 2>/dev/null)" 2>/dev/null

# Refusals: no batch file, a tree with changes, a live mutate.py lock, a tree that is not a
# worktree root, the main checkout, and a wrong argument count.
batch killed
run "$tmp/tree" "$tmp/none.sh"
[[ $code -eq 2 && -z "$(calls)" ]] || fail "no batch file: exit $code: $out"
touch "$tmp/tree/new"
run "$tmp/tree" "$tmp/batch.sh"
[[ $code -eq 2 && "$out" == *'has changes'* && -z "$(calls)" ]] || fail "dirty tree: exit $code: $out"
rm "$tmp/tree/new"
lock="$(git -C "$tmp/tree" rev-parse --absolute-git-dir)/dirigible-mutate.lock"
mkdir "$lock" && echo $$ > "$lock/pid"
run "$tmp/tree" "$tmp/batch.sh"
[[ $code -eq 2 && "$out" == *'mutate.py run holds'* && -z "$(calls)" ]] || fail "live lock: exit $code: $out"
rm -rf "$lock"
mkdir -p "$tmp/tree/sub"
run "$tmp/tree/sub" "$tmp/batch.sh"
[[ $code -eq 2 && -z "$(calls)" ]] || fail "not a worktree root: exit $code: $out"
run "$tmp/main" "$tmp/batch.sh"
[[ $code -eq 2 && "$out" == *'main checkout'* && -z "$(calls)" ]] || fail "main checkout: exit $code: $out"
run "$tmp/tree"
[[ $code -eq 2 && "$out" == *'usage'* ]] || fail "one argument: exit $code: $out"

[[ $failures -eq 0 ]] && echo "mutation-pass tests: all passed"
exit $((failures > 0))
