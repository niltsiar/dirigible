#!/bin/bash
# Build build/Dirigible.app: universal release binary, Info.plist, app icon, and signature.
# SIGN_IDENTITY defaults to "-" (ad-hoc). Set it to a local self-signed certificate
# name to keep the microphone permission across rebuilds (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64)

scripts/icon.sh
swift build "${SWIFT_FLAGS[@]}" --product DirigibleApp
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --product DirigibleApp --show-bin-path)"

APP="build/Dirigible.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DirigibleApp" "$APP/Contents/MacOS/Dirigible"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp -R Support/Resources/. "$APP/Contents/Resources/"
cp build/icon/Assets.car build/icon/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo "$APP"
