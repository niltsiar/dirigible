#!/bin/bash
# Check scripts/test-hooks.sh, the pass stamp of make test-hooks: a reuse with the same key (C1),
# a new run after a change of each key input (C2), a reuse after a change of an excluded path
# (C3), no stamp and no reuse on a dirty tree, a red test, or a make flag (C4), and a run from a
# key tree that fails on a read outside the key and leaves no git state (C5). Each case uses a
# stub repo whose two stub tests append their name to a log, fake swift, xcodebuild, jq, sw_vers,
# and date on PATH, and its own TMPDIR. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
# A make value of an outer run (make test-hooks) must not reach the stub make.
unset MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
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
    mkdir -p "$tmp/own" "$repo/scripts" "$repo/t" "$repo/.claude" "$repo/Support" "$repo/Tests" "$repo/docs" \
        "$repo/Sources/DirigibleAudio" "$repo/Sources/DirigibleCore" "$repo/Sources/Other"
    git -C "$repo" init -q -b main
    cp "$here/test-hooks.sh" "$here/check-changed.sh" "$repo/scripts/"
    printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
    for n in a b; do printf '#!/bin/bash\necho %s >> "$HOOKS_LOG"\n' "$n" > "$repo/t/$n.test.sh"; done
    chmod +x "$repo/t/"*.sh
    for f in Sources/DirigibleAudio/A.swift Sources/DirigibleCore/SessionReader.swift Sources/DirigibleCore/SessionWriter.swift \
        Sources/DirigibleCore/PackageLock.swift Sources/Other/O.swift Tests/T.swift docs/d.md README.md .claude/settings.json Support/s.txt; do
        echo x > "$repo/$f"
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

# C4: a dirty tree runs the tests in place, with no reuse and no stamp.
new_repo
run
echo y >> "$repo/README.md"
run
[[ $code -eq 0 && $(ran) -eq 4 && $(stamps) -eq 1 ]] && grep -q '^test-hooks: no stamp (the tree is dirty)$' "$tmp/out" \
    && ! grep -q reuse "$tmp/out" || fail "a modified tracked file: code $code, ran $(ran), stamps $(stamps): $(out)"
git -C "$repo" checkout -q README.md
echo y > "$repo/untracked.txt"
run
[[ $code -eq 0 && $(ran) -eq 6 && $(stamps) -eq 1 ]] && grep -q '^test-hooks: no stamp (the tree is dirty)$' "$tmp/out" \
    && ! grep -q reuse "$tmp/out" || fail "an untracked file: code $code, ran $(ran), stamps $(stamps): $(out)"

# C4: a red stub test gives exit 1 and no stamp, also with make -i.
new_repo
printf '#!/bin/bash\necho b >> "$HOOKS_LOG"\nexit 1\n' > "$repo/t/b.test.sh"
commit red
run
[[ $code -ne 0 && $(ran) -eq 2 && $(stamps) -eq 0 ]] && grep -q '^test-hooks: 1 of 2 failed: t/b.test.sh$' "$tmp/out" \
    || fail "a red stub: code $code, ran $(ran), stamps $(stamps): $(out)"
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

# C5: on a clean tree the tests run from a key tree with no docs/, so a read of docs/ fails and
# writes no stamp. On a dirty tree the same test runs in place and passes.
new_repo
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\ncat docs/d.md > /dev/null\n' > "$repo/t/a.test.sh"
commit 'outside read'
run
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -q 'failed: t/a.test.sh$' "$tmp/out" \
    || fail "outside read: the clean run passed or wrote a stamp: code $code, stamps $(stamps): $(out)"
echo y > "$repo/untracked.txt"
run
[[ $code -eq 0 ]] || fail "outside read: the run in place failed: code $code: $(out)"

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

[[ $failures -eq 0 ]] || { echo "$failures failure(s)"; exit 1; }
echo "test-hooks.test.sh: all passed"
