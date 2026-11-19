#!/bin/bash
# Runs the hook and script tests of make test-hooks, and reuses a pass with the same input key.
# Usage: scripts/test-hooks.sh <test script>...
#   Only the test-hooks recipe of the Makefile calls it, with the HOOK_TESTS list. An argument can
#   hold several tests joined with commas: scripts/check-changed.sh gives make one HOOK_TESTS word
#   for the tests of the changed paths, and make passes that word as one argument. Each part is a
#   test. A list of some of the tests gets no stamp. The whole list (that of the Makefile at HEAD,
#   or that of the Makefile in the work tree) runs only when one of these is set to 1:
#   DIRIGIBLE_PUSH_CHECK (the push check), DIRIGIBLE_FULL_SUITE (a person), or DIRIGIBLE_HOOKS_ALL
#   (scripts/check-changed.sh gives it to a local run that needs the whole list). Else the script
#   prints the reason and exits 1, before the key and the stamp reuse. Before the first test, the
#   script unsets BASE, FILTER, SINCE, CHECK_RISK, HOOK_TESTS, MAKEFLAGS, MFLAGS, MAKELEVEL,
#   GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE, HOOK_JOBS, HOOK_JOBS_PROBE, and each variable that
#   starts with WITH_LOCK_ or DIRIGIBLE_ (make and the caller put them in the environment of each
#   recipe), so no hook test reads the context of its caller. PATH and HOME stay, and so does
#   HOOK_CASES (below). A test that needs one of them sets it itself.
# Jobs: while the caller holds the build lock (DIRIGIBLE_BUILD_LOCK equals the pid in the lock
#   folder of the git common dir), the script runs HOOK_JOBS tests at a time, else ncpu / 2 (at
#   least 1). With no lock it runs 1 test at a time, and a HOOK_JOBS over 1 prints a line that says
#   so: a lock-free call must not load the machine. HOOK_JOBS_PROBE=1 takes HOOK_JOBS with no lock
#   (a probe of the 4-job load). A HOOK_JOBS that is not a whole number of 1 or more exits 2, before
#   the key. The job count is no part of the key. Each job slot has its own clone of the key
#   commit, and each test runs in the process group of the script, with SIGINT at its default. The
#   script prints "test-hooks: start <test>" at the start of a test, and the output of each test
#   whole, in list order, after "test-hooks: <test> <passed|FAILED> in <s> s". The last line is
#   "test-hooks: <N> tests in <s> s, <J> jobs". TERM or INT prints "test-hooks: stopped while
#   <test> ran" and the last 20 lines of the log of each running test, and stops each of them.
# The key is the tree of the work tree with no Sources/, Tests/, docs/, or README.md, plus the
# existence of each floor path of scripts/check-changed.sh --floor, the sorted test list, the tool
# versions, and the date: a pass is good for one day. The tests run `bash` as /bin/bash (a link first
# on their PATH), so the key holds no bash version. The tree is HEAD with the changes of a dirty
# tree and its untracked files that no ignore rule hides: git add -A on a copy of the real index
# makes it, so the real index stays as it is. The script computes the key once, before the tests.
# The tests run from a key tree: a clone with a commit of that tree checked out, in a temporary
# folder of the git common dir, with a sparse checkout of the key paths only, so a test that reads
# a path outside the key fails. Each floor file in it is empty: the key holds only its existence.
# The sparse checkout stays inside the clone: in a linked worktree it changes the shared config. A
# trap removes the folder at the exit and after INT or TERM. A hook test reads only the work tree
# of the key tree. The clone holds each object of the repo, so a read of an excluded path through
# git (for example git show HEAD:docs/x.md) is outside the key: a hook test must not do it.
# A pass appends "<key> <commit> <date>" to dirigible-hooks-stamp in the git common dir, and drops
# the lines of other days. The next run with the same key prints "test-hooks: reuse <key>" and runs
# no test. At the start, the script removes each key tree folder over one hour old.
# No reuse and no stamp: when the list is not the HOOK_TESTS list of the Makefile at HEAD, after a
# failed test, when the first word of MAKEFLAGS has -n, -t, -i, or -q (as scripts/check-stamp.sh),
# and when HOOK_CASES is set. After a failed test, the summary names each failed test and prints the
# last 40 lines of its output.
# HOOK_CASES=<label pattern> reaches the test, which runs only the case blocks that match (the
# header of .claude/hooks/git-guardrails.test.sh). With DIRIGIBLE_PUSH_CHECK=1 or
# DIRIGIBLE_HOOKS_ALL=1 the script prints a message that names HOOK_CASES and exits 1, before the
# key: a push check or a hooks pass runs every case, or fails. When the pattern does not match the
# label guardrails-rules, and the work tree differs from the merge base of HEAD and origin/main in
# .claude/hooks/git-guardrails.sh or scripts/lock-words.sh (the hook sources it), or there is no
# merge base, the script adds |guardrails-rules to the pattern and prints that it did.
# A test counts as failed when its output has a line that ends in ": command not found", also when
# it exits 0. The summary names the test and the first such line.
# scripts/test-hooks.test.sh tests it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
common="$(git rev-parse --path-format=absolute --git-common-dir)" || exit 1
stamp="$common/dirigible-hooks-stamp"
sha="$(git rev-parse HEAD)" || exit 1
today="$(date +%F)"
# A killed run (no trap) leaves its key tree: remove each one over one hour old. A serial pass takes
# about 47 min on an 8-core Mac and a pass in jobs less, so the run of another worktree keeps its
# tree.
find "$common" -maxdepth 1 -type d -name 'dirigible-hooks-tree.*' -mmin +60 -exec rm -rf {} +

# The job count. The variables are read here: the unset of the caller context below removes them.
if [[ -n ${HOOK_JOBS+x} && ! $HOOK_JOBS =~ ^[1-9][0-9]*$ ]]; then
    echo "test-hooks: HOOK_JOBS must be a whole number of 1 or more, not '$HOOK_JOBS'" >&2
    exit 2
fi
holds_lock=no
if [[ -n ${DIRIGIBLE_BUILD_LOCK:-} && "$(cat "$common/dirigible-build.lock/pid" 2>/dev/null)" == "$DIRIGIBLE_BUILD_LOCK" ]]; then
    holds_lock=yes
fi
njobs=1
if [[ $holds_lock == yes || ${HOOK_JOBS_PROBE:-} == 1 ]]; then
    if [[ -n ${HOOK_JOBS+x} ]]; then
        njobs=$HOOK_JOBS
    elif [[ $holds_lock == yes ]]; then
        ncpu="$(sysctl -n hw.ncpu 2>/dev/null)"
        [[ $ncpu =~ ^[0-9]+$ ]] || { echo "test-hooks: sysctl -n hw.ncpu gave no number; set HOOK_JOBS" >&2; exit 1; }
        njobs=$((ncpu / 2))
        [[ $njobs -ge 1 ]] || njobs=1
    fi
elif [[ -n ${HOOK_JOBS+x} && $HOOK_JOBS -gt 1 ]]; then
    echo "test-hooks: HOOK_JOBS=$HOOK_JOBS needs the build lock; 1 job"
fi

if [[ -n ${HOOK_CASES:-} && ( ${DIRIGIBLE_PUSH_CHECK:-} == 1 || ${DIRIGIBLE_HOOKS_ALL:-} == 1 ) ]]; then
    echo "test-hooks: HOOK_CASES is set, and a push check or a hooks pass runs every hook case. Unset HOOK_CASES." >&2
    exit 1
fi

# A narrow run must still run the case block that the hook change can break: the block that tests
# the rules that use lock-words.sh. A pattern that already matches the label is left as it is.
if [[ -n ${HOOK_CASES:-} ]]; then
    cases_pattern="^(${HOOK_CASES})\$"
    if ! [[ guardrails-rules =~ $cases_pattern ]]; then
        add_label=no
        if base_commit="$(git merge-base HEAD origin/main 2>/dev/null)"; then
            { git diff --name-only "$base_commit" --; git ls-files --others --exclude-standard; } \
                | grep -qxE '\.claude/hooks/git-guardrails\.sh|scripts/lock-words\.sh' && add_label=yes
        else
            add_label=yes
        fi
        if [[ $add_label == yes ]]; then
            HOOK_CASES="$HOOK_CASES|guardrails-rules"
            export HOOK_CASES
            echo "test-hooks: HOOK_CASES is now $HOOK_CASES: git-guardrails.sh or lock-words.sh changed, or HEAD has no merge base with origin/main"
        fi
    fi
fi

args=()
for a in "$@"; do
    IFS=, read -ra parts <<< "$a"
    args+=("${parts[@]}")
done
set -- ${args[@]+"${args[@]}"}

reason="" flags="${MAKEFLAGS:-}"
flags="${flags%% *}"
[[ $flags == *=* ]] && flags=""
hook_list() { awk '/^HOOK_TESTS *=/ { on = 1 } on { print; if (!/\\$/) exit }' \
    | sed 's/^HOOK_TESTS *=//; s/\\$//' | tr -s ' \t' '\n' | grep . | sort; }
listed="$(git show "$sha:Makefile" | hook_list)"
current="$(hook_list < Makefile)"
given="$(printf '%s\n' "$@" | sort)"
whole=no
[[ $given == "$listed" ]] && whole=yes
if [[ $given == "$listed" || $given == "$current" ]] \
    && [[ ${DIRIGIBLE_PUSH_CHECK:-} != 1 && ${DIRIGIBLE_FULL_SUITE:-} != 1 && ${DIRIGIBLE_HOOKS_ALL:-} != 1 ]]; then
    echo "test-hooks: the whole HOOK_TESTS list runs only in the push check. Run make check-changed: it runs the hook tests of the changed paths. A person who needs the whole list sets DIRIGIBLE_FULL_SUITE=1." >&2
    exit 1
fi
if [[ $flags == *[ntiq]* ]]; then reason="make ran with -n, -t, -i, or -q"
elif [[ $whole == no ]]; then reason="the list is not HOOK_TESTS of the Makefile"
elif [[ -n ${HOOK_CASES:-} ]]; then reason="HOOK_CASES is set"
fi

# Not in TMPDIR: probe.test.sh needs a repo outside /private/var/folders, where the probe.sh
# sandbox allows each write.
work="$(mktemp -d "$common/dirigible-hooks-tree.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# git rev-parse --git-path returns GIT_INDEX_FILE when it is set, so read the path of the real
# index before the variable is set for the two commands that use the copy.
real_index="$(git rev-parse --path-format=absolute --git-path index)" || exit 1
cp "$real_index" "$work/index" || exit 1
tree="$(GIT_INDEX_FILE="$work/index" git add -A && GIT_INDEX_FILE="$work/index" git write-tree)" || exit 1

floor="$(scripts/check-changed.sh --floor)" || exit 1
key="$({
    git ls-tree "$tree" | grep -vE $'\t(Sources|Tests|docs|README\\.md)$'
    for f in $floor; do
        if git cat-file -e "$tree:${f%/}" 2>/dev/null; then echo "$f yes"; else echo "$f no"; fi
    done
    printf '%s\n' "$@" | sort
    # Each tool that a hook test or the script under it runs. sw_vers covers the tools of macOS
    # (plutil, osascript, codesign, bc, awk), and xcodebuild those of Xcode (actool).
    for tool in 'swift --version' sw_vers 'xcodebuild -version' 'python3 --version' 'node --version' \
        'git --version' 'make --version' 'jq --version' 'perl --version' 'gh --version'; do
        echo "$tool: $($tool 2>&1 | head -2 | tr '\n' ' ')"
    done
    echo "$today"
} | shasum -a 256 | cut -c1-64)"
if [[ -z $reason ]] && grep -q "^$key " "$stamp" 2>/dev/null; then
    echo "test-hooks: reuse $key"
    exit 0
fi
# The key and the stamp are read: remove the context of the caller before the clone and the tests.
unset BASE FILTER SINCE CHECK_RISK HOOK_TESTS MAKEFLAGS MFLAGS MAKELEVEL GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE HOOK_JOBS HOOK_JOBS_PROBE
for v in $(compgen -v WITH_LOCK_) $(compgen -v DIRIGIBLE_); do unset "$v"; done
# A commit of the key tree, so the checkout has a clean status.
keycommit="$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git commit-tree "$tree" -m key)" || exit 1
tests=("$@")
total=$#
echo "test-hooks: $total tests, $njobs jobs"
# One clone for each job slot, so two tests that run at once never share a work tree or a git dir.
slots=$((njobs < total ? njobs : total))
[[ $slots -ge 1 ]] || slots=1
for s in $(seq "$slots"); do
    git clone -q --shared --no-checkout "$common" "$work/tree$s" \
        && git -C "$work/tree$s" sparse-checkout set --no-cone '/*' '!/Sources/' '!/Tests/' '!/docs/' '!/README.md' \
            $(sed 's|^|/|' <<< "$floor") \
        && git -C "$work/tree$s" checkout -q --detach "$keycommit" || exit 1
    # The key holds only the existence of a floor path, so a test that reads floor content fails.
    (cd "$work/tree$s" && find $floor -type f | while IFS= read -r f; do : > "$f"; done)
done
# A hook test calls bash by name, and the first bash on the PATH can be a newer one than the 3.2
# of macOS. The tests must run on /bin/bash.
mkdir "$work/bin" && ln -s /bin/bash "$work/bin/bash" || exit 1
export PATH="$work/bin:$PATH"
command -v perl > /dev/null || { echo "test-hooks: perl is missing; the runner needs it to start each test with SIGINT at its default" >&2; exit 1; }

# The output of each test goes to a file of its own, and the runner prints it whole in list order.
logs="$(mktemp -d)" || exit 1
trap 'rm -rf "$logs" "$work"' EXIT
# The free job slots: a finished job writes its slot number to this fifo, and the runner reads one
# to start the next test. The runner holds the fifo open for read and write, so a write never blocks.
mkfifo "$logs/slots" && exec 9<> "$logs/slots" || exit 1
pids=()
kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2> /dev/null); do kill_tree "$child"; done
    kill -TERM "$1" 2> /dev/null
}
# launch <test index> <slot>: start one test in the clone of the slot, in the process group of the
# runner, so a TERM or a KILL to the group reaches it. A job that the shell starts in the
# background gets SIGINT ignored, and a test would inherit that: perl puts the default back.
launch() {
    local i=$1 slot=$2
    echo "test-hooks: start ${tests[i]}"
    : > "$logs/$i.log"
    (
        begin=$SECONDS status=0
        cd "$work/tree$slot" \
            && perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec @ARGV or die "exec $ARGV[0]: $!\n"' "${tests[i]}" \
                > "$logs/$i.log" 2>&1 9>&- || status=$?
        echo $((SECONDS - begin)) > "$logs/$i.time.new" && mv "$logs/$i.time.new" "$logs/$i.time"
        echo "$status" > "$logs/$i.status.new" && mv "$logs/$i.status.new" "$logs/$i.status"
        echo "$slot" >&9
    ) &
    pids[i]=$!
}
# A signal: name each test that still runs, show the end of its log, and stop it.
stop() {
    trap '' INT TERM
    local i
    for ((i = 0; i < next; i++)); do
        [[ -e "$logs/$i.status" ]] && continue
        echo "test-hooks: stopped while ${tests[i]} ran"
        tail -n 20 "$logs/$i.log"
        kill_tree "${pids[i]}"
    done
    exit "$1"
}
failed=() next=0 printed=0
run_start=$SECONDS
for s in $(seq "$slots"); do echo "$s" >&9; done
signaled=0
trap 'signaled=130' INT
trap 'signaled=143' TERM
# A trap runs inside a read that waits, and the alarm of the limit of that read can cut the trap
# short: a trap only sets the variable, and the loop calls stop after each read. The limit of 1 s
# also bounds the time to see the signal.
while [[ $printed -lt $total ]]; do
    got=1
    read -r -t 1 -u 9 slot || got=0
    [[ $signaled -eq 0 ]] || stop "$signaled"
    if [[ $got -eq 1 && $next -lt $total ]]; then
        launch "$next" "$slot"
        next=$((next + 1))
    fi
    while [[ $printed -lt $total && -e "$logs/$printed.status" ]]; do
        word=passed
        if [[ "$(cat "$logs/$printed.status")" != 0 ]] || grep -qE ': command not found$' "$logs/$printed.log"; then
            failed+=("$printed")
            word=FAILED
        fi
        echo "test-hooks: ${tests[printed]} $word in $(cat "$logs/$printed.time") s"
        cat "$logs/$printed.log"
        printed=$((printed + 1))
    done
done
trap 'exit 130' INT
trap 'exit 143' TERM
time_line="test-hooks: $total tests in $((SECONDS - run_start)) s, $njobs jobs"
if [[ ${#failed[@]} -gt 0 ]]; then
    names=()
    for i in "${failed[@]}"; do names+=("${tests[i]}"); done
    echo "test-hooks: ${#failed[@]} of $total failed: ${names[*]}"
    for i in "${failed[@]}"; do
        line="$(grep -m1 -E ': command not found$' "$logs/$i.log" || true)"
        [[ -z $line ]] || echo "test-hooks: ${tests[i]} printed a command not found line: $line"
        echo "test-hooks: the last 40 lines of ${tests[i]}:"
        tail -n 40 "$logs/$i.log"
    done
    echo "$time_line"
    exit 1
fi
if [[ -n $reason ]]; then
    echo "test-hooks: no stamp ($reason)"
else
    # The key holds the date, so only the lines of today can match: drop the others.
    { grep " $today\$" "$stamp" 2>/dev/null; echo "$key $sha $today"; } > "$stamp.new" && mv "$stamp.new" "$stamp"
    echo "test-hooks: wrote $key"
fi
echo "$time_line"
