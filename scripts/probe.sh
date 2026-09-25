#!/bin/bash
# Run a probe in its own folder. The probe can write only in that folder, the system
# temporary folders, and /dev. A probe once deleted files in the home folder, so the
# sandbox refuses a write anywhere else, also a relative path and an unlink() in C.
# Usage: scripts/probe.sh <folder> <command> [args...]
# The folder must be under .scratchpads/ of this repo or under /private/tmp.
# The command runs with the folder as its working directory.
set -euo pipefail

[[ $# -ge 2 ]] || { echo "usage: scripts/probe.sh <folder> <command> [args...]" >&2; exit 2; }
mkdir -p "$1"
folder="$(cd "$1" && pwd -P)"
shift
repo="$(cd "$(dirname "$0")/.." && pwd -P)"

case "$folder/" in
    "$repo/.scratchpads/"?*/ | /private/tmp/?*/) ;;
    *) echo "probe.sh: the folder must be under $repo/.scratchpads/ or /private/tmp: $folder" >&2; exit 2 ;;
esac

# In a sandbox profile, the last rule that matches wins.
profile="(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath \"$folder\") (subpath \"/private/var/folders\") (subpath \"/dev\"))"

cd "$folder"
exec sandbox-exec -p "$profile" "$@"
