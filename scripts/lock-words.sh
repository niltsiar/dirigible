#!/bin/bash
# The lock-free make words, sourced by scripts/with-lock.sh (lock_free, hooks_pass, release_call) and by
# .claude/hooks/git-guardrails.sh (the verdict for a with-lock.sh make test-hooks call). Both read
# the same functions, so a form of the call has one class. The case test-rule of
# .claude/hooks/git-guardrails.test.sh (expect_each_lock) sends each spelling through both.
# It also holds the lock-step lists that .claude/hooks/agent-guard.sh (a brief) and git-guardrails.sh
# (a Bash command with no with-lock.sh) read: lock_targets (the make targets that take the lock),
# lock_scripts (the scripts that take it themselves), lock_swift (the swift commands that take it),
# and lock_free_targets (the make targets that take none). scripts/with-lock.sh sets its own
# free_targets, so this list has another name. lock_make_opt and lock_make_set match the make words
# before the target. git-guardrails.test.sh keeps the lists equal to the Makefile and AGENTS.md.
# hold_base gives scripts/with-lock.sh and scripts/flake-monitor/loop.sh the push-check baseline
# of their hold limit. long_words is the one list of the long holders: lock_holder of
# scripts/with-lock.sh reads the command of the holder with it, and the release wait of
# git-guardrails.sh reads each command of a background call of the lead with it.
# Sourced only: no set line, and the top level holds the list assignments only.
lock_targets='setup|build|app|icon-preview|test|test-filter|test-asan|test-tsan|test-slow|test-slow-push|check-slow-gates|check-warnings|check-sizes|bench|test-app|dmg|test-dmg|test-hooks|run|static|check|check-changed|clean'
lock_scripts='swift-test|test-shards|bench|bench-pairs|flake-monitor/loop|sanitize|test-stress'
lock_swift='build|test|run'
lock_free_targets='check-docs|check-fast|lint|format'
lock_make_opt='-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?'
lock_make_set="[A-Za-z_][A-Za-z0-9_]*=('[^']*'|\"[^\"]*\"|[^[:space:]]*)"
# push_env: succeeds when BASE has a value in the environment or in a BASE= word of MAKEFLAGS (the
# Makefile reads $(BASE), and make puts a variable of its command line into the environment and
# MAKEFLAGS of the recipe).
push_env() { [[ -n "${BASE:-}" || " ${MAKEFLAGS:-}" =~ [[:space:]]BASE=[^[:space:]] ]]; }
# hooks_env: succeeds when DIRIGIBLE_HOOKS_ALL is 1 in the environment or in a word of MAKEFLAGS.
hooks_env() {
    local re='[[:space:]]DIRIGIBLE_HOOKS_ALL=1([[:space:]]|$)'
    [[ "${DIRIGIBLE_HOOKS_ALL:-}" == 1 || " ${MAKEFLAGS:-}" =~ $re ]]
}
# release_call <command>: a push check (make check-changed with a BASE= word, or with BASE from
# push_env), a land (land.sh), or a DMG build (make dmg).
release_call() {
    local w goal="" base=""
    [[ "${1##*/}" == land.sh ]] && return 0
    [[ "${1##*/}" == make ]] || return 1
    ! push_env || base=1
    for w in "${@:2}"; do
        case "$w" in
            BASE=?*) base=1 ;;
            dmg) goal=dmg ;;
            check-changed) [[ $goal == dmg ]] || goal=check ;;
        esac
    done
    [[ $goal == dmg || ($goal == check && -n $base) ]]
}

# hooks_pass <command>: the hooks pass of a run, which takes no lock: make (any path) with the one goal
# test-hooks, NAME=value words, DIRIGIBLE_HOOKS_ALL=1 as a word or from hooks_env, no HOOK_TESTS= word
# (that form is the plain lock-free call of lock_make_words), and no BASE word or push_env.
hooks_pass() {
    local w goal="" hooks=""
    [[ "${1##*/}" == make ]] || return 1
    ! push_env || return 1
    ! hooks_env || hooks=1
    for w in "${@:2}"; do
        case "$w" in
            BASE=?* | HOOK_TESTS=*) return 1 ;;
            DIRIGIBLE_HOOKS_ALL=1) hooks=1 ;;
            *=*) ;;
            test-hooks) [[ -z $goal ]] || return 1; goal=1 ;;
            *) return 1 ;;
        esac
    done
    [[ -n $goal && -n $hooks ]]
}

# long_text_re matches the text of each command that long_words takes, so a text with no match runs
# no long holder.
long_text_re='bench|mutation-pass|flake-monitor/loop|test-stress|land\.sh|make'
# long_words <command word>...: succeeds when a command of the words runs a long holder: a release
# call (release_call with no BASE or MAKEFLAGS of the environment), bench.sh, bench-pairs.sh (not
# --compare or --lines, which take no lock), make with a bench or dmg goal, mutation-pass.sh, flake-monitor/loop.sh, or
# test-stress.sh. A command starts at the first word, after a separator (&&, ||, |, &, ;, a lone (
# or {, or a word that ends with ;, &, or |), and after a wrapper word: env, nice, nohup, command,
# time, caffeinate, xcrun, a shell word (bash, sh, zsh, or dash), probe.sh with its folder, and an
# option, a number, or NAME=value after them. So a wrapper or a shell -c body hides no long holder,
# and an argument (rg -n bench.sh) runs none. A word loses its quote marks, a leading ( or {, and a
# trailing ;, &, |, ), or }. Miss: a wrapper outside that list (xargs, sudo).
long_words() {
    local raw w i j at=1 folder="" words=() ends=()
    [[ $# -gt 0 ]] || return 1
    for raw in "$@"; do
        w="${raw//[\"\']/}"
        while [[ "$w" == [\(\{]* ]]; do w="${w#?}"; done
        while [[ "$w" == *[\;\&\|\)\}] ]]; do w="${w%?}"; done
        words+=("$w")
        if [[ -z "$w" || "$raw" == *[\;\&\|] ]]; then ends+=(1); else ends+=(0); fi
    done
    for ((i = 0; i < ${#words[@]}; i++)); do
        w="${words[i]}"
        if [[ $at == 1 && -n "$w" ]]; then
            if [[ -n "$folder" && "$w" != -* ]]; then
                folder=""
            elif [[ "${w##*/}" =~ ^(env|nice|nohup|command|time|caffeinate|xcrun|bash|sh|zsh|dash|-.*|[0-9]+)$ || "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                :
            elif [[ "${w##*/}" == probe.sh ]]; then
                folder=1
            else
                at=0
                case "$w" in
                    */flake-monitor/loop.sh | flake-monitor/loop.sh) return 0 ;;
                esac
                case "${w##*/}" in
                    bench.sh | mutation-pass.sh | test-stress.sh | land.sh) return 0 ;;
                    bench-pairs.sh) [[ "${words[i + 1]:-}" != --compare && "${words[i + 1]:-}" != --lines ]] && return 0 ;;
                    make)
                        # The make command: its words up to the end of the command.
                        for ((j = i; j + 1 < ${#words[@]} && ends[j] == 0; j++)); do :; done
                        for w in "${words[@]:i:j-i+1}"; do [[ "$w" == bench || "$w" == dmg ]] && return 0; done
                        (
                            unset BASE MAKEFLAGS
                            release_call "${words[@]:i:j-i+1}"
                        ) && return 0
                        ;;
                esac
            fi
        fi
        [[ ${ends[i]} == 0 ]] || { at=1 folder=""; }
    done
    return 1
}

# lock_make_words <command>: succeeds for make (any path) with no BASE in the environment or in
# MAKEFLAGS (push_env), one goal of check-changed or test-hooks, NAME=value words, no BASE=<value>
# word, and a non-empty HOOK_TESTS= word for test-hooks. It sets lock_goal and lock_assign (the
# NAME=value words) for the caller. Any other form fails.
lock_make_words() {
    local w hooks=""
    lock_goal="" lock_assign=()
    [[ "${1##*/}" == make ]] || return 1
    ! push_env || return 1
    for w in "${@:2}"; do
        case "$w" in
            BASE=?*) return 1 ;;
            HOOK_TESTS=?*) lock_assign+=("$w"); hooks=1 ;;
            *=*) lock_assign+=("$w") ;;
            check-changed | test-hooks) [[ -z "$lock_goal" ]] || return 1; lock_goal="$w" ;;
            *) return 1 ;;
        esac
    done
    case "$lock_goal" in
        test-hooks) [[ -n "$hooks" ]] ;;
        check-changed) ;;
        *) return 1 ;;
    esac
}

# hold_base <hold log>: prints the largest hold of the last 10 push-check lines (a command with
# check-changed and BASE=) whose fifth column is not limit, as one whole number; a limit line takes
# no slot, and a field that is no number counts as 0. It prints 0 when the log is missing or has no
# such line.
hold_base() {
    [[ -r "$1" ]] || { echo 0; return; }
    awk -F'\t' '$3 ~ /check-changed/ && $3 ~ /BASE=/ && $5 != "limit" { h[n++ % 10] = $2 + 0 } END { for (i in h) if (h[i] > s + 0) s = h[i]; print int(s + 0) }' "$1"
}
