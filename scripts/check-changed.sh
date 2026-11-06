#!/bin/bash
# Print the change classes of the changed paths, the make targets that they need, and the risk.
# This script owns the path table and the risk floor (decision 0028). Docs name it, not the table.
# A change to a path of the shared guard list gives `risk: yes`, also a change of only comment lines, and keeps its class.
# In the git modes, the content of a change can also give the class: a change of only comment
# lines is class comments, and a Makefile change of only comment lines is class docs (comment_only).
# Usage: scripts/check-changed.sh               HEAD against the working tree and untracked files; the local targets
#        scripts/check-changed.sh <base>        also the commits since <base>; the targets before the push.
#          After a pass stamp S of <base> (check-stamp.sh read; its base can be an older commit of
#          <base>), it prints `stamp: delta <S>` first, and the targets of the paths changed since
#          S only; classes and risk stay those of <base>.
#          After a newer partial stamp P (run-checks.sh), it prints `stamp: partial <P>`, the targets
#          of the paths since P, and the word RERUN=<P>:fast:<names>+slow:<names> of the failed tests.
#          A partial line still needs the exact commit of <base>.
#          With class sources-risk (risk: yes) and no Sources/ or Tests/ path since P, it exits 1 with no targets line.
#          CHECK_PARTIAL=ignore: the targets with no partial stamp, and the word with each name.
#        SINCE=<ref> scripts/check-changed.sh   the commits since <ref> and the working tree; the local
#          targets and the HOOK_TESTS word, for the group end of one agent. It reads and writes no stamp.
#          The lead records `git rev-parse HEAD` before it starts the agent. That commit is <ref>: the
#          parent of the first commit of the group. A <ref> that is the first commit drops its paths.
#          With a base too it exits 2. With no changed path it exits 1. Only git mode reads SINCE.
#        A bare run (no base, SINCE, or FILTER) with no changed path exits 3 with one stderr line and no
#          stdout when HEAD has commits past the merge base of origin/main: give SINCE=<merge base> or
#          BASE=<ref>. At or behind origin/main, or with no origin/main, it prints targets: none.
#          With a changed path and commits past origin/main, a bare run prints the targets of the
#          path and one stderr note: `check-changed: <n> commits past origin/main are not checked:
#          give SINCE=<merge base>`.
#        scripts/check-changed.sh --paths [--push] <<<$'<path>\n<path>'   the paths from stdin only
#        scripts/check-changed.sh --floor       print the risk floor paths only (not the shared guard list)
#        scripts/check-changed.sh --wait-load <targets>   wait for a normal load and no test of another tree
#          (for a bench and a push check: no build or test of another tree)
#        scripts/check-changed.sh --overlap <base>   information only, exit 0: name other work that changes a
#          Sources/ or Tests/ file of this branch: `overlap: <base>: <files>` for the commits of <base>
#          since the merge base, `overlap: worktree <branch>: <files>` for each other worktree (its
#          commits that HEAD and <base> lack, working tree, untracked files), `overlap: PR #<n>
#          (<branch>): <files>` for each open PR of gh
#          (--limit 200), or `overlap: none`. A gh that gives no answer in OVERLAP_GH_TIMEOUT seconds
#          (default 20) gives `overlap: gh: no answer`. It runs no git fetch and takes no git lock.
# `make check-changed [BASE=<base>]` runs the targets. It fails closed: a git error exits nonzero.
# With FILTER (test names, for the tdd loop of a slice), the local target test becomes
# test-filter, and the local target check becomes check-fast test-filter test-app (or static
# test-filter test-app, below). FILTER before the push exits 1: the push runs the full targets. A
# local git run with no FILTER whose targets have test or check prints the three lines and exits 1:
# the full suite runs only in the push check. A local git run with FILTER whose targets have no
# test-filter prints the three lines and exits 1: it would run no test. With no changed path,
# FILTER gives the target test-filter and one stderr note. The mode --paths keeps the targets (a
# probe of the table).
# A local run with check-fast (the form of check with FILTER too) adds the word HOOK_TESTS=<tests>:
# the tests of the changed paths from Makefile HOOK_TESTS, joined with commas, so make gets one
# word and scripts/test-hooks.sh splits it. A path of class tooling, bundle, or build needs a test:
# the entry itself, <name>.test.sh for <name>.sh or <name>.py, the guardrails test for
# .claude/hooks/*, .claude/settings.json, and .githooks/*, scripts/land.test.sh for
# .githooks/pre-push, and each entry whose text names the basename of the changed path. A tooling or
# build path with no test gives the word DIRIGIBLE_HOOKS_ALL=1 in place of HOOK_TESTS:
# scripts/test-hooks.sh runs the whole list only with that word (or the switches of the push check
# and of a person). So do tests that are every entry of the list. A bundle path with no test, and a
# path of any other class (comments too), needs none. When no path needs a hook test, check-fast
# becomes static: the gates of STATIC_GATES in the Makefile, with no hook test.
# The push never adds either word. SINCE is local, so it adds them.
set -euo pipefail

# The risk floor. A change to one of these paths prints `risk: yes`, unless the change is
# comment-only. A path that ends in / is a folder. check-changed.test.sh fails when a floor path does not exist.
floor="Sources/DirigibleAudio/ Sources/DirigibleCore/SessionReader.swift Sources/DirigibleCore/SessionWriter.swift Sources/DirigibleCore/SessionXML.swift Sources/DirigibleCore/PackageLock.swift Sources/DirigibleCore/TranscriptStore.swift Sources/DirigibleCore/UnusedFiles.swift Sources/DirigibleCore/Backup.swift Sources/DirigibleCore/Session+Origin.swift Sources/DirigibleCore/SessionReader+Origin.swift Sources/DirigibleCore/UnusedFiles+Transcripts.swift Sources/DirigibleCore/UnusedFiles+Captures.swift Sources/DirigibleMCP/PackageEditCore.swift Sources/DirigibleMCP/PruneWork.swift"
# The shared guard list: the guards that each session shares (the build lock script, its word
# lists, the hooks). A change to one gives `risk: yes`. A path that ends in / is a folder.
shared_guards="scripts/with-lock.sh scripts/lock-words.sh .claude/hooks/"

class_of() {
    local f
    for f in $floor; do
        case "$1" in "$f"*) [[ "$f" == */ || "$1" == "$f" ]] && { echo sources-risk; return; } ;; esac
    done
    case "$1" in
        Makefile | Support/* | scripts/bundle.sh | scripts/sign-app.sh | scripts/guide-html.swift | scripts/dmg.sh | scripts/test-dmg.sh | scripts/icon.sh | \
            Tests/DirigibleTests/AppBundleTests.swift | Tests/DirigibleTests/DiskImageTests.swift) echo bundle ;;
        scripts/* | .claude/hooks/* | .claude/skills/*/scripts/* | .claude/workflows/* | .claude/settings.json | .githooks/* | .sourcekit-lsp/*) echo tooling ;;
        docs/* | README.md | AGENTS.md | CLAUDE.md | CODING_STANDARDS.md | .claude/skills/*.md | .claude/agents/*) echo docs ;;
        Tests/*) echo tests ;;
        Sources/*) echo sources ;;
        *) echo build ;;
    esac
}

# The Swift text with no blank line and no // line. A line with /* or */ stays: a block comment
# can end in a // line.
swift_code() { awk '{ t = $0; sub(/^[ \t]+/, "", t) } t == "" { next } t ~ /^\/\// && t !~ /\/\*|\*\// { next } { print }'; }

# The Makefile text with no blank line and no comment line that make skips: a line that starts
# with # after spaces (a tab makes a recipe line), with no $ and no \ at the end. A line after a
# line that ends in \ stays.
make_code() { awk '{ c = prev; prev = /\\$/ } !c && /^ *$/ { next } !c && /^ *#/ && !/\$/ && !/\\$/ { next } { print }'; }

# A change of only comment lines: the text at $from and the file on disk are equal after the
# filter of the file. A new, deleted, or untracked file is not. A file with a line that matches
# the guard keeps its path class.
comment_only() {
    local old filter guard
    [[ -n "$from" && -f "$1" ]] || return 1
    case "$1" in
        # ponytail: a // line in a multi-line string is text, so a file with """ keeps its path class.
        Sources/*.swift | Tests/*.swift) filter=swift_code guard='"""' ;;
        # A # line in a define body is value text.
        Makefile) filter=make_code guard='(^|[[:space:]])define([[:space:]]|$)' ;;
        *) return 1 ;;
    esac
    old="$(git show "$from:$1" 2>/dev/null)" || return 1
    ! grep -qE "$guard" <<<"$old" && ! grep -qE "$guard" "$1" || return 1
    [[ "$($filter <<<"$old")" == "$($filter <"$1")" ]]
}

# The targets of a class: the local column (push=0) or the before-the-push column (push=1).
targets_of() {
    case "$1:$push" in
        docs:*) echo check-docs ;;
        comments:* | tooling:*) echo check-fast ;;
        tests:0 | sources:0 | sources-risk:0) echo test ;;
        bundle:0 | build:0) echo check ;;
        tests:1 | sources:1 | sources-risk:1 | build:1) echo check ;;
        bundle:1) echo check test-dmg ;;
    esac
}

# A build or a test in another worktree makes timing tests fail (DLV-157). Before a target other
# than check-docs, check-fast, and static, wait until the 1-minute load is under CHECK_LOAD_MAX
# (default: the core count) and no swiftpm-testing-helper of another tree runs (its command line does not
# hold <root>/.build/). A bench (the target bench) and a push check (BASE in the environment: make
# check-changed BASE=<ref> and land.sh export it) also wait for a toolchain swift-build or
# swift-test, and for a test-hooks.sh, of another tree. The tree of a process is the git top level
# of its cwd, or the cwd when that is no git tree; a test-hooks.sh runs in a clone of its own, so
# its tree is the tree of the cwd of its parent (make). A slice check keeps the first rule only, so
# its lock wait, load wait, and tests fit in one 600 s Bash call. Read all each 10 s. After
# CHECK_LOAD_WAIT seconds (default 300, so the wait and the tests of a slice fit in one 600 s Bash
# call), run the tests anyway. The lines go to stderr.
# cwd_tree <pid>: the tree of the cwd of a process; nothing when the process or its folder is gone.
cwd_tree() {
    local cwd
    cwd="$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    [[ -d "$cwd" ]] || return 0
    git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd"
}
# other_tree_process <root> <pgrep lines>: print "pid <pid>: <command>" (with " in <tree>" for a
# build or a hook run) for the first process that is not of the tree <root>.
other_tree_process() {
    local root="$1" line pid cmd word second tree
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pid="${line%% *}" cmd="${line#* }" word="${cmd%% *}" second="${cmd#* }" second="${second%% *}"
        if [[ "$cmd" == *"/swiftpm-testing-helper "* ]]; then
            [[ "$cmd" == *"$root/.build/"* ]] || { echo "pid ${line/ /: }"; return 0; }
        elif [[ "$word" == */swift-build || "$word" == */swift-test ]]; then
            tree="$(cwd_tree "$pid")"
        elif [[ "$word" == *test-hooks.sh || ("$word" == */bash && "$second" == *test-hooks.sh) ]]; then
            tree="$(cwd_tree "$(ps -o ppid= -p "$pid" | tr -d ' ')")"
        else
            continue
        fi
        [[ -z "$tree" || "$tree" == "$root" ]] || { echo "pid ${line/ /: } in $tree"; return 0; }
    done <<<"$2"
    return 1
}
wait_load() {
    local rest=" " t max load other why stop root waited=0 limit="${CHECK_LOAD_WAIT:-300}" pattern='/swiftpm-testing-helper '
    for t in "$@"; do [[ $t == *=* ]] || rest+="$t "; done
    for t in check-docs check-fast static none; do rest="${rest// $t / }"; done
    [[ -n "${rest// /}" ]] || return 0
    max="${CHECK_LOAD_MAX:-$(sysctl -n hw.ncpu)}"
    root="$(git rev-parse --show-toplevel)"
    if [[ "$rest" == *" bench "* || -n "${BASE:-}" ]]; then pattern+='|/swift-(build|test)( |$)|test-hooks\.sh( |$)'; fi
    while :; do
        load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
        # pgrep exits 1 with no match, and other_tree_process prints nothing then.
        other="$(other_tree_process "$root" "$(pgrep -lf "$pattern" || true)" || true)"
        if [[ -n "$other" ]]; then
            # The command line names the tree of the helper, so a stale helper can be stopped.
            why="a test of another tree runs ($other)" stop="a test of another tree runs after $waited s ($other)"
        elif awk -v l="$load" -v m="$max" 'BEGIN { exit !(l < m) }'; then
            echo "check-changed: load $load, under $max: run the tests" >&2
            return 0
        else
            why="load $load, not under $max (CHECK_LOAD_MAX)" stop="load $load after $waited s, not under $max"
        fi
        if ((waited >= limit)); then
            echo "check-changed: $stop: run the tests" >&2
            return 0
        fi
        echo "check-changed: $why: wait 10 s, up to $limit s (CHECK_LOAD_WAIT)" >&2
        sleep 10
        waited=$((waited + 10))
    done
}

# hook_list: the tests of Makefile HOOK_TESTS, one for each line.
hook_list() {
    awk '/^HOOK_TESTS *=/ { on = 1 } on { print; if (!/\\$/) exit }' "$(dirname "$0")/../Makefile" | sed 's/^HOOK_TESTS *=//; s/\\$//' | tr -s ' \t' '\n' | grep . || true
}

# hook_tests <paths>: the hook tests that the changed paths need, in the order of HOOK_TESTS and
# joined with commas. It prints "all" when a path of class tooling or build has no test, and nothing
# when no path needs a hook test.
hook_tests() {
    local root list p c t base hits all=" " out=""
    root="$(cd "$(dirname "$0")/.." && pwd)"
    list="$(hook_list)"
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if comment_only "$p"; then c=comments; else c="$(class_of "$p")"; fi
        [[ $c == tooling || $c == bundle || $c == build ]] || continue
        hits=" "
        grep -qxF -- "$p" <<<"$list" && hits+="$p "
        case "$p" in *.sh | *.py) t="${p%.*}.test.sh"; grep -qxF -- "$t" <<<"$list" && hits+="$t " ;; esac
        case "$p" in .claude/hooks/* | .claude/settings.json | .githooks/*) hits+=".claude/hooks/git-guardrails.test.sh " ;; esac
        [[ $p == .githooks/pre-push ]] && hits+="scripts/land.test.sh "
        base="${p##*/}"
        # A basename that no test names is no failure: grep exits 1 with no match.
        while IFS= read -r t; do hits+="$t "; done < <(cd "$root" && grep -lsF -- "$base" $list || true)
        if [[ "$hits" == " " ]]; then
            [[ $c == bundle ]] || { echo all; return 0; }
            continue
        fi
        all+="${hits# } "
    done <<<"$1"
    for t in $list; do [[ "$all" == *" $t "* ]] && out+=",$t"; done
    echo "${out#,}"
}

# The Sources/ and Tests/ paths of stdin, sorted and unique; the shared names of two such files.
ov_keep() { { grep -E '^(Sources|Tests)/' || true; } | sort -u; }
ov_shared() { comm -12 "$1" "$2" | paste -sd, - | sed 's/,/, /g'; }

# overlap <base>: see the usage block. Every read is local, except gh, which has a time limit. The
# result is information, so a failed read gives a line and never a failure.
overlap() {
    local base="${1:-}" timeout="${OVERLAP_GH_TIMEOUT:-20}" top cur mb shared line wt_path wt_name wt_head
    local gh_pid="" waited=0 notes="" lines="" wt_mb rec
    if (($# != 1)) || [[ -z "$base" ]]; then
        echo "usage: scripts/check-changed.sh --overlap <base> (information only; OVERLAP_GH_TIMEOUT seconds for gh)" >&2
        exit 2
    fi
    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        echo "check-changed: OVERLAP_GH_TIMEOUT=$timeout is not a whole number of seconds" >&2
        exit 2
    fi
    timeout=$((10#$timeout))
    cd "$(git rev-parse --show-toplevel)"
    top="$(pwd -P)"
    ovtmp="$(mktemp -d)"
    trap 'rm -rf "$ovtmp"' EXIT
    mb="$(git merge-base "$base" HEAD 2> /dev/null)" || mb=""
    if [[ -z "$mb" ]]; then
        echo "overlap: base $base not read"
        return 0
    fi
    { git diff --name-only --no-renames "$mb"; git ls-files --others --exclude-standard; } | ov_keep > "$ovtmp/mine"
    cur="$(git branch --show-current)"
    if command -v gh > /dev/null; then
        gh pr list --state open --limit 200 --json number,headRefName,files --jq '.[] | [.number, .headRefName] + [.files[].path] | @tsv' \
            > "$ovtmp/prs" 2> "$ovtmp/gh.err" < /dev/null &
        gh_pid=$!
    fi

    git diff --name-only --no-renames "$mb" "$base" | ov_keep > "$ovtmp/other"
    shared="$(ov_shared "$ovtmp/mine" "$ovtmp/other")"
    [[ -z "$shared" ]] || lines+="overlap: $base: $shared"$'\n'

    # One record for each worktree in the porcelain list; a blank line ends it.
    wt_path="" wt_name="" wt_head=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt_path="${line#worktree }" ;;
            "HEAD "*) wt_head="${line#HEAD }" ;;
            "branch "*) wt_name="${line#branch refs/heads/}" ;;
            "")
                if [[ -n "$wt_path" && -n "$wt_head" && -d "$wt_path" && "$(cd "$wt_path" && pwd -P)" != "$top" ]]; then
                    [[ -n "$wt_name" ]] || wt_name="$(git rev-parse --short "$wt_head")"
                    wt_mb="$(git merge-base "$base" "$wt_head" 2> /dev/null)" || wt_mb=""
                    if [[ -n "$wt_mb" ]]; then
                        {
                            git log --format= --name-only --no-renames "$wt_head" ^HEAD ^"$base"
                            git --no-optional-locks -C "$wt_path" diff --name-only --no-renames HEAD
                            git --no-optional-locks -C "$wt_path" ls-files --others --exclude-standard
                        } 2> /dev/null | ov_keep > "$ovtmp/other" || true
                        shared="$(ov_shared "$ovtmp/mine" "$ovtmp/other")"
                        [[ -z "$shared" ]] || lines+="overlap: worktree $wt_name: $shared"$'\n'
                    fi
                fi
                wt_path="" wt_name="" wt_head=""
                ;;
        esac
    done < <(git worktree list --porcelain; echo)

    if [[ -z "$gh_pid" ]]; then
        notes+="overlap: open PRs not read (gh not found)"$'\n'
    else
        while kill -0 "$gh_pid" 2> /dev/null && ((waited < timeout * 10)); do
            sleep 0.1
            waited=$((waited + 1))
        done
        if kill -0 "$gh_pid" 2> /dev/null; then
            kill "$gh_pid" 2> /dev/null || true
            wait "$gh_pid" 2> /dev/null || true
            notes+="overlap: gh: no answer"$'\n'
        elif ! wait "$gh_pid"; then
            notes+="overlap: open PRs not read ($(head -n 1 "$ovtmp/gh.err"))"$'\n'
        else
            while IFS=$'\t' read -r -a rec; do
                [[ "${rec[1]:-}" != "$cur" ]] || continue
                printf '%s\n' "${rec[@]:2}" | ov_keep > "$ovtmp/other"
                shared="$(ov_shared "$ovtmp/mine" "$ovtmp/other")"
                [[ -z "$shared" ]] || lines+="overlap: PR #${rec[0]} (${rec[1]}): $shared"$'\n'
            done < "$ovtmp/prs"
        fi
    fi
    printf '%s' "${lines:-overlap: none$'\n'}" "$notes"
}

push=0 mode=git base="" from=""
case "${1:-}" in
    --floor) printf '%s\n' $floor; exit 0 ;;
    --wait-load) shift; wait_load "$@"; exit 0 ;;
    --overlap) shift; overlap "$@"; exit 0 ;;
    --paths)
        mode=stdin
        [[ "${2:-}" == --push ]] && push=1
        if (($# > push + 1)); then
            echo "usage: scripts/check-changed.sh --paths [--push] <<<\$'<path>\\n<path>' (the paths come from stdin)" >&2
            exit 2
        fi
        ;;
    "") ;;
    *) base="$1" push=1 ;;
esac

since_ref=""
[[ $mode == git ]] && since_ref="${SINCE:-}"
if [[ -n "$since_ref" && -n "$base" ]]; then
    echo "check-changed: SINCE=$since_ref and the base $base cannot both be set: SINCE is the local mode, a base is the push form" >&2
    exit 2
fi

if [[ -n "${FILTER:-}" && $push == 1 ]]; then
    echo "check-changed: FILTER is for the tdd loop of a slice; the push check runs with no FILTER" >&2
    exit 1
fi

if [[ $mode == stdin ]]; then
    paths="$(cat)"
else
    cd "$(git rev-parse --show-toplevel)"
    # --no-renames lists the old path of a move too, so a moved floor file stays risk: yes.
    committed=""
    [[ -n "$base" ]] && committed="$(git diff --name-only --no-renames "$base...HEAD")"
    [[ -n "$since_ref" ]] && committed="$(git diff --name-only --no-renames "$since_ref...HEAD")"
    worktree="$(git diff --name-only --no-renames HEAD)"
    untracked="$(git ls-files --others --exclude-standard)"
    paths="$committed"$'\n'"$worktree"$'\n'"$untracked"
    # The old side of the content check: the fork point of the branch, or HEAD.
    from=HEAD
    [[ -n "$base" ]] && from="$(git merge-base "$base" HEAD)"
    [[ -n "$since_ref" ]] && from="$(git merge-base "$since_ref" HEAD)"
fi
paths="$(grep -v '^$' <<<"$paths" | sort -u || true)"
if [[ -z "$paths" && ( $push == 1 || -n "$since_ref" ) ]]; then
    if [[ -n "$since_ref" ]]; then
        echo "check-changed: no changed paths since $since_ref" >&2
    else
        echo "check-changed: no changed paths against ${base:-the paths of stdin}" >&2
    fi
    exit 1
fi
# A bare git run (no base, SINCE, or FILTER) whose HEAD has commits past the merge base with
# origin/main checks none of those commits. With no changed path it would report targets: none, so
# it exits 3 (with-lock.sh passes status 3 through at once). With a changed path it prints one stderr
# note. A missing ref, or no common commit, goes on as before.
if [[ $mode == git && $push == 0 && -z "${FILTER:-}" && -z "$since_ref" ]]; then
    origin="$(git rev-parse --verify -q 'origin/main^{commit}' 2>/dev/null || true)"
    merge_base="" count=0
    [[ -z "$origin" ]] || merge_base="$(git merge-base "$origin" HEAD 2>/dev/null || true)"
    [[ -z "$merge_base" ]] || count="$(git rev-list --count "$origin..HEAD" 2>/dev/null || echo 0)"
    if ((count > 0)); then
        if [[ -z "$paths" ]]; then
            echo "check-changed: no changed path, and HEAD has commits past the merge base $merge_base of origin/main (count: $count): give SINCE=$merge_base or BASE=<ref>" >&2
            exit 3
        fi
        echo "check-changed: $count commits past origin/main are not checked: give SINCE=$merge_base" >&2
    fi
fi

# classify <paths>: sets found (the classes) and kept (the paths that keep their path class; the
# push rule for test-slow-push reads only them). comment_only reads the old side at $from.
classify() {
    local p c
    found=" " kept=""
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if comment_only "$p"; then
            c=comments
            [[ $p == Makefile ]] && c=docs
        else
            c="$(class_of "$p")" kept+="$p"$'\n'
        fi
        [[ "$found" == *" $c "* ]] || found+="$c "
    done <<<"$1"
}
classify "$paths"

classes="" risk=no
for c in docs comments tooling tests sources sources-risk bundle build; do
    [[ "$found" == *" $c "* ]] || continue
    classes+=" $c"
    [[ $c == sources-risk ]] && risk=yes
done
while IFS= read -r p; do
    for f in $shared_guards; do
        case "$p" in "$f"*) [[ "$f" == */ || "$p" == "$f" ]] && risk=yes ;; esac
    done
done <<<"$paths"

# The newest pass stamp S of this base, and the partial stamp line that run-checks.sh appends
# after a check whose only red targets were tests: '<P> <base commit> failed fast:<names>
# slow:<names>'. This script is its only reader. It takes the last line of this base whose P is
# HEAD or an ancestor of HEAD, and descends from S and is not S (or with no S).
pass="" partial=""
if [[ -n "$base" ]]; then
    stamp="$("$(dirname "$0")/check-stamp.sh" read "$base")" && pass="${stamp%% *}"
    base_commit="$(git rev-parse --verify "$base^{commit}")"
    partial_file="$(git rev-parse --path-format=absolute --git-common-dir)/dirigible-check-partial"
    [[ ! -s "$partial_file" ]] || while read -r p p_base _ p_fast p_slow; do
        [[ $p_base == "$base_commit" && $p != "$pass" ]] || continue
        git merge-base --is-ancestor "$p" HEAD 2>/dev/null || continue
        [[ -z $pass ]] || git merge-base --is-ancestor "$pass" "$p" || continue
        partial="$p" rerun_fast="${p_fast#fast:}" rerun_slow="${p_slow#slow:}"
        break
    done < <(tail -r "$partial_file")
fi
# With class sources-risk (risk: yes), a test that failed and passes with no change of Sources/ or Tests/ is a flake of
# a risk branch: refuse the rerun, also with CHECK_PARTIAL=ignore. A shared guard gives risk: yes only.
if [[ -n $partial ]]; then
    since="$(git diff --name-only --no-renames "$partial")"$'\n'"$untracked"
    if [[ "$found" == *" sources-risk "* ]] && ! grep -qE '^(Sources|Tests)/' <<<"$since"; then
        echo "check-changed: the tests ${rerun_fast//,/ } ${rerun_slow//,/ } failed in the check of $partial, and no Sources/ or Tests/ path changed since then on this sources-risk (risk: yes) branch: fix the test first (.claude/skills/tdd/references/flake-triage.md)" >&2
        exit 1
    fi
fi

# The delta: after a partial stamp P, only the paths changed since P (the working tree too) pick
# the targets, with the content against P; with CHECK_PARTIAL=ignore, or with no P, the paths
# changed since the pass stamp S.
if [[ -n $partial && "${CHECK_PARTIAL:-}" != ignore ]]; then
    from="$partial"
    echo "stamp: partial $from"
    classify "$since"
elif [[ -n $pass ]]; then
    from="$pass"
    echo "stamp: delta $from"
    classify "$(git diff --name-only --no-renames "$from")"$'\n'"$untracked"
fi
wanted=" "
for c in $found; do
    for t in $(targets_of "$c"); do wanted+="$t "; done
done

# Before the push, test-slow-push runs for risk, a changed slow test (a file with the gate of the
# Makefile), or a Makefile change (it owns the recipe). A push with Swift tests (check) also runs
# it when no slow run passed today on this clone: the recipe writes the date file. A changed file
# of PUSH_SKIP (the Makefile line) adds test-slow-push and the word PUSH_RUN=<names> (sorted, joined
# with commas) after the targets: the recipe then also runs the slow tests of those files.
run=""
if [[ $push == 1 ]]; then
    slow=no
    skip="$(sed -n 's/^PUSH_SKIP = //p' "$(dirname "$0")/../Makefile")"
    [[ "$found" == *" sources-risk "* ]] && slow=yes
    grep -qx Makefile <<<"$kept" && slow=yes
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    while IFS= read -r p; do
        [[ $p == Tests/* ]] && grep -qF 'environment["DIRIGIBLE_SLOW_TESTS"]' "$root/$p" 2>/dev/null && slow=yes
        for n in $skip; do [[ $p == Tests/*/"$n.swift" ]] && slow=yes run+="$n"$'\n'; done
    done <<<"$kept"
    if [[ "$wanted" == *" check "* ]]; then
        date_file="$(git rev-parse --git-common-dir 2>/dev/null)/dirigible-slow-date" || date_file=/dev/null
        [[ "$(cat "$date_file" 2>/dev/null)" == "$(date +%F)" ]] || slow=yes
    fi
    [[ $slow == yes ]] && wanted+="test-slow-push "
fi

# check runs check-docs, check-fast, and test; check-fast runs check-docs. Drop what another target runs.
targets=""
for t in check-docs check-fast test check test-slow-push test-dmg; do
    [[ "$wanted" == *" $t "* ]] || continue
    case "$t" in check-docs | check-fast | test) [[ "$wanted" == *" check "* ]] && continue ;; esac
    [[ $t == check-docs && "$wanted" == *" check-fast "* ]] && continue
    targets+=" $t"
done

[[ -n "$run" ]] && targets+=" PUSH_RUN=$(sort -u <<<"${run%$'\n'}" | paste -sd, -)"

# The word RERUN=<P>:fast:<names>+slow:<names> gives run-checks.sh the failed tests of P. The fast
# part drops beside check or test, which run each fast test. test-slow-push skips a PUSH_SKIP file
# that PUSH_RUN does not name, so the slow part stays. A name with no `func <name>(` under Tests/
# drops. CHECK_PARTIAL=ignore keeps each name.
tested() {
    local n left=""
    for n in ${1//,/ }; do
        grep -rqF --include='*.swift' "func $n(" Tests 2>/dev/null && left+=",$n"
    done
    echo "${left#,}"
}
if [[ -n $partial && "${CHECK_PARTIAL:-}" != ignore ]]; then
    [[ " $targets " != *" check "* && " $targets " != *" test "* ]] || rerun_fast=""
    rerun_fast="$(tested "$rerun_fast")" rerun_slow="$(tested "$rerun_slow")"
fi
[[ -z $partial || -z "$rerun_fast$rerun_slow" ]] || targets+=" RERUN=$partial:fast:$rerun_fast+slow:$rerun_slow"
classes="${classes# }" targets="${targets# }"
needs_suite=no
[[ " $targets " == *" test "* || " $targets " == *" check "* ]] && needs_suite=yes
if [[ -n "${FILTER:-}" ]]; then
    targets="$(sed -E 's/(^| )check( |$)/\1check-fast test-filter test-app\2/; s/(^| )test( |$)/\1test-filter\2/' <<<"$targets")"
fi
# A local check-fast runs only the hook tests that the changed paths need. The FILTER rewrite makes
# check-fast of check, so this comes after it. The whole list runs only with a switch, which
# test-hooks.sh needs; with no hook test, check-fast is static.
if [[ $push == 0 && " $targets " == *" check-fast "* ]]; then
    hooks="$(hook_tests "$paths")"
    [[ "$hooks" != "$(hook_list | paste -sd, -)" ]] || hooks=all
    case "$hooks" in
        all) targets+=" DIRIGIBLE_HOOKS_ALL=1" ;;
        "") targets="$(sed -E 's/(^| )check-fast( |$)/\1static\2/' <<<"$targets")" ;;
        *) targets+=" HOOK_TESTS=$hooks" ;;
    esac
fi
# A local git run with FILTER and no changed path runs the named tests: no path needs another target.
if [[ $mode == git && $push == 0 && -n "${FILTER:-}" && -z "$paths" ]]; then
    targets=test-filter
    echo "check-changed: no changed path; FILTER runs only the named tests" >&2
fi
echo "classes: ${classes:-none}"
echo "targets: ${targets:-none}"
echo "risk: $risk"
if [[ $mode == git && $push == 0 && -z "${FILTER:-}" && $needs_suite == yes ]]; then
    if [[ -n "$since_ref" ]]; then
        echo "check-changed: the targets $targets run the full Swift suite. Run make check-changed SINCE=$since_ref FILTER='<name> <name>' for the tests of the group. The full suite runs only in the push check. A bare make test refuses too." >&2
    else
        echo "check-changed: the targets $targets run the full Swift suite. A slice runs make check-changed FILTER='<name> <name>'. The full suite runs only in the push check: make check-changed BASE=origin/main. A bare make test refuses too." >&2
    fi
    exit 1
fi
if [[ $mode == git && -n "${FILTER:-}" && " $targets " != *" test-filter "* ]]; then
    if [[ -n "$since_ref" ]]; then
        echo "check-changed: FILTER is set, but the targets $targets run no test. Run make test-filter FILTER='<name> <name>' for the tests, or run make check-changed SINCE=$since_ref with no FILTER for these targets." >&2
    else
        echo "check-changed: FILTER is set, but the targets $targets run no test. Run make test-filter FILTER='<name> <name>' for the tests, or run make check-changed with no FILTER for these targets." >&2
    fi
    exit 1
fi
