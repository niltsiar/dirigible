#!/bin/bash
# Tear down a landed run: remove its worktree and free the disk that its heavy files hold.
# Usage: scripts/teardown-run.sh <run folder>      (from the main checkout)
#        scripts/teardown-run.sh --sweep-trash
# Exit 2: the run folder is not a direct child of .scratchpads/runs/ of the main checkout, its
# run.md has no `- Status: done` line, the working directory is in the run worktree, the fetch of
# origin/main fails, or the branch of the last `- Branch:` line has neither a worktree nor a ref.
# Exit 1, before any removal: `git cherry origin/main <branch>` prints a `+` line, the worktree is
# not clean, or a scratch path is there already in <run folder>/worktree-scratch/.
# Steps, in order:
# 1. It prints `free before:` (df -k of the run folder volume).
# 2. Each file of <worktree>/.scratchpads/ (ignored by git) moves to <run folder>/worktree-scratch/
#    at the same relative path, with no overwrite. Then `git worktree remove` (no --force).
# 3. The file step walks the run folder, with worktree-scratch/: it follows no symbolic link and
#    moves or removes no link. It skips logs/ and the ledgers (run.md,
#    decisions.tsv, analysis.md, plan.md, review-*.md, pr.md) at the top level. A *.dirigible
#    package, an *.app folder, and a .build/ folder are each one item.
#    An item is a candidate when it is under the top-level verify/ or probes/, is a package, an
#    *.app, or a .build/ folder, is an audio file (.wav .caf .pcm .aif .aiff .m4a .mp3 .flac) or a
#    video file (.mov .mp4 .m4v) of any size, is a .dmg file, or is a file of TEARDOWN_MIN_MB MB
#    (default 5) or more. For each candidate, the first rule that matches wins:
#    a) build output (*.app, .build/, *.dmg) is deleted, named or not;
#    b) a named item stays in place;
#    c) an audio file, a video file, or a package moves to .scratchpads/trash/<date>/<run>/ of the
#       main checkout at the same run-relative path (-2, -3 before the extension when that path is
#       there already; no move overwrites a file), and the script prints each moved path;
#    d) each other candidate is deleted.
#    Named: a text file of the run folder outside a package, an *.app, or a .build/ folder (.md
#    .tsv .txt .json .csv .log .xml) holds the run-relative path of the item, the base name of a
#    file, or the run-relative path of a folder that holds the item (not the top-level verify/ or
#    probes/), as a whole token: no letter, digit, `-`, `_`, or `.` comes before or after it.
#    So no step deletes an audio or video file outside build output, a file of a package, or a file
#    in a named folder. A recording of a real voice that no text file names goes to the trash.
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
if [[ -n "$wt" ]]; then
    wt="$(cd "$wt" && pwd -P)"
    [[ "$wt" != "$main" ]] || die 2 "the worktree of $branch is the main checkout"
    cwd="$(pwd -P)"
    [[ "$cwd" != "$wt" && "$cwd" != "$wt"/* ]] || die 2 "the working directory is in the run worktree $wt; run it from the main checkout"
fi
git -C "$main" fetch -q origin main || die 2 "git fetch origin main failed"
git -C "$main" rev-parse --verify -q "refs/heads/$branch" > /dev/null || die 2 "no branch $branch; the worktree is gone and the ref is gone"
plus="$(git -C "$main" cherry origin/main "$branch" | grep '^+' || true)"
[[ -z "$plus" ]] || die 1 "the branch $branch has commits that origin/main lacks: $(wc -l <<<"$plus" | tr -d ' ') line(s) with +; land them first"
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
    git -C "$main" worktree remove "$wt" || die 1 "git worktree remove $wt failed"
    echo "worktree removed: $wt"
else
    echo "worktree removed: none (gone already)"
fi

names="$(mktemp)"
trap 'rm -f "$names"' EXIT
while IFS= read -r -d '' file; do cat "$file" >> "$names"; done < <(find -P "$run" \( -name '*.dirigible' -o -name '*.app' -o -name .build \) -prune -o -type f \
    \( -name '*.md' -o -name '*.tsv' -o -name '*.txt' -o -name '*.json' -o -name '*.csv' -o -name '*.log' -o -name '*.xml' \) -print0)

# has_token <text>: the names file holds the text with no letter, digit, - _ . before or after it.
has_token() {
    grep -aF -- "$1" "$names" | T="$1" awk 'BEGIN { t = ENVIRON["T"] }
        { off = 0
          while ((i = index(substr($0, off + 1), t)) > 0) {
              p = off + i
              pre = (p > 1) ? substr($0, p - 1, 1) : ""
              post = substr($0, p + length(t), 1)
              if (pre !~ /[A-Za-z0-9_.-]/ && post !~ /[A-Za-z0-9_.-]/) { f = 1; exit }
              off = p
          } }
        END { exit !f }'
}
# is_named <rel> <file|dir>
is_named() {
    local rel="$1" anc="${1%/*}"
    has_token "$rel" && return 0
    [[ "$2" == file ]] && has_token "${rel##*/}" && return 0
    while [[ "$anc" != "$rel" && "$anc" != verify && "$anc" != probes ]]; do
        has_token "$anc" && return 0
        rel="$anc" anc="${anc%/*}"
    done
    return 1
}

stamp="$(date +%F)"
trash_dir="$trash_root/$stamp/${run##*/}"
moved_n=0 moved_kb=0 del_n=0 del_kb=0
handle() { # <path> <rel> <file|dir>
    local path="$1" rel="$2" kind="$3" name="${2##*/}" ext kb dest base stem n
    ext="$(tr '[:upper:]' '[:lower:]' <<<"${name##*.}")"
    kb="$(du -sk "$path" | cut -f1)"
    if [[ "$kind" == dir ]]; then
        case "$name" in *.app | .build) action=delete ;; *) action=pkg ;; esac
    else
        action=none
        case "$ext" in
            wav | caf | pcm | aif | aiff | m4a | mp3 | flac | mov | mp4 | m4v) action=media ;;
            dmg) action=delete ;;
            *) if [[ "$rel" == verify/* || "$rel" == probes/* || "$(wc -c < "$path")" -ge $((min_mb * 1048576)) ]]; then action=other; fi ;;
        esac
    fi
    [[ "$action" != none ]] || return 0
    if [[ "$action" != delete ]] && is_named "$rel" "$kind"; then return 0; fi
    if [[ "$action" == media || "$action" == pkg ]]; then
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

echo "trash folder: $trash_dir"
echo "moved: $moved_n items, $moved_kb KiB"
echo "deleted: $del_n items, $del_kb KiB"
echo "free after: $(free_kib "$run") KiB"
count="$(old_trash | grep -c . || true)"
[[ "$count" -eq 0 ]] || echo "trash: $count folders older than 14 days; run scripts/teardown-run.sh --sweep-trash"
