#!/bin/bash
# Run a probe in its own folder. The probe can write only in that folder, the system
# temporary folders, and /dev. A probe once deleted files in the home folder, so the
# sandbox refuses a write anywhere else, also a relative path and an unlink() in C.
# Usage: scripts/probe.sh <folder> <command> [args...]
# The folder must be under .scratchpads/ of this repo (in a worktree, also of the main checkout)
# or under /private/tmp.
# The command runs with the folder as its working directory.
#
# A Swift build in a probe: pass `--disable-sandbox` to swift build, test, or package, because
# SwiftPM cannot start its own sandbox inside this one. A build with two --arch values goes through
# the Xcode build system, and its macro plugin server needs `-Xswiftc -disable-sandbox` too
# ("swift-plugin-server produced malformed response"). For a package copy with a new
# --scratch-path, copy .build/repositories and .build/checkouts from a build first, so SwiftPM does
# not fetch from the network. The SwiftPM lines "failed storing manifest in cache" and "not
# accessible or not writable" come from this sandbox, not from the build.
#
# Only the command runs in the sandbox. A pipe or a redirect in the calling shell (`| tee x.log`)
# runs outside it, in the folder of the caller: put it inside the probe with `bash -c '...'`.
# A package copy with an APFS clone of .build fails with "PCH was compiled with module cache
# path": delete *.pch and .build/*/debug/ModuleCache in the copy before you build. In a
# command-line Swift probe, a top-level `Task {}` inherits the main actor: when the main thread
# then blocks (a semaphore), use `Task.detached`, or the probe hangs.
# The sandbox refuses writes under /Volumes, so `hdiutil create -srcfolder` fails with "Operation
# not permitted". Create a blank image and attach it with `-mountpoint` in the probe folder.
set -euo pipefail

[[ $# -ge 2 ]] || { echo "usage: scripts/probe.sh <folder> <command> [args...]" >&2; exit 2; }
# Resolve the folder before it exists: the real path of its nearest existing parent, plus the
# missing part. Refuse ".." in the missing part, because it can leave the allowed roots.
parent="$1" missing=""
while [[ ! -d "$parent" ]]; do
    missing="$(basename "$parent")${missing:+/$missing}"
    parent="$(dirname "$parent")"
done
case "/$missing/" in */../*) echo "probe.sh: the missing part of the folder has '..': $1" >&2; exit 2 ;; esac
folder="$(cd "$parent" && pwd -P)${missing:+/$missing}"
shift
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
# In a git worktree, the run folders are in .scratchpads/ of the main checkout, the folder of the
# common git dir. Accept both.
common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
main="$(cd "$(dirname "${common:-$repo/.git}")" && pwd -P)"

# A worktree can be inside .scratchpads/ of the main checkout, so refuse its own .scratchpads/ first.
[[ "$folder" != "$repo/.scratchpads" ]] || { echo "probe.sh: the folder must be a subfolder of $folder" >&2; exit 2; }
case "$folder/" in
    "$repo/.scratchpads/"?*/ | "$main/.scratchpads/"?*/ | /private/tmp/?*/) ;;
    *) echo "probe.sh: the folder must be under $repo/.scratchpads/, $main/.scratchpads/, or /private/tmp: $folder" >&2; exit 2 ;;
esac
mkdir -p "$folder"
# The missing part can have a "." segment. The sandbox matches only the canonical path.
folder="$(cd "$folder" && pwd -P)"

# In a sandbox profile, the last rule that matches wins.
profile="(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath \"$folder\") (subpath \"/private/var/folders\") (subpath \"/dev\"))"

cd "$folder"
exec sandbox-exec -p "$profile" "$@"
