#!/bin/bash
# Tear down a landed run: remove its worktree and free the disk that its heavy files hold.
# Usage: scripts/teardown-run.sh <run folder>      (from the main checkout)
#        scripts/teardown-run.sh --sweep-trash
# Exit 2: the run folder is not a direct child of .scratchpads/runs/ of the main checkout, its
# run.md has no `- Status: done` line, the working directory is in the run worktree, the fetch of
# origin/main fails, the branch of the last `- Branch:` line has neither a worktree nor a ref, or
# run.md names two detached worktrees that are at a landed commit.
# The run worktree is the one on that branch. With none, it is the detached worktree whose path
# run.md holds as a whole token and whose HEAD is the end of a `range <a>..<b>` or the commit of a
# `tag <name> on <commit>` that run.md records (a DMG step detaches the run worktree), and an
# ancestor of origin/main. A named detached worktree at another commit, or at a recorded commit
# that is not on origin/main, stays. The worktree also stays, with the line
# `worktree kept: <path> (<reason>)`, and the file step goes on, when `with-lock.sh --builders`
# (WITH_LOCK_BUILDERS_MIN=0) lists it (a live holder or waiter) or the run.md of an open run (a line
# that starts with `- Status: open`) names it. A whole token can end in `/`, and `~/` in it stands
# for $HOME; a relative path (`../wt`) does not match.
# Exit 1, before any removal: `git cherry origin/main <branch>` prints a `+` line, the worktree is
# not clean, or a scratch path is there already in <run folder>/worktree-scratch/.
# Steps, in order:
# 1. It prints `free before:` (df -k of the run folder volume).
# 2. Each file of <worktree>/.scratchpads/ (ignored by git) moves to <run folder>/worktree-scratch/
#    at the same relative path, with no overwrite. When <worktree>/build/verify exists, it runs
#    `<worktree>/scripts/verify-copy.sh stop` (a failure only prints a line). Then
#    `git worktree remove` (no --force).
# 3. The file step walks the run folder, with worktree-scratch/: it follows no symbolic link and
#    moves or removes no link. It skips logs/ and the ledgers (run.md,
#    decisions.tsv, analysis.md, plan.md, review-*.md, pr.md) at the top level. A *.dirigible
#    package, an *.app folder, and a .build/ folder are each one item.
#    An item is a candidate when it is under the top-level verify/ or probes/, is a package, an
#    *.app, or a .build/ folder, is an audio file (.wav .caf .pcm .aif .aiff .m4a .mp3 .flac) or a
#    video file (.mov .mp4 .m4v) of any size, is a .dmg file, or is a file of TEARDOWN_MIN_MB MB
#    (default 5) or more. For each candidate, the first rule that matches wins:
#    a) build output (*.app, .build/, *.dmg) is deleted, named or not: it is the only thing that
#       the script deletes;
#    b) a named item stays in place;
#    c) each other candidate moves to .scratchpads/trash/<date>/<run>/ of the main checkout at the
#       same run-relative path (-2, -3 before the extension when that path is there already; no
#       move overwrites a file), and the script prints each moved path.
#    Named: a text file of the run folder outside a package, an *.app, or a .build/ folder (.md
#    .tsv .txt .json .csv .log .xml) holds the run-relative path of the item, the base name of a
#    file, or the run-relative path of a folder that holds the item (not the top-level verify/ or
#    probes/), as a whole token: no letter, digit, `-`, `_`, or `.` comes before or after it.
#    So no step deletes a file outside build output, a file of a package, or a file in a named
#    folder. A recording of a real voice in any format (.f32, .raw, .opus, and the like), even when
#    no text file names it, goes to the trash.
#    The name check reads the text files once, in one awk pass after the walk, so its cost does not
#    grow with the count of candidates. The Named rule keeps its meaning. A name with a character
#    other than a letter, a digit, or one of _ . / - gets a scan of the text.
# 4. It prints the removed worktree, the trash folder, the count and size of the moved and of the
#    deleted items, and `free after:`. When the trash holds a date folder more than 14 days old, it
#    prints a `trash:` line with the sweep command.
# --sweep-trash lists and deletes the date folders of .scratchpads/trash/ that are more than 14 days
# old, and prints `free before:` and `free after:`. A folder whose name is no date stays.
# scripts/land.test.sh tests it.
set -euo pipefail
shopt -s nullglob dotglob

min_mb="${TEARDOWN_MIN_MB:-5}"
die() { echo "teardown-run: $2" >&2; exit "$1"; }

common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || die 2 "run it inside the main checkout"
main="$(cd "$common/.." && pwd -P)"
trash_root="$main/.scratchpads/trash"
free_kib() { df -k "$1" | awk 'NR == 2 { print $4 }'; }
days_ago() { date -v-"$1"d +%F 2>/dev/null || date -d "$1 days ago" +%F; }
old_trash() { # the date folders of the trash that are more than 14 days old
    local cutoff dir name
    cutoff="$(days_ago 14)"
    for dir in "$trash_root"/*/; do
        dir="${dir%/}" name="${dir##*/}"
        if [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$name" < "$cutoff" ]]; then echo "$dir"; fi
    done
}

if [[ "${1:-}" == --sweep-trash ]]; then
    [[ $# -eq 1 ]] || die 2 "usage: scripts/teardown-run.sh <run folder> | --sweep-trash"
    echo "free before: $(free_kib "$main") KiB"
    old="$(old_trash)"
    while IFS= read -r dir; do
        [[ -z "$dir" ]] || echo "sweep: ${dir##*/} ($(du -sk "$dir" | cut -f1) KiB)"
    done <<<"$old"
    while IFS= read -r dir; do
        [[ -z "$dir" ]] || rm -rf "$dir"
    done <<<"$old"
    echo "free after: $(free_kib "$main") KiB"
    exit 0
fi

[[ $# -eq 1 ]] || die 2 "usage: scripts/teardown-run.sh <run folder> | --sweep-trash"
runs="$(cd "$main/.scratchpads/runs" 2>/dev/null && pwd -P)" || die 2 "no .scratchpads/runs in $main"
run="$(cd "$1" 2>/dev/null && pwd -P)" || die 2 "$1 is not a folder"
[[ "$(dirname "$run")" == "$runs" ]] || die 2 "$1 is not a direct child of $runs"
[[ -f "$run/run.md" ]] && grep -qx -- '- Status: done' "$run/run.md" || die 2 "$run/run.md has no '- Status: done' line; close the run first"
branch="$(awk '/^- Branch:/ { b = $3 } END { print b }' "$run/run.md" | tr -d '`')"
[[ -n "$branch" ]] || die 2 "$run/run.md has no '- Branch:' line"
wt="$(git -C "$main" worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree / { p = substr($0, 10) } $1 == "branch" && $2 == b { print p }')"
check_wt() { # <worktree path>: it is not the main checkout, and the working directory is outside it
    local cwd
    [[ "$1" != "$main" ]] || die 2 "the worktree of $branch is the main checkout"
    cwd="$(pwd -P)"
    [[ "$cwd" != "$1" && "$cwd" != "$1"/* ]] || die 2 "the working directory is in the run worktree $1; run it from the main checkout"
}
names_path() { # <file> <path>: the file holds the path, or its ~/ form, as a whole token (a trailing / and a period that ends a sentence are no part of it)
    local home=""
    [[ -n "${HOME:-}" && "$2" == "$HOME"/* ]] && home="~${2#"$HOME"}"
    awk -v t="$2" -v h="$home" '
        function has(s, t,   off, i, p, q, pre, post, nxt) {
            off = 0
            while ((i = index(substr(s, off + 1), t)) > 0) {
                p = off + i
                pre = (p > 1) ? substr(s, p - 1, 1) : ""
                q = p + length(t)
                if (substr(s, q, 1) == "/") q++
                post = substr(s, q, 1)
                nxt = substr(s, q + 1, 1)
                if (pre !~ "[A-Za-z0-9_./-]" && post !~ "[A-Za-z0-9_/-]" && !(post == "." && nxt ~ "[A-Za-z0-9_-]")) return 1
                off = p }
            return 0 }
        has($0, t) || (h != "" && has($0, h)) { found = 1; exit }
        END { exit !found }' "$1"
}
if [[ -n "$wt" ]]; then
    wt="$(cd "$wt" && pwd -P)"
    check_wt "$wt"
fi
git -C "$main" fetch -q origin main || die 2 "git fetch origin main failed"
git -C "$main" rev-parse --verify -q "refs/heads/$branch" > /dev/null || die 2 "no branch $branch; the worktree is gone and the ref is gone"
plus="$(git -C "$main" cherry origin/main "$branch" | grep '^+' || true)"
[[ -z "$plus" ]] || die 1 "the branch $branch has commits that origin/main lacks: $(wc -l <<<"$plus" | tr -d ' ') line(s) with +; land them first"
kept=()
if [[ -z "$wt" ]]; then
    landed=" "
    while IFS= read -r ref; do
        sha="$(git -C "$main" rev-parse --verify -q "$ref^{commit}")" && landed+="$sha "
    done < <(grep -oE 'range [0-9a-f]{7,40}\.\.[0-9a-f]{7,40}|tag [^ ]+ on [0-9a-f]{7,40}' "$run/run.md" | sed -E 's/^.*(\.\.| on )//')
    match=()
    while IFS=$'\t' read -r path head; do
        [[ "$path" != "$main" ]] && names_path "$run/run.md" "$path" || continue
        if [[ "$landed" == *" $head "* ]] && git -C "$main" merge-base --is-ancestor "$head" origin/main; then
            match+=("$path")
        elif [[ "$landed" == *" $head "* ]]; then
            kept+=("worktree kept: $path (HEAD ${head:0:9} is not on origin/main)")
        else
            kept+=("worktree kept: $path (HEAD ${head:0:9} is no commit that run.md records as landed)")
        fi
    done < <(git -C "$main" worktree list --porcelain | awk '/^worktree / { p = substr($0, 10) } /^HEAD / { h = $2 } $1 == "detached" { print p "\t" h }')
    [[ ${#match[@]} -le 1 ]] || die 2 "run.md names ${#match[@]} detached worktrees at a landed commit: ${match[*]}; remove the wrong one by hand"
    if [[ ${#match[@]} -eq 1 ]]; then
        wt="${match[0]}"
        check_wt "$wt"
    fi
fi
if [[ -n "$wt" ]]; then
    # Keep a worktree that a live holder or waiter builds in, or that the run.md of an open run names.
    live="$(WITH_LOCK_BUILDERS_MIN=0 "$(dirname "$0")/with-lock.sh" --builders)" || die 2 "with-lock.sh --builders failed"
    reason=""
    if grep -qxF -- "$wt" <<<"$live"; then
        reason="a live holder or waiter builds in it"
    else
        for file in "$runs"/*/run.md; do
            [[ "$file" != "$run/run.md" ]] && grep -q '^- Status: open' "$file" && names_path "$file" "$wt" || continue
            reason="the open run $(basename "$(dirname "$file")") names it"
            break
        done
    fi
    if [[ -n "$reason" ]]; then
        kept+=("worktree kept: $wt ($reason)")
        wt=""
    fi
fi
if [[ -n "$wt" ]]; then
    [[ -z "$(git -C "$wt" status --porcelain)" ]] || die 1 "the worktree $wt has changes (git status --porcelain); commit or copy them first"
    scratch="$wt/.scratchpads"
    if [[ -d "$scratch" ]]; then
        while IFS= read -r -d '' file; do
            dest="$run/worktree-scratch/${file#"$scratch"/}"
            [[ ! -e "$dest" && ! -L "$dest" ]] || die 1 "$dest is there already; nothing moved and the worktree stays"
        done < <(find -P "$scratch" -type f -print0)
    fi
fi

echo "free before: $(free_kib "$run") KiB"
if [[ -n "$wt" ]]; then
    if [[ -d "$scratch" ]]; then
        while IFS= read -r -d '' file; do
            dest="$run/worktree-scratch/${file#"$scratch"/}"
            mkdir -p "$(dirname "$dest")"
            mv -n "$file" "$dest"
        done < <(find -P "$scratch" -type f -print0)
    fi
    if [[ -d "$wt/build/verify" ]]; then
        "$wt/scripts/verify-copy.sh" stop || echo "teardown-run: verify-copy.sh stop exited $?; go on" >&2
    fi
    git -C "$main" worktree remove "$wt" || die 1 "git worktree remove $wt failed"
    echo "worktree removed: $wt"
elif [[ ${#kept[@]} -eq 0 ]]; then
    echo "worktree removed: none (gone already)"
fi
[[ ${#kept[@]} -eq 0 ]] || printf '%s\n' "${kept[@]}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
find -P "$run" \( -name '*.dirigible' -o -name '*.app' -o -name .build \) -prune -o -type f \
    \( -name '*.md' -o -name '*.tsv' -o -name '*.txt' -o -name '*.json' -o -name '*.csv' -o -name '*.log' -o -name '*.xml' \) -exec cat {} + > "$work/names"
min_bytes=$((min_mb * 1048576))
big=""
if [[ "$min_bytes" -gt 0 ]]; then
    big=$'\n'"$(find -P "$run" \( -type d \( -name '*.dirigible' -o -name '*.app' -o -name .build \) -prune \) -o -type f -size +$((min_bytes - 1))c -print)"$'\n'
fi

stamp="$(date +%F)"
trash_dir="$trash_root/$stamp/${run##*/}"
moved_n=0 moved_kb=0 del_n=0 del_kb=0
cand_n=0 cand_action=() cand_rel=()
handle() { # <path> <rel> <file|dir>: record a candidate; the name check comes after the walk
    local path="$1" rel="$2" kind="$3" name="${2##*/}" action
    if [[ "$kind" == dir ]]; then
        case "$name" in *.app | .build) action=delete ;; *) action=move ;; esac
    else
        action=none
        case "${name##*.}" in
            [wW][aA][vV] | [cC][aA][fF] | [pP][cC][mM] | [aA][iI][fF] | [aA][iI][fF][fF] | [mM]4[aA] | [mM][pP]3 | [fF][lL][aA][cC] | [mM][oO][vV] | [mM][pP]4 | [mM]4[vV]) action=move ;;
            [dD][mM][gG]) action=delete ;;
            *) if [[ "$rel" == verify/* || "$rel" == probes/* || "$min_bytes" -eq 0 || "$big" == *$'\n'"$path"$'\n'* ]]; then action=move; fi ;;
        esac
    fi
    [[ "$action" != none ]] || return 0
    cand_n=$((cand_n + 1))
    cand_action[cand_n]="$action" cand_rel[cand_n]="$rel"
    printf '%s\t%s\t%s\t%s\n' "$cand_n" "$action" "$kind" "$rel" >> "$work/cand"
}
visit() { # <dir> <depth>
    local entry rel name
    for entry in "$1"/*; do
        [[ ! -L "$entry" ]] || continue
        rel="${entry#"$run"/}" name="${entry##*/}"
        if [[ "$2" -eq 0 ]]; then
            case "$name" in logs | run.md | decisions.tsv | analysis.md | plan.md | pr.md | review-*.md) continue ;; esac
        fi
        if [[ -d "$entry" ]]; then
            case "$name" in
                *.app | .build | *.dirigible) handle "$entry" "$rel" dir ;;
                *) visit "$entry" $(($2 + 1)) ;;
            esac
        elif [[ -f "$entry" ]]; then
            handle "$entry" "$rel" file
        fi
    done
}
visit "$run" 0

# The name check, in one awk pass. The token set holds each run of [A-Za-z0-9_./-] of the text and
# each slash-aligned sub-path of the run, up to the depth of the deepest candidate. A query of only
# those characters is named when the set holds it. Any other query gets a scan of the text.
# The awk prints the number of each candidate that stays.
stay=()
if [[ "$cand_n" -gt 0 ]]; then
    LC_ALL=C tr -cs 'A-Za-z0-9_./-' '\n' < "$work/names" | LC_ALL=C sort -u > "$work/tokens"
    awk -F'\t' -v names="$work/names" '
        NR == FNR { if ($1 ~ /^[0-9]+$/) { n++; cid[n] = $1; cact[n] = $2; ckind[n] = $3
                        crel[n] = substr($0, length($1 $2 $3) + 4); d = split(crel[n], part, "/"); if (d > maxd) maxd = d }
                    next }
        { k = split($0, part, "/")
          for (i = 1; i <= k; i++) { t = part[i]; if (t != "") set[t] = 1
              for (j = i + 1; j <= k && j < i + maxd; j++) { t = t "/" part[j]; set[t] = 1 } } }
        function scan(t,   l, off, i, p, pre, post) {
            if (t in memo) return memo[t]
            memo[t] = 0
            while ((getline l < names) > 0) { off = 0
                while ((i = index(substr(l, off + 1), t)) > 0) {
                    p = off + i
                    pre = (p > 1) ? substr(l, p - 1, 1) : ""
                    post = substr(l, p + length(t), 1)
                    if (pre !~ /[A-Za-z0-9_.-]/ && post !~ /[A-Za-z0-9_.-]/) { memo[t] = 1; break }
                    off = p }
                if (memo[t]) break }
            close(names); return memo[t] }
        function has(t) { if (t ~ /^[A-Za-z0-9_.\/-]+$/) return (t in set); return scan(t) }
        function named(rel, kind,   anc, b) {
            if (has(rel)) return 1
            b = rel; sub(/.*\//, "", b)
            if (kind == "file" && has(b)) return 1
            anc = rel; sub(/\/[^\/]*$/, "", anc)
            while (anc != rel && anc != "verify" && anc != "probes") {
                if (has(anc)) return 1
                rel = anc; sub(/\/[^\/]*$/, "", anc) }
            return 0 }
        END { for (c = 1; c <= n; c++) if (cact[c] != "delete" && named(crel[c], ckind[c])) print cid[c] }
    ' "$work/cand" "$work/tokens" > "$work/stay"
    while IFS= read -r id; do stay[id]=1; done < "$work/stay"
fi

for ((i = 1; i <= cand_n; i++)); do
    action="${cand_action[i]}" rel="${cand_rel[i]}"
    [[ "$action" == delete || -z "${stay[i]:-}" ]] || continue
    path="$run/$rel"
    kb="$(du -sk "$path" | cut -f1)"
    if [[ "$action" == move ]]; then
        dest="$trash_dir/$rel"
        mkdir -p "${dest%/*}"
        if [[ -e "$dest" || -L "$dest" ]]; then
            base="${dest##*/}" stem="$base" ext=""
            if [[ "$base" == *.* && "$base" != .* ]]; then stem="${base%.*}" ext=".${base##*.}"; fi
            n=2
            while [[ -e "${dest%/*}/$stem-$n$ext" ]]; do n=$((n + 1)); done
            dest="${dest%/*}/$stem-$n$ext"
        fi
        mv "$path" "$dest"
        echo "moved: $rel -> $dest"
        moved_n=$((moved_n + 1)) moved_kb=$((moved_kb + kb))
    else
        rm -rf "$path"
        echo "deleted: $rel"
        del_n=$((del_n + 1)) del_kb=$((del_kb + kb))
    fi
done

echo "trash folder: $trash_dir"
echo "moved: $moved_n items, $moved_kb KiB"
echo "deleted: $del_n items, $del_kb KiB"
echo "free after: $(free_kib "$run") KiB"
count="$(old_trash | grep -c . || true)"
[[ "$count" -eq 0 ]] || echo "trash: $count folders older than 14 days; run scripts/teardown-run.sh --sweep-trash"
