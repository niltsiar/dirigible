#!/bin/bash
# Check replay-batch.sh with a fake python3 (in place of mutate.py) and a fake date (a clock that
# the fake python3 moves on). Check that it replays each killed log once into controls/replay/,
# skips a done replay (a result other than stopped), replays a stopped or header-only replay and
# a named log only with --again, counts only killed, a hang, and survived as done, gives a log that fits the budget its full header timeout, caps a log that cannot
# fit once, moves a capped hang aside and gives it only its full limit later (else TOO LONG),
# stops with BUDGET and the count line, goes on after a mutate.py exit 2, and refuses a budget
# over 480, a tree that is not a worktree root, and the main checkout. Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/replay-batch.sh"
failures=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q "$tmp/main"
git -C "$tmp/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$tmp/main" worktree add -q "$tmp/tree" 2>/dev/null
mkdir -p "$tmp/bin"

# The fake date prints the clock of $tmp/clock for +%s. The fake python3 logs its --timeout and
# log, moves the clock on by the `# fake-seconds:` of the log, writes the replay log with the
# `# fake:` result of the log, and prints that result. `# fake: exit3` prints a failed restore and
# exits 3. `# fake: exit2` prints a mutate.py message
# and exits 2 with no replay log.
cat > "$tmp/bin/date" <<EOF
#!/bin/bash
[[ "\$1" == +%s ]] && { cat "$tmp/clock"; exit 0; }
exec /bin/date "\$@"
EOF
cat > "$tmp/bin/python3" <<EOF
#!/bin/bash
[[ "\$1" == -I ]] || { echo "fake python3: no -I" >&2; exit 9; }
t="" log="" out="" allow=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --timeout) t="\$2"; shift 2 ;;
    --replay) log="\$2" out="\$3"; shift 3 ;;
    --allow-side-effects) allow=" allow"; shift ;;
    *) shift ;;
  esac
done
echo "\$(basename "\$log") \$t \$PWD\$allow" >> "$tmp/calls"
s="\$(sed -n 's/^# fake-seconds: //p' "\$log")"
echo \$(( \$(cat "$tmp/clock") + \${s:-10} )) > "$tmp/clock"
r="\$(sed -n 's/^# fake: //p' "\$log")"
if [[ "\$r" == exit3 ]]; then echo "mutate: the restore of x failed; the copy is y" >&2; exit 3; fi
if [[ "\$r" == exit2 ]]; then echo "mutate: \$log has side effects; pass --allow-side-effects" >&2; exit 2; fi
b="\$(sed -n 's/^# fake-build: //p' "\$log")"
{ echo '# mutation of x'; [[ -n "\$b" ]] && printf 'Build complete! (%ss)\nBuild complete! (1.00s)\n' "\$b"; echo "# result: \${r:-killed}"; } > "\$out"
echo "\${r:-killed}"
EOF
chmod +x "$tmp/bin/date" "$tmp/bin/python3"

c="$tmp/controls"
# control <name> <source result> [<timeout>] [<fake result>] [<fake seconds>] [<fake build seconds>]:
# a source log.
control() {
  { echo "# mutation of Sources/x.swift"; [[ -n "${3:-}" ]] && echo "# timeout: $3"
    echo "# result: $2"; [[ -n "${4:-}" ]] && echo "# fake: $4"; [[ -n "${5:-}" ]] && echo "# fake-seconds: $5"
    [[ -n "${6:-}" ]] && echo "# fake-build: $6"; } > "$c/$1.log"
}
fresh() { rm -rf "$c" "$tmp/calls"; mkdir -p "$c"; echo 1000 > "$tmp/clock"; : > "$tmp/calls"; }
run() { out="$(PATH="$tmp/bin:$PATH" "$script" "$tmp/tree" "$c" "$@" 2>&1)"; code=$?; }
# runf <flag> <value> <budget> [<log>...]: a run with one flag and its value before the tree.
# runx <arguments>: a run with the whole argument list, flags and tree too.
runx() { out="$(PATH="$tmp/bin:$PATH" "$script" "$@" 2>&1)"; code=$?; }
runf() { out="$(PATH="$tmp/bin:$PATH" "$script" "$1" "$2" "$tmp/tree" "$c" "${@:3}" 2>&1)"; code=$?; }
calls() { cat "$tmp/calls"; }

# A killed log replays into controls/replay/ in the tree, with its full header timeout.
fresh
control a killed 100.0
control b 'killed (hang)' 200.0
control s survived 100.0
run 480
[[ $code -eq 0 ]] || fail "replay: exit $code: $out"
[[ "$(calls)" == "a.log 100 $tmp/tree"$'\n'"b.log 200 $tmp/tree" ]] || fail "replay: calls [$(calls)]"
grep -qx 'a.log: killed' <<<"$out" || fail "replay: no result line for a: $out"
[[ -f "$c/replay/a.log" && -f "$c/replay/b.log" ]] || fail 'replay: no replay logs'
grep -qx 'replayed 2 of 2; left 0; too long 0; refused 0; needs a decision 0' <<<"$out" || fail "replay: count line: $out"
grep -qx 'ALL DONE' <<<"$out" || fail "replay: no ALL DONE: $out"

# A done replay is skipped; a stopped or header-only replay log replays again.
: > "$tmp/calls"
printf '# result: stopped\n' > "$c/replay/a.log"
printf '# mutation of x\n' > "$c/replay/b.log"
run 480
[[ "$(calls | cut -d' ' -f1 | paste -sd' ' -)" == 'a.log b.log' ]] || fail "stopped and header-only: calls [$(calls)]"
: > "$tmp/calls"
run 480
[[ -z "$(calls)" ]] || fail "done replays ran again: [$(calls)]"
grep -qx 'ALL DONE' <<<"$out" || fail "done replays: no ALL DONE: $out"
# Done means done on this HEAD: after a new commit, each log replays again with no flag.
git -C "$tmp/tree" -c user.name=t -c user.email=t@t commit -q --allow-empty -m next
: > "$tmp/calls"
run 480
[[ "$(calls | cut -d' ' -f1 | paste -sd' ' -)" == 'a.log b.log' ]] || fail "new HEAD: calls [$(calls)]"
: > "$tmp/calls"
# A named log that is done is skipped too; --again replays it. Only the named logs count.
run 480 "$c/a.log"
[[ -z "$(calls)" ]] || fail "named done log: calls [$(calls)]"
grep -qx 'replayed 1 of 1; left 0; too long 0; refused 0; needs a decision 0' <<<"$out" || fail "named log: count line: $out"
runx --again "$tmp/tree" "$c" 480 "$c/a.log"
[[ "$(calls | cut -d' ' -f1)" == a.log ]] || fail "--again: calls [$(calls)]"
# A replay that ended with BUILD FAILED, NO TESTS, or WRONG FAILURE is not done.
for r in 'BUILD FAILED' 'NO TESTS' 'WRONG FAILURE'; do
  printf '# result: %s\n' "$r" > "$c/replay/b.log"
  : > "$tmp/calls"
  run 480
  [[ "$(calls | cut -d' ' -f1)" == b.log ]] || fail "$r: not replayed: calls [$(calls)]"
done

# A log that cannot fit a full budget (900 + 30 > 480) runs once, capped at the time left.
fresh
control big killed 900.0
run 480
[[ "$(calls)" == "big.log 450 $tmp/tree" ]] || fail "capped: calls [$(calls)]"
grep -qx 'big.log: killed (capped 450 s)' <<<"$out" || fail "capped: result line: $out"
grep -qx 'ALL DONE' <<<"$out" || fail "capped kill: no ALL DONE: $out"

# A capped hang is not done: its replay log moves aside, and the next call gives it only its full
# limit, which cannot fit, so it is TOO LONG and the batch can end.
fresh
control big killed 900.0 'killed (hang)'
run 480
grep -qx 'big.log: CAPPED HANG (capped 450 s)' <<<"$out" || fail "capped hang: result line: $out"
[[ -f "$c/replay/big.log.capped" && ! -e "$c/replay/big.log" ]] || fail 'capped hang: replay log not moved aside'
grep -qx 'replayed 0 of 1; left 1; too long 0; refused 0; needs a decision 0' <<<"$out" || fail "capped hang: count line: $out"
grep -qx 'ALL DONE' <<<"$out" && fail "capped hang: ALL DONE with a log left"
: > "$tmp/calls"
run 480
[[ -z "$(calls)" ]] || fail "TOO LONG: replayed [$(calls)]"
# The printed command holds the tree, so it never replays in the main checkout.
grep -qx "big.log: TOO LONG; run it with run_in_background: $script --timeout 900 $tmp/tree $c 480 $c/big.log" <<<"$out" ||
  fail "TOO LONG: line: $out"
grep -qx 'replayed 0 of 1; left 0; too long 1; refused 0; needs a decision 0' <<<"$out" || fail "TOO LONG: count line: $out"
grep -qx 'ALL DONE' <<<"$out" && fail "TOO LONG: ALL DONE with a TOO LONG log"
grep -qx 'TOO LONG PENDING: do not build or commit until it ends' <<<"$out" || fail "TOO LONG: no PENDING line: $out"
# --timeout gives a named log that limit, with no budget and no cap.
: > "$tmp/calls"
runf --timeout 900 480 "$c/big.log"
[[ "$(calls)" == "big.log 900 $tmp/tree" ]] || fail "--timeout: calls [$(calls)]: $out"
grep -qx 'big.log: killed (hang)' <<<"$out" || fail "--timeout: result line: $out"
grep -qx 'replayed 1 of 1; left 0; too long 0; refused 0; needs a decision 0' <<<"$out" || fail "--timeout: count line: $out"
# A capped hang whose full limit fits replays with that limit.
fresh
control mid killed 300.0
mkdir -p "$c/replay"
printf '# result: killed (hang)\n' > "$c/replay/mid.log.capped"
run 480
[[ "$(calls)" == "mid.log 300 $tmp/tree" ]] || fail "capped hang that fits: calls [$(calls)]"

# A log with no timeout header runs capped; after a capped hang it is TOO LONG.
fresh
control none killed '' 'killed (hang)'
run 480
[[ "$(calls)" == "none.log 450 $tmp/tree" ]] || fail "no header: calls [$(calls)]"
grep -qx 'none.log: CAPPED HANG (capped 450 s)' <<<"$out" || fail "no header: result line: $out"
run 480
grep -q '^none.log: TOO LONG' <<<"$out" || fail "no header after a capped hang: $out"

# A log that fits a full budget but not the time left waits for a fresh call: BUDGET and the
# count line. The first log uses 100 s, so 350 s are left for a 400 s log.
fresh
control a1 killed 100.0 killed 100
control a2 killed 400.0
run 480
[[ "$(calls | cut -d' ' -f1)" == a1.log ]] || fail "budget: calls [$(calls)]"
grep -qx 'BUDGET' <<<"$out" || fail "budget: no BUDGET: $out"
grep -qx 'replayed 1 of 2; left 1; too long 0; refused 0; needs a decision 0' <<<"$out" || fail "budget: count line: $out"
grep -qx 'ALL DONE' <<<"$out" && fail 'budget: ALL DONE with a log left'
# Under 60 s left, a capped log does not start: BUDGET.
fresh
control a1 killed 100.0 killed 400
control big killed 900.0
run 480
[[ "$(calls | cut -d' ' -f1)" == a1.log ]] || fail "low time: calls [$(calls)]"
grep -qx 'BUDGET' <<<"$out" || fail "low time: no BUDGET: $out"

# The build allowance is twice the first build time of the last replay log (the build command;
# the test command builds later, and faster), and 30 s or more. A 100 s build and 10 s of use
# leave 480 - 10 - 200 = 270 s for a capped log.
fresh
control b1 killed 100.0 killed 10 100
control big killed 900.0
run 480
[[ "$(calls | sed -n 2p)" == "big.log 270 $tmp/tree" ]] || fail "build time: calls [$(calls)]"
# The first log of a call takes its allowance from the build line of its source log: 480 - 400.
fresh
control big killed 900.0
echo 'Build complete! (200.00s)' >> "$c/big.log"
run 480
[[ "$(calls)" == "big.log 80 $tmp/tree" ]] || fail "source build time: calls [$(calls)]"

# A mutate.py exit 2 prints its message, and the next log runs.
fresh
control e killed 100.0 exit2
control f killed 100.0
run 480
grep -q '^e.log: mutate: .*side effects' <<<"$out" || fail "exit 2: no message: $out"
[[ "$(calls | cut -d' ' -f1 | paste -sd' ' -)" == 'e.log f.log' ]] || fail "exit 2: calls [$(calls)]"
grep -qx 'replayed 1 of 2; left 0; too long 0; refused 1; needs a decision 0' <<<"$out" || fail "exit 2: count line: $out"
grep -qx 'ALL DONE' <<<"$out" && fail "exit 2: ALL DONE with a refused log"
grep -qx 'REFUSED: replay each refused log, or log why not' <<<"$out" || fail "exit 2: no REFUSED line: $out"
# A refused log with an older done replay log counts only as refused.
printf '# result: killed\n# head: %s\n' "$(git -C "$tmp/tree" rev-parse HEAD)" > "$c/replay/e.log"
runx --again "$tmp/tree" "$c" 480 "$c/e.log"
grep -qx 'replayed 0 of 1; left 0; too long 0; refused 1; needs a decision 0' <<<"$out" || fail "refused and done: count line: $out"

# BUILD FAILED, NO TESTS, and WRONG FAILURE need a decision: not left, skipped by the next call
# unless --again, and the count line points to the rule.
fresh
control x killed 100.0 'BUILD FAILED'
run 480
grep -qx 'replayed 0 of 1; left 0; too long 0; refused 0; needs a decision 1' <<<"$out" || fail "decision: count line: $out"
grep -q 'mutation-controls.md:21' <<<"$out" || fail "decision: no pointer: $out"
grep -qx 'ALL DONE' <<<"$out" && fail "decision: ALL DONE with a decision left"
: > "$tmp/calls"
run 480
[[ -z "$(calls)" ]] || fail "decision: replayed again with no --again: [$(calls)]"
runx --again "$tmp/tree" "$c" 480
[[ "$(calls | cut -d' ' -f1)" == x.log ]] || fail "decision --again: calls [$(calls)]"

# A failed restore (mutate.py exit 3) stops the batch at once: a mutant can be in the tree.
fresh
control r1 killed 100.0 exit3
control r2 killed 100.0
run 480
[[ $code -eq 3 ]] || fail "restore failed: exit $code: $out"
[[ "$(calls | cut -d' ' -f1)" == r1.log ]] || fail "restore failed: calls [$(calls)]"
grep -q '^RESTORE FAILED: check git status' <<<"$out" || fail "restore failed: no line: $out"
# --allow-side-effects goes to mutate.py.
fresh
control e killed 100.0 exit2
runx --allow-side-effects "$tmp/tree" "$c" 480 "$c/e.log"
[[ "$(calls)" == "e.log 100 $tmp/tree allow" ]] || fail "--allow-side-effects: calls [$(calls)]"

# A folder with no killed log ends at once (bash 3.2 with set -u has no empty array).
fresh
control s survived 100.0
run 480
[[ $code -eq 0 && -z "$(calls)" ]] || fail "no killed log: exit $code, calls [$(calls)]: $out"
grep -q '^replayed 0 of 0; left 0' <<<"$out" || fail "no killed log: count line: $out"
grep -qx 'ALL DONE' <<<"$out" || fail "no killed log: no ALL DONE: $out"

# Refusals: a tree with changes (a mutant or a TOO LONG run in it), and a live mutate.py lock.
fresh
control a killed 100.0
touch "$tmp/tree/new"
run 480
[[ $code -eq 2 && "$out" == *'has changes'* && -z "$(calls)" ]] || fail "dirty tree: exit $code, calls [$(calls)]: $out"
rm "$tmp/tree/new"
lock="$(git -C "$tmp/tree" rev-parse --absolute-git-dir)/dirigible-mutate.lock"
mkdir "$lock" && echo $$ > "$lock/pid"
run 480
[[ $code -eq 2 && "$out" == *'mutate.py run holds'* && -z "$(calls)" ]] || fail "live lock: exit $code, calls [$(calls)]: $out"
sh -c 'exit 0' & dead=$!
wait "$dead"
echo "$dead" > "$lock/pid"
run 480
[[ "$(calls | cut -d' ' -f1)" == a.log ]] || fail "dead lock: calls [$(calls)]: $out"
rm -rf "$lock"

# Refusals: a budget over 480, a tree that is not a worktree root, the main checkout.
fresh
control a killed 100.0
run 481
[[ $code -eq 2 && -z "$(calls)" ]] || fail "budget 481: exit $code, calls [$(calls)]"
out="$(PATH="$tmp/bin:$PATH" "$script" "$tmp/tree/sub" "$c" 480 2>&1)"; code=$?
[[ $code -eq 2 ]] || fail "not a worktree root: exit $code: $out"
out="$(PATH="$tmp/bin:$PATH" "$script" "$tmp/main" "$c" 480 2>&1)"; code=$?
[[ $code -eq 2 && "$out" == *'main checkout'* && -z "$(calls)" ]] || fail "main checkout: exit $code: $out"

[[ $failures -eq 0 ]] && echo "replay-batch tests: all passed"
exit $((failures > 0))
