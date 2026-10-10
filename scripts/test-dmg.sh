#!/bin/bash
# Check the DMG of `make dmg`: its checksum, its image, and the app in it. The script mounts
# the DMG read-only with no Finder window, runs AppBundleTests and DiskImageTests on the
# mounted app, and detaches.
set -euo pipefail
cd "$(dirname "$0")/.."

dmgs=(build/Dirigible-*.dmg)
if [[ ${#dmgs[@]} -ne 1 || ! -f "${dmgs[0]}" ]]; then
    echo "test-dmg: build/ must hold exactly one DMG" >&2
    exit 1
fi
dmg="$(pwd -P)/${dmgs[0]}"

(cd build && shasum -a 256 -c "$(basename "$dmg").sha256")
hdiutil verify -quiet "$dmg"

# mount prints the real path (/private/var), so the trap compares with the real path.
mnt="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
    if mount | grep -qF " on $mnt "; then
        hdiutil detach -quiet "$mnt" || { sleep 1; hdiutil detach -quiet "$mnt"; } \
            || hdiutil detach -quiet -force "$mnt" || true
    fi
    # The check matches the folder name, which is the same in the /var and the /private/var form.
    if mount | grep -qF "/$(basename "$mnt") ("; then
        echo "test-dmg.sh: $mnt is still attached" >&2
        exit 1
    fi
    rmdir "$mnt" || true
}
trap cleanup EXIT
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg"

DIRIGIBLE_DMG="$dmg" DIRIGIBLE_APP="$mnt/Dirigible.app" scripts/swift-test.sh --filter 'AppBundleTests|DiskImageTests'
