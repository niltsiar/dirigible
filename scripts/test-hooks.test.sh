#!/bin/bash
# Check scripts/test-hooks.sh, the pass stamp of make test-hooks: a reuse with the same key (C1),
# a new run after a change of each key input (C2), a reuse after a change of an excluded path
# (C3), a key from the work tree on a dirty tree (C16), no stamp after a red test or a make flag
# (C4), and a run from a key tree that fails on a read outside the key and leaves no git state
# (C5), and a refusal of the whole list outside the push check, with no stamp reuse before it
# (C6). Each case uses a stub repo whose two stub tests append their name to a log, fake swift,
# xcodebuild, jq, sw_vers, and date on PATH, and its own TMPDIR. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
# A make value of an outer run (make test-hooks) must not reach the stub make.
unset MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE SINCE DIRIGIBLE_PUSH_CHECK DIRIGIBLE_HOOKS_ALL
# The whole list runs only with a switch. The cases of C1 to C5 run it, so they hold the switch of a
# person; the cases of C6 take it away.
export DIRIGIBLE_FULL_SUITE=1
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

mkdir "$tmp/bin"
printf '#!/bin/bash\necho "swift-driver version: 1 Apple Swift version ${FAKE_SWIFT}"\n' > "$tmp/bin/swift"
printf '#!/bin/bash\necho "Xcode 26.3"\n' > "$tmp/bin/xcodebuild"
printf '#!/bin/bash\necho "jq-${FAKE_JQ}"\n' > "$tmp/bin/jq"
printf '#!/bin/bash\necho "ProductVersion: 15.6"\n' > "$tmp/bin/sw_vers"
printf '#!/bin/bash\n[[ "$*" == +%%F ]] || { echo "fake date: $*" >&2; exit 2; }\necho "$FAKE_DATE"\n' > "$tmp/bin/date"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null

repo="$tmp/r"
stamp="$repo/.git/dirigible-hooks-stamp"
# new_repo: a new stub repo with the script, the stub tests, the floor paths of
# check-changed.sh --floor, and one file in each excluded path.
new_repo() {
    rm -rf "$repo" "$tmp/log" "$tmp/own"
    mkdir -p "$tmp/own" "$repo/scripts" "$repo/t" "$repo/.claude" "$repo/Support" "$repo/Tests" "$repo/docs" "$repo/Sources/Other"
    git -C "$repo" init -q -b main
    cp "$here/test-hooks.sh" "$here/check-changed.sh" "$repo/scripts/"
    printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
    for n in a b; do printf '#!/bin/bash\necho %s >> "$HOOKS_LOG"\n' "$n" > "$repo/t/$n.test.sh"; done
    chmod +x "$repo/t/"*.sh
    local floor_paths
    floor_paths="$("$here/check-changed.sh" --floor)"
    for f in $floor_paths; do
        [[ $f == */ ]] && f="${f}A.swift"
        mkdir -p "$repo/$(dirname "$f")"
        echo x > "$repo/$f"
    done
    for f in Sources/Other/O.swift Tests/T.swift docs/d.md README.md .claude/settings.json Support/s.txt; do
        echo x > "$repo/$f"
    done
    # Guards the stub setup above, not a hook case: each floor path exists in the stub repo.
    for p in $floor_paths; do
        if [[ $p == */ ]]; then
            [[ -n $(find "$repo/$p" -type f 2> /dev/null) ]] || fail "stub setup: no file in the floor folder $p"
        else
            [[ -f "$repo/$p" ]] || fail "stub setup: no file at the floor path $p"
        fi
    done
    commit init
    export FAKE_SWIFT=6.2.4 FAKE_JQ=1.7.1 FAKE_DATE=2026-10-12
}
commit() { git -C "$repo" add -A && git -C "$repo" commit -qm "$1"; }
# run [make arguments]: make test-hooks in the stub repo. The output goes to $tmp/out, the exit
# code to $code.
run() {
    (cd "$repo" && TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" make -s test-hooks "$@") > "$tmp/out" 2>&1
    code=$?
}
# run_with <VAR=value>... [make arguments]: as run, and the environment of make holds only the switches
# given (the first words that hold =, up to --). Without a word, no switch is set.
run_with() {
    local env_words=()
    while [[ $# -gt 0 && $1 != -- ]]; do env_words+=("$1"); shift; done
    [[ $# -eq 0 ]] || shift
    (cd "$repo" && env -u DIRIGIBLE_FULL_SUITE ${env_words[@]+"${env_words[@]}"} TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" \
        make -s test-hooks "$@") > "$tmp/out" 2>&1
    code=$?
}
# ran: the number of stub test runs so far.
ran() { if [[ -f "$tmp/log" ]]; then wc -l < "$tmp/log" | tr -d ' '; else echo 0; fi; }
stamps() { if [[ -f "$stamp" ]]; then wc -l < "$stamp" | tr -d ' '; else echo 0; fi; }
out() { tr '\n' '|' < "$tmp/out"; }

# C1: the second run with the same key prints the reuse line and runs no stub test.
new_repo
run
[[ $code -eq 0 && $(ran) -eq 2 ]] && grep -qE '^test-hooks: wrote [0-9a-f]{64}$' "$tmp/out" \
    || fail "same key: the first pass did not run both stubs and write a stamp: code $code, ran $(ran): $(out)"
run
[[ $code -eq 0 && $(ran) -eq 2 ]] && grep -qE '^test-hooks: reuse [0-9a-f]{64}$' "$tmp/out" \
    || fail "same key: the second run did not reuse the pass: code $code, ran $(ran): $(out)"

# C6: the whole HOOK_TESTS list with no switch exits nonzero before any test, and the message names
# make check-changed before DIRIGIBLE_FULL_SUITE=1.
new_repo
run_with --
refusal="$(tr '\n' ' ' < "$tmp/out")"
[[ $code -ne 0 && $(ran) -eq 0 && $(stamps) -eq 0 ]] && [[ $refusal == *'the whole HOOK_TESTS list runs only in the push check'* ]] \
    || fail "(C6) the whole list, no switch: code $code, ran $(ran): $(out)"
before_switch="${refusal%%DIRIGIBLE_FULL_SUITE=1*}"
[[ $refusal == *DIRIGIBLE_FULL_SUITE=1* && $before_switch == *'make check-changed'* ]] \
    || fail "(C6) the message does not name make check-changed before DIRIGIBLE_FULL_SUITE=1: $(out)"
# Each of the three switches runs the whole list.
for sw in DIRIGIBLE_PUSH_CHECK DIRIGIBLE_FULL_SUITE DIRIGIBLE_HOOKS_ALL; do
    new_repo
    run_with "$sw=1" --
    [[ $code -eq 0 && $(ran) -eq 2 ]] || fail "(C6) $sw=1: the whole list did not run: code $code, ran $(ran): $(out)"
done
# A pass stamp of the same key does not skip the refusal, and no reuse line prints.
new_repo
run_with DIRIGIBLE_FULL_SUITE=1 --
run_with --
[[ $code -ne 0 && $(ran) -eq 2 && $(stamps) -eq 1 ]] && ! grep -q reuse "$tmp/out" \
    || fail "(C6) a stamp of the key: the refusal did not come first: code $code, ran $(ran): $(out)"
# A list of all tests but one runs with no switch; a comma word that holds the whole list refuses.
new_repo
printf '#!/bin/bash\necho c >> "$HOOKS_LOG"\n' > "$repo/t/c.test.sh"
chmod +x "$repo/t/c.test.sh"
printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh \\\n\tt/c.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
commit three-tests
run_with -- HOOK_TESTS=t/a.test.sh,t/b.test.sh
[[ $code -eq 0 && $(ran) -eq 2 ]] || fail "(C6) all tests but one, no switch: code $code, ran $(ran): $(out)"
run_with -- HOOK_TESTS=t/a.test.sh,t/b.test.sh,t/c.test.sh
[[ $code -ne 0 && $(ran) -eq 2 ]] || fail "(C6) a comma word of the whole list, no switch: code $code, ran $(ran): $(out)"
# A switch is on only at the value 1: the value 0 refuses, also for each switch alone, and one switch
# at 1 beside another at 0 runs.
for sw in DIRIGIBLE_PUSH_CHECK DIRIGIBLE_FULL_SUITE DIRIGIBLE_HOOKS_ALL; do
    new_repo
    run_with "$sw=0" --
    [[ $code -ne 0 && $(ran) -eq 0 ]] || fail "(C6) $sw=0: the whole list was not refused: code $code, ran $(ran): $(out)"
done
new_repo
run_with DIRIGIBLE_FULL_SUITE=0 DIRIGIBLE_PUSH_CHECK=1 --
[[ $code -eq 0 && $(ran) -eq 2 ]] || fail "(C6) one switch at 1 beside one at 0: code $code, ran $(ran): $(out)"
# A HOOK_TESTS entry that only the work tree Makefile holds is part of the whole list: the list of HEAD
# does not decide the refusal.
new_repo
printf '#!/bin/bash\necho c >> "$HOOKS_LOG"\n' > "$repo/t/c.test.sh"
chmod +x "$repo/t/c.test.sh"
commit c-test
printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh \\\n\tt/c.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
run_with --
[[ $code -ne 0 && $(ran) -eq 0 ]] && grep -q 'the whole HOOK_TESTS list runs only in the push check' "$tmp/out" \
    || fail "(C6) an uncommitted HOOK_TESTS entry, no switch: code $code, ran $(ran): $(out)"
run_with DIRIGIBLE_FULL_SUITE=1 --
[[ $code -eq 0 && $(ran) -eq 3 && $(stamps) -eq 0 ]] || fail "(C6) an uncommitted HOOK_TESTS entry, with a switch: code $code, ran $(ran), stamps $(stamps): $(out)"

# C2: after a change of each key input, each stub test runs again and no reuse line prints.
# expect_rerun <name> <change function>: a pass, the change, then the next run.
expect_rerun() {
    new_repo
    run
    "$2"
    local before
    before="$(ran)"
    run
    if [[ $code -ne 0 || $(ran) -ne $((before + 2)) ]] || grep -q reuse "$tmp/out"; then
        fail "$1: the run after the change did not run each stub: code $code, ran $before then $(ran): $(out)"
    fi
}
change_test() { echo '# x' >> "$repo/t/a.test.sh"; commit a; }
change_makefile() { echo '# x' >> "$repo/Makefile"; commit b; }
change_claude() { echo y > "$repo/.claude/settings.json"; commit c; }
change_support() { echo y > "$repo/Support/s.txt"; commit d; }
add_root_file() { echo y > "$repo/new.txt"; commit e; }
remove_floor_path() { git -C "$repo" rm -q Sources/DirigibleCore/PackageLock.swift; commit f; }
change_swift() { FAKE_SWIFT=6.3; }
change_jq() { FAKE_JQ=1.8.0; }
change_date() { FAKE_DATE=2026-10-13; }
expect_rerun '(a) a stub test script' change_test
expect_rerun '(b) the Makefile' change_makefile
expect_rerun '(c) a file under .claude/' change_claude
expect_rerun '(d) a file under Support/' change_support
expect_rerun '(e) a new file at the repo root' add_root_file
expect_rerun '(f) a removed floor path' remove_floor_path
expect_rerun '(g) another tool version' change_swift
expect_rerun '(g) another jq version' change_jq
expect_rerun '(h) another date' change_date

# C2 (i): a pass of a subset of the list writes no stamp, and the next full run runs each test.
new_repo
run HOOK_TESTS=t/a.test.sh
[[ $code -eq 0 && $(ran) -eq 1 && $(stamps) -eq 0 ]] && grep -q '^test-hooks: no stamp (the list is not HOOK_TESTS of the Makefile)$' "$tmp/out" \
    || fail "(i) a subset pass: code $code, ran $(ran), stamps $(stamps): $(out)"
run
[[ $code -eq 0 && $(ran) -eq 3 ]] && ! grep -q reuse "$tmp/out" \
    || fail "(i) the full run after a subset pass did not run each stub: code $code, ran $(ran): $(out)"

# C2 (j): an argument with commas gives one test for each part. A list of two tests of three runs those
# two and writes no stamp. Make takes the whole word as one value of HOOK_TESTS.
new_repo
printf '#!/bin/bash\necho c >> "$HOOKS_LOG"\n' > "$repo/t/c.test.sh"
chmod +x "$repo/t/c.test.sh"
printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh \\\n\tt/c.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
commit three-tests
run HOOK_TESTS=t/a.test.sh,t/b.test.sh
[[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 0 && "$(tr '\n' ' ' < "$tmp/log")" == 'a b ' ]] && grep -q '^test-hooks: no stamp (the list is not HOOK_TESTS of the Makefile)$' "$tmp/out" \
    || fail "(j) a comma list: code $code, ran $(ran), stamps $(stamps): $(out)"

# C3: a change of an excluded path keeps the key. The key holds only the existence of a floor
# path: each hook test passed with each floor file emptied (run 2026-10-12-pipeline-reuse).
new_repo
run
for f in Sources/Other/O.swift Tests/T.swift docs/d.md README.md Sources/DirigibleAudio/A.swift; do
    echo y >> "$repo/$f"
    commit "$f"
    run
    [[ $code -eq 0 && $(ran) -eq 2 ]] && grep -q '^test-hooks: reuse ' "$tmp/out" \
        || fail "excluded paths: a change of $f gave no reuse: code $code, ran $(ran): $(out)"
done

# C4: a dirty tree has a key from its work tree, as a clean tree has one from HEAD. A change of a
# path outside the key keeps the key, and an untracked file in the key gives a new key.
new_repo
run
echo y >> "$repo/README.md"
run
[[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 1 ]] && grep -qE '^test-hooks: reuse [0-9a-f]{64}$' "$tmp/out" \
    || fail "a modified tracked file: code $code, ran $(ran), stamps $(stamps): $(out)"
git -C "$repo" checkout -q README.md
echo y > "$repo/untracked.txt"
run
[[ $code -eq 0 && $(ran) -eq 4 && $(stamps) -eq 2 ]] && grep -qE '^test-hooks: wrote [0-9a-f]{64}$' "$tmp/out" \
    || fail "an untracked file: code $code, ran $(ran), stamps $(stamps): $(out)"

# C16: a pass on a dirty tree is reused after a commit of the same content, and a stray untracked
# file after the pass gives a miss.
new_repo
echo '# x' >> "$repo/Makefile"
run
[[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 1 ]] && grep -qE '^test-hooks: wrote [0-9a-f]{64}$' "$tmp/out" \
    || fail "a dirty pass: code $code, ran $(ran), stamps $(stamps): $(out)"
commit 'same content'
run
[[ $code -eq 0 && $(ran) -eq 2 ]] && grep -qE '^test-hooks: reuse [0-9a-f]{64}$' "$tmp/out" \
    || fail "a dirty pass, then a commit of the same content: code $code, ran $(ran): $(out)"
echo y > "$repo/stray.txt"
run
[[ $code -eq 0 && $(ran) -eq 4 ]] && ! grep -q reuse "$tmp/out" \
    || fail "a stray untracked file after a pass: code $code, ran $(ran): $(out)"

# C4: a red stub test gives exit 1 and no stamp, also with make -i.
new_repo
printf '#!/bin/bash\necho b >> "$HOOKS_LOG"\nfor i in $(seq 50); do echo "b line $i"; done\nexit 1\n' > "$repo/t/b.test.sh"
commit red
run
[[ $code -ne 0 && $(ran) -eq 2 && $(stamps) -eq 0 ]] && grep -q '^test-hooks: 1 of 2 failed: t/b.test.sh$' "$tmp/out" \
    || fail "a red stub: code $code, ran $(ran), stamps $(stamps): $(out)"
# After the failed line, the last 40 lines of the output of each failed test.
sed -n '/^test-hooks: 1 of 2 failed/,$p' "$tmp/out" > "$tmp/tail"
grep -qx 'b line 50' "$tmp/tail" && grep -qx 'b line 11' "$tmp/tail" && ! grep -qx 'b line 10' "$tmp/tail" \
    || fail "a red stub: no last 40 lines after the failed line: $(tr '\n' '|' < "$tmp/tail")"
run -i
[[ $(ran) -eq 4 && $(stamps) -eq 0 ]] || fail "a red stub with make -i: ran $(ran), stamps $(stamps): $(out)"

# C4: with -n, -t, -i, or -q in the first word of MAKEFLAGS, no reuse and no stamp.
new_repo
run
for f in n t i q kq; do
    before="$(ran)"
    (cd "$repo" && MAKEFLAGS="$f" TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" scripts/test-hooks.sh t/a.test.sh t/b.test.sh) > "$tmp/out" 2>&1
    [[ $(ran) -eq $((before + 2)) && $(stamps) -eq 1 ]] && grep -q '^test-hooks: no stamp (make ran with -n, -t, -i, or -q)$' "$tmp/out" \
        || fail "MAKEFLAGS $f: ran $before then $(ran), stamps $(stamps): $(out)"
done

# C4: the key comes from the tree that the tests ran on. A commit during the run that changes a
# key path gives no reuse for the new HEAD.
new_repo
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\necho "# during" >> "$COMMIT_IN/t/b.test.sh"\ngit -C "$COMMIT_IN" commit -qam during\n' > "$repo/t/a.test.sh"
commit during
COMMIT_IN="$repo" run
[[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 1 ]] || fail "commit during the run: the pass: code $code, ran $(ran), stamps $(stamps): $(out)"
git -C "$repo" log -1 --format=%s | grep -qx during || fail "commit during the run: the stub made no commit"
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\n' > "$repo/t/a.test.sh"
commit 'no commit in the stub'
run
[[ $code -eq 0 && $(ran) -eq 4 ]] && ! grep -q reuse "$tmp/out" \
    || fail "commit during the run: the new HEAD got a reuse: code $code, ran $(ran): $(out)"

# C5: the tests run from a key tree with no docs/, so a read of docs/ fails and writes no stamp.
# A dirty tree runs from a key tree too.
new_repo
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\ncat docs/d.md > /dev/null\n' > "$repo/t/a.test.sh"
commit 'outside read'
run
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -q 'failed: t/a.test.sh$' "$tmp/out" \
    || fail "outside read: the clean run passed or wrote a stamp: code $code, stamps $(stamps): $(out)"
echo y > "$repo/untracked.txt"
run
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -q 'failed: t/a.test.sh$' "$tmp/out" \
    || fail "outside read: the dirty run passed or wrote a stamp: code $code, stamps $(stamps): $(out)"

# A run removes each key tree folder over one hour old that a killed run left, and keeps a newer
# one. A stamp append keeps only the lines of today.
new_repo
mkdir "$repo/.git/dirigible-hooks-tree.old" "$repo/.git/dirigible-hooks-tree.new"
touch -t "$(/bin/date -v-2H +%Y%m%d%H%M)" "$repo/.git/dirigible-hooks-tree.old"
printf 'k0 s0 2026-10-11\nk1 s1 2026-10-12\n' > "$stamp"
run
[[ $code -eq 0 && ! -e "$repo/.git/dirigible-hooks-tree.old" && -d "$repo/.git/dirigible-hooks-tree.new" ]] \
    || fail "sweep: code $code, folders [$(ls -d "$repo/.git/dirigible-hooks-tree."* 2>/dev/null | xargs)]: $(out)"
[[ "$(cut -d' ' -f1,3 "$stamp" | head -1)" == 'k1 2026-10-12' && $(stamps) -eq 2 ]] && ! grep -q '^k0 ' "$stamp" \
    || fail "stamp of today only: [$(tr '\n' '|' < "$stamp")]"
rm -rf "$repo/.git/dirigible-hooks-tree.new"

# C5: the key holds only the existence of a floor path, so each floor file is empty in the key
# tree. A test that reads floor content fails on a clean tree and writes no stamp.
new_repo
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\ngrep -q x Sources/DirigibleCore/PackageLock.swift\n' > "$repo/t/a.test.sh"
commit 'floor read'
run
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -q 'failed: t/a.test.sh$' "$tmp/out" \
    || fail "floor read: the clean run passed or wrote a stamp: code $code, stamps $(stamps): $(out)"
[[ -e "$repo/Sources/DirigibleCore/PackageLock.swift" && -s "$repo/Sources/DirigibleCore/PackageLock.swift" ]] \
    || fail 'floor read: the floor file of the repo changed'

# C5: a run, and a run stopped with a signal, leave the shared config, the worktree list, and
# the TMPDIR of the case as before.
new_repo
git -C "$repo" config --list --show-origin > "$tmp/config-before"
git -C "$repo" worktree list > "$tmp/worktrees-before"
same_state() {
    git -C "$repo" config --list --show-origin | cmp -s - "$tmp/config-before" || fail "$1: the shared config changed"
    git -C "$repo" worktree list | cmp -s - "$tmp/worktrees-before" || fail "$1: the worktree list changed"
    [[ -z "$(ls -A "$tmp/own")" ]] || fail "$1: TMPDIR holds $(ls -A "$tmp/own" | tr '\n' ' ')"
    [[ -z "$(find "$repo/.git" -maxdepth 1 -name 'dirigible-hooks-tree.*')" ]] || fail "$1: a key tree folder stays in the git dir"
}
run
[[ $code -eq 0 ]] || fail "no git state left: the run failed: $(out)"
same_state 'no git state left after a run'
printf '#!/bin/bash\ntouch "$HOOKS_MARK"\nsleep 30\n' > "$repo/t/a.test.sh"
commit sleep
git -C "$repo" worktree list > "$tmp/worktrees-before"
set -m
(cd "$repo" && TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" HOOKS_MARK="$tmp/mark" exec scripts/test-hooks.sh t/a.test.sh t/b.test.sh) > "$tmp/out" 2>&1 &
pid=$!
set +m
for _ in $(seq 100); do [[ -e "$tmp/mark" ]] && break; sleep 0.1; done
[[ -e "$tmp/mark" ]] || fail "stopped run: the stub did not start in 10 s"
kill -TERM -- "-$pid" 2>/dev/null
for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
    fail "stopped run: the script did not end in 3 s after the signal"
    kill -KILL -- "-$pid" 2>/dev/null
fi
wait "$pid" 2>/dev/null
same_state 'no git state left after a stopped run'

# C16: a run stopped with TERM during a dirty pass leaves no key tree folder, and the status and
# the real index are as before.
echo y > "$repo/untracked.txt"
rm -f "$tmp/mark"
git -C "$repo" status --porcelain > "$tmp/status-before"
cp "$repo/.git/index" "$tmp/index-before"
set -m
(cd "$repo" && TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" HOOKS_MARK="$tmp/mark" exec scripts/test-hooks.sh t/a.test.sh t/b.test.sh) > "$tmp/out" 2>&1 &
pid=$!
set +m
for _ in $(seq 100); do [[ -e "$tmp/mark" ]] && break; sleep 0.1; done
[[ -e "$tmp/mark" ]] || fail "stopped dirty run: the stub did not start in 10 s"
kill -TERM -- "-$pid" 2>/dev/null
for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
    fail "stopped dirty run: the script did not end in 3 s after the signal"
    kill -KILL -- "-$pid" 2>/dev/null
fi
wait "$pid" 2>/dev/null
same_state 'no git state left after a stopped dirty run'
git -C "$repo" status --porcelain | cmp -s - "$tmp/status-before" || fail "stopped dirty run: git status changed"
cmp -s "$repo/.git/index" "$tmp/index-before" || fail "stopped dirty run: the real index changed"

# C17: no variable of the caller reaches a hook test, PATH and HOME do, and the key tree takes its
# own build lock. The caller sets each variable, and a stub test writes env to a file and then
# runs the with-lock.sh of the key tree.
new_repo
cp "$here/with-lock.sh" "$repo/scripts/"
printf '#!/bin/bash\nenv > "$ENV_FILE"\nPATH="${PATH#"$FAKE_BIN:"}" scripts/with-lock.sh true\n' > "$repo/t/a.test.sh"
commit 'env'
(cd "$repo" && TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" ENV_FILE="$tmp/env" FAKE_BIN="$tmp/bin" \
    BASE=main FILTER=x SINCE=HEAD CHECK_RISK=1 HOOK_TESTS=t/a.test.sh MFLAGS=-s MAKELEVEL=3 \
    GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" GIT_INDEX_FILE="$repo/.git/index" \
    WITH_LOCK_MAX_WAIT=1 WITH_LOCK_OTHER=1 DIRIGIBLE_BUILD_LOCK=$$ DIRIGIBLE_PUSH_CHECK=1 DIRIGIBLE_OTHER=1 \
    make -s test-hooks) > "$tmp/out" 2>&1
code=$?
[[ $code -eq 0 && -f "$tmp/env" ]] || fail "caller context: the run failed: code $code: $(out)"
caller_vars='^(BASE|FILTER|SINCE|CHECK_RISK|HOOK_TESTS|MAKEFLAGS|MFLAGS|MAKELEVEL|GIT_DIR|GIT_INDEX_FILE|GIT_WORK_TREE|WITH_LOCK_[A-Z_]+|DIRIGIBLE_[A-Z_]+)='
[[ -z "$(grep -oE "$caller_vars" "$tmp/env")" ]] \
    || fail "caller context: the stub test saw $(grep -oE "$caller_vars" "$tmp/env" | tr -d '=' | tr '\n' ' ')"
{ grep -q '^PATH=' "$tmp/env" && grep -q '^HOME=' "$tmp/env"; } || fail 'caller context: PATH or HOME is not in the env of the stub test'

[[ $failures -eq 0 ]] || { echo "$failures failure(s)"; exit 1; }
echo "test-hooks.test.sh: all passed"
