#!/bin/bash
# Build the app bundle: universal release binary, Info.plist, app icon, user guide, and signature.
# The first argument is the bundle path (default build/Dirigible.app). It must be
# build/<name>.app, because the script deletes that folder first.
# SIGN_IDENTITY defaults to "-" (ad-hoc). Set it to a local self-signed certificate
# name to keep the microphone permission across rebuilds (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Dirigible.app}"
if [[ "$APP" != build/*.app || "$APP" == *..* ]]; then
    echo "bundle.sh: the bundle path must be build/<name>.app" >&2
    exit 2
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64)

scripts/icon.sh
swift build "${SWIFT_FLAGS[@]}" --product DirigibleApp
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --product DirigibleApp --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DirigibleApp" "$APP/Contents/MacOS/Dirigible"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Support/Resources/. "$APP/Contents/Resources/"
cp build/icon/Assets.car build/icon/AppIcon.icns "$APP/Contents/Resources/"
# The user guide as an HTML page, with only the images that it shows. Help > Dirigible Guide
# opens it. guide-html.swift accepts only images/<name> paths.
GUIDE="$APP/Contents/Resources/Guide"
mkdir -p "$GUIDE/images"
images="$(swift scripts/guide-html.swift docs/guide.md "$GUIDE/guide.html")"
for image in $images; do cp "docs/$image" "$GUIDE/$image"; done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo "$APP"
