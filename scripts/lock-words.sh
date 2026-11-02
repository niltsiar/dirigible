#!/bin/bash
# The lock-free make words, sourced by scripts/with-lock.sh (lock_free, release_call) and by
# .claude/hooks/git-guardrails.sh (the verdict for a with-lock.sh make test-hooks call). Both read
# the same functions, so a form of the call has one class. The case test-rule of
# .claude/hooks/git-guardrails.test.sh (expect_each_lock) sends each spelling through both.
# Sourced only: no set line, no top-level command.
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
# push_env), the hooks pass of a run (make test-hooks with DIRIGIBLE_HOOKS_ALL=1 as a word, or from
# hooks_env), a land (land.sh), or a DMG build (make dmg).
release_call() {
    local w goal="" base="" hooks=""
    [[ "${1##*/}" == land.sh ]] && return 0
    [[ "${1##*/}" == make ]] || return 1
    ! push_env || base=1
    ! hooks_env || hooks=1
    for w in "${@:2}"; do
        case "$w" in
            BASE=?*) base=1 ;;
            DIRIGIBLE_HOOKS_ALL=1) hooks=1 ;;
            dmg) goal=dmg ;;
            check-changed) [[ $goal == dmg ]] || goal=check ;;
            test-hooks) [[ -n $goal ]] || goal=hooks ;;
        esac
    done
    [[ $goal == dmg || ($goal == check && -n $base) || ($goal == hooks && -n $hooks) ]]
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
