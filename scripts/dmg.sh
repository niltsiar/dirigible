#!/bin/bash
# Build build/Dirigible-<version>.dmg from build/dmg-app/Dirigible.app (`make dmg`): a UDZO
# image with the app, an Applications link, and the app icon as the volume icon, plus a
# .sha256 file. The DMG is not notarized (constraint C1).
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/dmg-app/Dirigible.app
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
name="Dirigible-$version.dmg"
dmg="build/$name"
rm -f build/Dirigible-*.dmg build/Dirigible-*.dmg.sha256

# A detach can fail while the system still reads the new volume, so it tries once more.
detach() {
    hdiutil detach -quiet "$@" || { sleep 1; hdiutil detach -quiet "$@"; }
}

# mount prints the real path (/private/var), so the trap compares with the real path.
work="$(cd "$(mktemp -d)" && pwd -P)"
mnt="$work/mnt"
cleanup() {
    if mount | grep -qF " on $mnt "; then
        detach "$mnt" || hdiutil detach -quiet -force "$mnt" || true
    fi
    # Never delete through a mount point that is still attached.
    mount | grep -qF " on $mnt " || rm -rf "$work"
}
trap cleanup EXIT
mkdir "$mnt"

size=$(($(du -sm "$app" | cut -f1) + 20))
hdiutil create -quiet -size "${size}m" -fs HFS+ -volname Dirigible -type UDIF -layout NONE "$work/rw.dmg"
hdiutil attach -quiet -readwrite -nobrowse -noautoopen -mountpoint "$mnt" "$work/rw.dmg"
ditto "$app" "$mnt/Dirigible.app"
ln -s /Applications "$mnt/Applications"
cp "$app/Contents/Resources/AppIcon.icns" "$mnt/.VolumeIcon.icns"
# The Finder info of the root with the custom icon flag (bit 0x04 of byte 8).
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$mnt"
# No -force here: a forced detach can leave a dirty image, so a failure stops the script.
detach "$mnt"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -o "$dmg"

hash=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
echo "$hash  $name" > "$dmg.sha256"
echo "$dmg"
