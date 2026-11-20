#!/bin/bash
# Check scripts/test-hooks.sh, the pass stamp of make test-hooks: a reuse with the same key (C1),
# a new run after a change of each key input (C2), a reuse after a change of an excluded path
# (C3), a key from the work tree on a dirty tree (C16), no stamp after a red test or a make flag
# (C4), and a run from a key tree that fails on a read outside the key and leaves no git state
# (C5), and a refusal of the whole list outside the push check, with no stamp reuse before it
# (C6), and HOOK_CASES: no stamp and no reuse, and an exit 1 with a push check or a hooks pass (C10),
# and a hook test that runs bash on /bin/bash whatever bash the PATH holds first, and the label
# guardrails-rules that a narrow HOOK_CASES run gets after a change of the hook, and a test whose
# output has a line that ends in ": command not found" failing.
# Each case uses a stub repo whose two stub tests append their name to a log, fake swift,
# xcodebuild, jq, sw_vers, and date on PATH, and its own TMPDIR. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
# A make value of an outer run (make test-hooks) must not reach the stub make.
unset MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE SINCE DIRIGIBLE_PUSH_CHECK DIRIGIBLE_HOOKS_ALL \
    HOOK_CASES HOOK_JOBS HOOK_JOBS_PROBE
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
printf '#!/bin/bash\n[[ "$*" == "-n hw.ncpu" ]] || { echo "fake sysctl: $*" >&2; exit 2; }\necho "$FAKE_NCPU"\n' > "$tmp/bin/sysctl"
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
    cp "$here/test-hooks.sh" "$here/check-changed.sh" "$here/swift-suites.sh" "$repo/scripts/"
    printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
    for n in a b; do printf '#!/bin/bash\necho %s >> "$HOOKS_LOG"\n' "$n" > "$repo/t/$n.test.sh"; done
    chmod +x "$repo/t/"*.sh
    local floor_paths
    floor_paths="$("$here/check-changed.sh" --floor)"
    # Guards the stub setup, not a hook case: with no floor path, the loop below makes no floor stub.
    [[ -n $floor_paths ]] || fail "stub setup: --floor prints no path"
    for f in $floor_paths; do
        [[ $f == */ ]] && f="${f}A.swift"
        mkdir -p "$repo/$(dirname "$f")"
        echo x > "$repo/$f"
    done
    for f in Sources/Other/O.swift Tests/T.swift docs/d.md README.md .claude/settings.json Support/s.txt; do
        echo x > "$repo/$f"
    done
    commit init
    export FAKE_SWIFT=6.2.4 FAKE_JQ=1.7.1 FAKE_DATE=2026-10-12 FAKE_NCPU=8
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

# C10: HOOK_CASES thins the cases of a hook test, so a run with it writes no stamp and reuses none,
# and a push check or a hooks pass with it exits 1 before any test. A stub test writes the value
# that it gets, so a make command line value reaches the test as it is.
new_repo
run_with DIRIGIBLE_FULL_SUITE=1 --
run_with DIRIGIBLE_FULL_SUITE=1 HOOK_CASES=agent-clock --
[[ $code -eq 0 && $(ran) -eq 4 && $(stamps) -eq 1 ]] && ! grep -q reuse "$tmp/out" && grep -q '^test-hooks: no stamp' "$tmp/out" \
    || fail "(C10) HOOK_CASES with a stamp of the key: the run reused it or wrote a stamp: code $code, ran $(ran), stamps $(stamps): $(out)"
new_repo
run_with DIRIGIBLE_FULL_SUITE=1 HOOK_CASES=agent-clock --
[[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 0 ]] \
    || fail "(C10) HOOK_CASES with no stamp: code $code, ran $(ran), stamps $(stamps): $(out)"
for sw in DIRIGIBLE_PUSH_CHECK DIRIGIBLE_HOOKS_ALL; do
    new_repo
    run_with "$sw=1" HOOK_CASES=agent-clock --
    [[ $code -ne 0 && $(ran) -eq 0 && $(stamps) -eq 0 ]] && grep -q HOOK_CASES "$tmp/out" \
        || fail "(C10) $sw=1 with HOOK_CASES: code $code, ran $(ran), stamps $(stamps): $(out)"
    run_with "$sw=1" --
    [[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 1 ]] \
        || fail "(C10) $sw=1 with no HOOK_CASES: code $code, ran $(ran), stamps $(stamps): $(out)"
done
new_repo
printf '#!/bin/bash\nprintf "%%s" "${HOOK_CASES-unset}" > "$HOOKS_LOG.cases"\n' > "$repo/t/a.test.sh"
commit cases-echo
git -C "$repo" update-ref refs/remotes/origin/main HEAD
run_with DIRIGIBLE_FULL_SUITE=1 -- 'HOOK_CASES=agent-clock|write-guard'
[[ $code -eq 0 && "$(cat "$tmp/log.cases" 2>/dev/null)" == 'agent-clock|write-guard' ]] \
    || fail "(C10) make did not pass HOOK_CASES unchanged: code $code, value [$(cat "$tmp/log.cases" 2>&1)]: $(out)"

# Label: a narrow HOOK_CASES run adds guardrails-rules when the work tree differs from the merge base
# with origin/main in git-guardrails.sh or lock-words.sh (the hook sources lock-words.sh), and adds it
# with no merge base. A stub test writes the HOOK_CASES that it gets.
label_repo() { # [with-origin] <changed path>...
    local origin=no p
    [[ ${1:-} == with-origin ]] && { origin=yes; shift; }
    new_repo
    printf '#!/bin/bash\nprintf "%%s" "${HOOK_CASES-unset}" > "$HOOKS_LOG.cases"\n' > "$repo/t/a.test.sh"
    commit cases-echo
    [[ $origin == no ]] || git -C "$repo" update-ref refs/remotes/origin/main HEAD
    for p in "$@"; do mkdir -p "$repo/$(dirname "$p")"; echo x >> "$repo/$p"; done
    [[ $# -eq 0 ]] || commit change
}
cases_got() { # <HOOK_CASES value or -> : the value that the stub test got
    if [[ $1 == - ]]; then run_with DIRIGIBLE_FULL_SUITE=1 --; else run_with DIRIGIBLE_FULL_SUITE=1 "HOOK_CASES=$1" --; fi
    [[ $code -eq 0 ]] || { echo "exit $code: $(out)"; return; }
    cat "$tmp/log.cases"
}
expect_cases() { # <name> <want> <HOOK_CASES value or -> : <changed paths>
    local name="$1" want="$2" value="$3" got
    got="$(cases_got "$value")"
    [[ $got == "$want" ]] || fail "(label) $name: got [$got], want [$want]"
}
label_repo with-origin .claude/hooks/git-guardrails.sh
expect_cases 'the hook changed' 'release-wait|guardrails-rules' release-wait
expect_cases 'the label added once to a pattern that lists it' 'guardrails-rules|release-wait' 'guardrails-rules|release-wait'
expect_cases 'a pattern that matches the label' 'guardrails-.*' 'guardrails-.*'
expect_cases 'no HOOK_CASES' unset -
label_repo with-origin scripts/lock-words.sh
expect_cases 'only lock-words.sh changed' 'release-wait|guardrails-rules' release-wait
label_repo with-origin docs/d2.md scripts/other.sh
expect_cases 'only a doc and another script changed' 'release-wait' release-wait
label_repo with-origin
mkdir -p "$repo/.claude/hooks" && echo x >> "$repo/.claude/hooks/git-guardrails.sh"
expect_cases 'an uncommitted hook change' 'release-wait|guardrails-rules' release-wait
label_repo with-origin
printf 'u\n' > "$repo/scripts/lock-words.sh"
expect_cases 'an untracked lock-words.sh' 'release-wait|guardrails-rules' release-wait
label_repo docs/d2.md
expect_cases 'no merge base' 'release-wait|guardrails-rules' release-wait

# Not found: a line that ends in ": command not found" fails the test that printed it, also when it
# exits 0 (a hook test whose helper is missing runs on, and passes without the case that needed it).
# The summary names the test and the line. A line "x not found" passes.
new_repo
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\necho "line 3: nosuchtool: command not found"\n' > "$repo/t/a.test.sh"
commit not-found
run_with DIRIGIBLE_FULL_SUITE=1 --
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -q '^test-hooks: 1 of 2 failed: t/a.test.sh$' "$tmp/out" \
    && grep -qF 'test-hooks: t/a.test.sh printed a command not found line: line 3: nosuchtool: command not found' "$tmp/out" \
    || fail "(not-found) a test that exits 0 with a command not found line: code $code, stamps $(stamps): $(out)"
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\necho "nosuchtool not found"\n' > "$repo/t/a.test.sh"
commit near-not-found
run_with DIRIGIBLE_FULL_SUITE=1 --
[[ $code -eq 0 && $(stamps) -eq 1 ]] || fail "(not-found) the near line 'x not found': code $code, stamps $(stamps): $(out)"

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

# The sweep keeps an old key tree folder whose pid file names a live process (a long run of another
# call) and removes one whose pid is dead.
new_repo
sleep 60 & live_pid=$!
true & dead_pid=$!
wait "$dead_pid"
mkdir "$repo/.git/dirigible-hooks-tree.live" "$repo/.git/dirigible-hooks-tree.dead"
echo "$live_pid" > "$repo/.git/dirigible-hooks-tree.live/pid"
echo "$dead_pid" > "$repo/.git/dirigible-hooks-tree.dead/pid"
touch -t "$(/bin/date -v-2H +%Y%m%d%H%M)" "$repo/.git/dirigible-hooks-tree.live" "$repo/.git/dirigible-hooks-tree.dead"
run
kill "$live_pid" 2>/dev/null
[[ $code -eq 0 && -d "$repo/.git/dirigible-hooks-tree.live" && ! -e "$repo/.git/dirigible-hooks-tree.dead" ]] \
    || fail "sweep pid: code $code, folders [$(ls -d "$repo/.git/dirigible-hooks-tree."* 2>/dev/null | xargs)]: $(out)"
rm -rf "$repo/.git/dirigible-hooks-tree.live"

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
# own build lock. The caller sets each variable, and a stub test writes env to a file, takes the
# fake tools off its PATH wherever they sit, and runs the with-lock.sh of the key tree.
new_repo
cp "$here/with-lock.sh" "$here/lock-words.sh" "$repo/scripts/"
cat > "$repo/t/a.test.sh" <<'STUB'
#!/bin/bash
env > "$ENV_FILE"
p=":$PATH:"
p="${p//:$FAKE_BIN:/:}"
p="${p#:}"
PATH="${p%:}"
command -v date > "$ENV_FILE.date"
scripts/with-lock.sh true
STUB
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
[[ -s "$tmp/env.date" && "$(cat "$tmp/env.date")" != "$tmp/bin/date" ]] || fail "caller context: with-lock.sh got the fake date of the test PATH: $(cat "$tmp/env.date" 2>&1)"

# A hook test that runs `bash` gets /bin/bash, not the first bash on the PATH of the caller, and a
# pass is reused when only the PATH bash differs: the key holds no bash version.
new_repo
mkdir "$tmp/fakebash" "$tmp/fakebash2"
printf '#!/bin/sh\necho fake-bash\n' > "$tmp/fakebash/bash"
printf '#!/bin/sh\necho fake-bash-two\n' > "$tmp/fakebash2/bash"
chmod +x "$tmp/fakebash/bash" "$tmp/fakebash2/bash"
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\nbash -c '\''echo "$BASH_VERSION"'\'' > "$HOOKS_LOG.bash"\n' > "$repo/t/a.test.sh"
commit 'bash version'
(cd "$repo" && PATH="$tmp/fakebash:$PATH" TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" make -s test-hooks) > "$tmp/out" 2>&1
code=$?
want="$(/bin/bash -c 'echo "$BASH_VERSION"')"
[[ $code -eq 0 && "$(cat "$tmp/log.bash" 2>/dev/null)" == "$want" ]] \
    || fail "PATH bash: a hook test did not run /bin/bash: code $code, got [$(cat "$tmp/log.bash" 2>&1)], want [$want]: $(out)"
(cd "$repo" && PATH="$tmp/fakebash2:$PATH" TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" make -s test-hooks) > "$tmp/out" 2>&1
code=$?
[[ $code -eq 0 && $(ran) -eq 2 ]] && grep -qE '^test-hooks: reuse [0-9a-f]{64}$' "$tmp/out" \
    || fail "PATH bash: another PATH bash did not reuse the pass: code $code, ran $(ran): $(out)"

# Jobs: under the build lock the runner runs up to ncpu / 2 tests at a time. The cases fake the lock
# (a lock folder with a pid file in the git dir, and the same value in DIRIGIBLE_BUILD_LOCK) and
# sysctl (FAKE_NCPU).
lock_value=4242
fake_lock() { mkdir -p "$repo/.git/dirigible-build.lock" && echo "$lock_value" > "$repo/.git/dirigible-build.lock/pid"; }
# pair_stub <name> <other>: a stub test that records its clone, writes its mark, and waits up to
# HOOKS_WAIT tenths of a second for the mark of the other test, which it fails without.
pair_stub() {
    cat <<'STUB' | sed "s/NAME/$1/g; s/OTHER/$2/g"
#!/bin/bash
echo NAME >> "$HOOKS_LOG"
git rev-parse --show-toplevel > "$HOOKS_MARKS/top-NAME"
git rev-parse --path-format=absolute --git-common-dir > "$HOOKS_MARKS/common-NAME"
touch "$HOOKS_MARKS/NAME"
for _ in $(seq "$HOOKS_WAIT"); do [[ -e "$HOOKS_MARKS/OTHER" ]] && exit 0; sleep 0.1; done
exit 1
STUB
}
pair_repo() {
    new_repo
    pair_stub a b > "$repo/t/a.test.sh"
    pair_stub b a > "$repo/t/b.test.sh"
    commit pair
    rm -rf "$tmp/marks" && mkdir "$tmp/marks"
}
locked=(DIRIGIBLE_BUILD_LOCK="$lock_value" DIRIGIBLE_FULL_SUITE=1)
marks=(HOOKS_MARKS="$tmp/marks")

# Jobs C1: two tests that wait for the mark of each other pass with 2 jobs, and one job fails the
# first of them.
pair_repo; fake_lock
run_with "${locked[@]}" "${marks[@]}" HOOK_JOBS=2 HOOKS_WAIT=150 --
[[ $code -eq 0 && $(ran) -eq 2 ]] || fail "(jobs C1) two tests at 2 jobs did not run at once: code $code, ran $(ran): $(out)"
pair_repo; fake_lock
run_with "${locked[@]}" "${marks[@]}" HOOK_JOBS=1 HOOKS_WAIT=20 --
[[ $code -ne 0 ]] && grep -q '^test-hooks: 1 of 2 failed: t/a.test.sh$' "$tmp/out" \
    || fail "(jobs C1) two tests at 1 job: code $code: $(out)"

# Jobs C2: the job count. expect_jobs <name> <want> <lock> <env word>..., where <lock> is held, other,
# none, novar, or a lock-free file: hooks, plain (no kind), or other-hooks (of another pid).
jobs_line() { sed -n 's/^test-hooks: [0-9]* tests, \([0-9]*\) jobs$/\1/p' "$tmp/out"; }
expect_jobs() {
    local name="$1" want="$2" mode="$3"
    shift 3
    new_repo
    local lockenv=("DIRIGIBLE_BUILD_LOCK=$lock_value" DIRIGIBLE_FULL_SUITE=1)
    case "$mode" in
        held) fake_lock ;;
        other) fake_lock; lockenv=("DIRIGIBLE_BUILD_LOCK=$((lock_value + 1))" DIRIGIBLE_FULL_SUITE=1) ;;
        none) ;;
        novar) fake_lock; lockenv=(DIRIGIBLE_FULL_SUITE=1) ;;
        hooks | plain | other-hooks)
            mkdir -p "$repo/.git/dirigible-lock-free"
            local kind=hooks pid=4243
            [[ $mode != plain ]] || kind=""
            [[ $mode != other-hooks ]] || pid=4244
            printf 'start\nmake test-hooks DIRIGIBLE_HOOKS_ALL=1\n%s\n' "$kind" > "$repo/.git/dirigible-lock-free/4243"
            lockenv=("DIRIGIBLE_HOOKS_PASS=$pid" DIRIGIBLE_HOOKS_ALL=1) ;;
    esac
    run_with "${lockenv[@]}" "$@" --
    [[ $code -eq 0 && "$(jobs_line)" == "$want" ]] || fail "(jobs C2) $name: want $want jobs: code $code, got [$(jobs_line)]: $(out)"
}
expect_jobs 'lock held, 8 cpus' 4 held
expect_jobs 'lock held, 1 cpu' 1 held FAKE_NCPU=1
expect_jobs 'lock held, 3 cpus' 1 held FAKE_NCPU=3
expect_jobs 'a pid that is not the lock pid' 1 other
expect_jobs 'no lock folder' 1 none
expect_jobs 'no lock variable' 1 novar
expect_jobs 'HOOK_JOBS=3 under the lock' 3 held HOOK_JOBS=3
expect_jobs 'HOOK_JOBS=1 under the lock' 1 held HOOK_JOBS=1
expect_jobs 'HOOK_JOBS=3 with no lock' 1 none HOOK_JOBS=3
grep -qxF 'test-hooks: HOOK_JOBS=3 needs the build lock; 1 job' "$tmp/out" \
    || fail "(jobs C2) HOOK_JOBS=3 with no lock: no needs-the-lock line: $(out)"
expect_jobs 'HOOK_JOBS=3 with the probe override and no lock' 3 none HOOK_JOBS=3 HOOK_JOBS_PROBE=1
# The lock-free hooks pass of with-lock.sh (DIRIGIBLE_HOOKS_PASS names its lock-free file of the
# kind hooks) runs ncpu / 2 jobs, or HOOK_JOBS; a file of no kind, or of another pid, gives 1 job.
expect_jobs 'the lock-free hooks pass, 8 cpus' 4 hooks
expect_jobs 'the lock-free hooks pass, HOOK_JOBS=3' 3 hooks HOOK_JOBS=3
expect_jobs 'a lock-free file of no kind' 1 plain
expect_jobs 'a hooks file of another pid' 1 other-hooks
for bad in 0 x 01 -1 2.5 ''; do
    new_repo; fake_lock
    run_with "${locked[@]}" "HOOK_JOBS=$bad" --
    [[ $code -eq 2 && $(ran) -eq 0 && $(stamps) -eq 0 ]] && grep -q 'HOOK_JOBS' "$tmp/out" \
        || fail "(jobs C2) HOOK_JOBS='$bad' did not exit 2 with a message: code $code, ran $(ran): $(out)"
done

# Jobs C3: each test prints a start line at once. The output of a test comes as one block after its
# status line, in list order, also when the second test ends first.
new_repo; fake_lock
printf '#!/bin/bash\nfor _ in $(seq 150); do [[ -e "$HOOKS_MARKS/b-end" ]] && break; sleep 0.1; done\necho a-out-1\necho a-out-2\n' > "$repo/t/a.test.sh"
printf '#!/bin/bash\necho b-out-1\necho b-out-2\ntouch "$HOOKS_MARKS/b-end"\n' > "$repo/t/b.test.sh"
commit order
rm -rf "$tmp/marks" && mkdir "$tmp/marks"
run_with "${locked[@]}" "${marks[@]}" HOOK_JOBS=2 --
got="$(grep -E '^(test-hooks: (start|t/)|[ab]-out)' "$tmp/out" | sed 's/ in [0-9]* s$/ in S s/' | tr '\n' '|')"
want='test-hooks: start t/a.test.sh|test-hooks: start t/b.test.sh|test-hooks: t/a.test.sh passed in S s|a-out-1|a-out-2|test-hooks: t/b.test.sh passed in S s|b-out-1|b-out-2|'
[[ $code -eq 0 && $got == "$want" ]] || fail "(jobs C3) the order of the lines: code $code, got [$got]"
tail -n 1 "$tmp/out" | grep -qE '^test-hooks: 2 tests in [0-9]+ s, 2 jobs$' || fail "(jobs C3) the last line is not the time line: $(tail -n 1 "$tmp/out")"

# Jobs C4: the summary and the exit status are those of one job: with 3 tests at 2 jobs, a red
# second test and a third test that prints a command not found line exit 1, name both in list order,
# print the last 40 lines of each, and write no stamp.
new_repo; fake_lock
printf '#!/bin/bash\necho b >> "$HOOKS_LOG"\nfor i in $(seq 50); do echo "b line $i"; done\nexit 1\n' > "$repo/t/b.test.sh"
printf '#!/bin/bash\necho c >> "$HOOKS_LOG"\nfor i in $(seq 49); do echo "c line $i"; done\necho "line 3: nosuchtool: command not found"\n' > "$repo/t/c.test.sh"
chmod +x "$repo/t/c.test.sh"
printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh \\\n\tt/c.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
commit three-red
run_with "${locked[@]}" HOOK_JOBS=2 --
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -qx 'test-hooks: 2 of 3 failed: t/b.test.sh t/c.test.sh' "$tmp/out" \
    && grep -qxF 'test-hooks: t/c.test.sh printed a command not found line: line 3: nosuchtool: command not found' "$tmp/out" \
    || fail "(jobs C4) two red tests at 2 jobs: code $code, stamps $(stamps): $(out)"
sed -n '/^test-hooks: 2 of 3 failed/,$p' "$tmp/out" > "$tmp/tail"
grep -qx 'b line 50' "$tmp/tail" && grep -qx 'b line 11' "$tmp/tail" && ! grep -qx 'b line 10' "$tmp/tail" \
    && grep -qx 'c line 49' "$tmp/tail" && grep -qx 'c line 11' "$tmp/tail" && ! grep -qx 'c line 10' "$tmp/tail" \
    || fail "(jobs C4) the last 40 lines of each red test: $(tr '\n' '|' < "$tmp/tail")"

# Jobs C5: TERM stops both running tests: the stopped line and the last lines of each test print,
# no test process stays, no key tree stays, and the exit is 143. A TERM to the process group and a
# TERM to the script alone give the same result.
stop_case() { # <name> <group|script>
    local name="$1" target="$2" s
    new_repo; fake_lock
    for n in a b; do
        printf '#!/bin/bash\necho %s-line\nsleep 120 &\necho $! > "$HOOKS_MARKS/%s.sleep"\ntouch "$HOOKS_MARKS/%s"\nwait\n' "$n" "$n" "$n" > "$repo/t/$n.test.sh"
    done
    commit hang
    rm -rf "$tmp/marks" && mkdir "$tmp/marks"
    git -C "$repo" config --list --show-origin > "$tmp/config-before"
    git -C "$repo" worktree list > "$tmp/worktrees-before"
    set -m
    (cd "$repo" && TMPDIR="$tmp/own" HOOKS_LOG="$tmp/log" HOOKS_MARKS="$tmp/marks" DIRIGIBLE_BUILD_LOCK="$lock_value" HOOK_JOBS=2 \
        exec scripts/test-hooks.sh t/a.test.sh t/b.test.sh) > "$tmp/out" 2>&1 &
    pid=$!
    set +m
    for _ in $(seq 300); do [[ -e "$tmp/marks/a" && -e "$tmp/marks/b" ]] && break; sleep 0.1; done
    [[ -e "$tmp/marks/a" && -e "$tmp/marks/b" ]] || { fail "($name) both tests did not start in 30 s"; kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return; }
    grep -qx 'test-hooks: start t/a.test.sh' "$tmp/out" && grep -qx 'test-hooks: start t/b.test.sh' "$tmp/out" \
        || fail "($name) no start line of each test before the signal: $(out)"
    if [[ $target == group ]]; then kill -TERM -- "-$pid" 2>/dev/null; else kill -TERM "$pid" 2>/dev/null; fi
    for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
        fail "($name) the script did not end in 10 s after the signal"
        kill -KILL -- "-$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null
    local rc=$?
    [[ $rc -eq 143 ]] || fail "($name) exit $rc, want 143"
    for n in a b; do
        s="$(cat "$tmp/marks/$n.sleep" 2>/dev/null)"
        if [[ -n $s ]] && kill -0 "$s" 2>/dev/null; then fail "($name) the sleep of test $n is alive"; kill -KILL "$s" 2>/dev/null; fi
        grep -qx "test-hooks: stopped while t/$n.test.sh ran" "$tmp/out" && grep -qx "$n-line" "$tmp/out" \
            || fail "($name) no stopped line or log line of test $n: $(out)"
    done
    same_state "$name"
}
stop_case '(jobs C5) a TERM to the process group' group
stop_case '(jobs C5) a TERM to the script alone' script

# Jobs C6: two tests that run at the same time run in two clones of the key commit, both in the
# folder of the run and neither the repo.
pair_repo; fake_lock
run_with "${locked[@]}" "${marks[@]}" HOOK_JOBS=2 HOOKS_WAIT=150 --
physical="$(cd "$repo" && pwd -P)"
top_a="$(cat "$tmp/marks/top-a" 2>/dev/null)" top_b="$(cat "$tmp/marks/top-b" 2>/dev/null)"
common_a="$(cat "$tmp/marks/common-a" 2>/dev/null)" common_b="$(cat "$tmp/marks/common-b" 2>/dev/null)"
[[ $code -eq 0 && -n $top_a && $top_a != "$top_b" && $top_a == "$physical"/.git/dirigible-hooks-tree.*/* \
    && $top_b == "$physical"/.git/dirigible-hooks-tree.*/* ]] \
    || fail "(jobs C6) the two tests did not run in two clones of the run: code $code, [$top_a] [$top_b]: $(out)"
[[ -n $common_a && $common_a != "$common_b" && $common_a != "$physical/.git" && $common_b != "$physical/.git" ]] \
    || fail "(jobs C6) a clone shares the git dir of the repo or of the other clone: [$common_a] [$common_b]"

# Jobs C7: the job count is no part of the key, a red pass at 2 jobs writes no stamp, and 5 tests at
# 4 jobs each run once.
new_repo; fake_lock
run_with "${locked[@]}" HOOK_JOBS=1 --
run_with "${locked[@]}" HOOK_JOBS=4 --
[[ $code -eq 0 && $(ran) -eq 2 && $(stamps) -eq 1 ]] && grep -qE '^test-hooks: reuse [0-9a-f]{64}$' "$tmp/out" \
    || fail "(jobs C7) a pass at 4 jobs after a pass at 1 job did not reuse it: code $code, ran $(ran): $(out)"
new_repo; fake_lock
printf '#!/bin/bash\necho b >> "$HOOKS_LOG"\nexit 1\n' > "$repo/t/b.test.sh"
commit red
run_with "${locked[@]}" HOOK_JOBS=2 --
[[ $code -ne 0 && $(ran) -eq 2 && $(stamps) -eq 0 ]] || fail "(jobs C7) a red pass at 2 jobs: code $code, ran $(ran), stamps $(stamps): $(out)"
new_repo; fake_lock
for n in c d e; do
    printf '#!/bin/bash\necho %s >> "$HOOKS_LOG"\n' "$n" > "$repo/t/$n.test.sh"
    chmod +x "$repo/t/$n.test.sh"
done
printf 'HOOK_TESTS = \\\n\tt/a.test.sh \\\n\tt/b.test.sh \\\n\tt/c.test.sh \\\n\tt/d.test.sh \\\n\tt/e.test.sh\n\ntest-hooks:\n\tscripts/test-hooks.sh $(HOOK_TESTS)\n' > "$repo/Makefile"
commit five-tests
run_with "${locked[@]}" HOOK_JOBS=4 --
[[ $code -eq 0 && $(ran) -eq 5 && "$(sort "$tmp/log" | tr '\n' ' ')" == 'a b c d e ' ]] \
    || fail "(jobs C7) 5 tests at 4 jobs did not run each once: code $code, log [$(sort "$tmp/log" 2>&1 | tr '\n' ' ')]: $(out)"

# Jobs C19: a hook test sees neither HOOK_JOBS nor HOOK_JOBS_PROBE of the caller.
new_repo; fake_lock
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\necho "${HOOK_JOBS-unset} ${HOOK_JOBS_PROBE-unset}" > "$HOOKS_LOG.jobs"\n' > "$repo/t/a.test.sh"
commit jobs-env
run_with "${locked[@]}" HOOK_JOBS=2 HOOK_JOBS_PROBE=1 --
[[ $code -eq 0 && "$(cat "$tmp/log.jobs" 2>/dev/null)" == 'unset unset' ]] \
    || fail "(jobs C19) a hook test read HOOK_JOBS or HOOK_JOBS_PROBE: code $code, got [$(cat "$tmp/log.jobs" 2>&1)]: $(out)"

# Jobs: a job starts with SIGINT at its default, as a test in the foreground does, so a test that
# signals its own child with INT (set -m, as with-lock.test.sh) sees the child die with 130.
new_repo; fake_lock
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\nset -m\nsh -c '\''kill -INT $$; echo survived'\'' > /dev/null &\nwait $!\necho $? > "$HOOKS_LOG.int"\n' > "$repo/t/a.test.sh"
commit int-child
run_with "${locked[@]}" HOOK_JOBS=2 --
[[ $code -eq 0 && "$(cat "$tmp/log.int" 2>/dev/null)" == 130 ]] \
    || fail "(jobs INT) a child of a job test ignored INT: code $code, got [$(cat "$tmp/log.int" 2>&1)]: $(out)"

# Jobs: only a status of exactly 0 is a pass. The first test plants an empty status file for itself
# (the file that a job creates before it writes the value) and runs on: the runner fails it.
new_repo; fake_lock
printf '#!/bin/bash\necho a >> "$HOOKS_LOG"\nlog="$(lsof -p $$ -a -d 1 -Fn | sed -n "s/^n//p")"\n: > "${log/.log/.status}"\nsleep 3\n' > "$repo/t/a.test.sh"
printf '#!/bin/bash\necho b >> "$HOOKS_LOG"\nsleep 5\n' > "$repo/t/b.test.sh"
commit empty-status
run_with "${locked[@]}" HOOK_JOBS=2 --
[[ $code -ne 0 && $(stamps) -eq 0 ]] && grep -qx 'test-hooks: 1 of 2 failed: t/a.test.sh' "$tmp/out" \
    || fail "(jobs status) an empty status file passed: code $code, stamps $(stamps): $(out)"

[[ $failures -eq 0 ]] || { echo "$failures failure(s)"; exit 1; }
echo "test-hooks.test.sh: all passed"
