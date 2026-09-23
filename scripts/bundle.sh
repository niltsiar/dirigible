#!/bin/bash
# Build build/Dirigible.app: universal release binary, Info.plist, and signature.
# SIGN_IDENTITY defaults to "-" (ad-hoc). Set it to a local self-signed certificate
# name to keep the microphone permission across rebuilds (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${OUT:-build}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64)

swift build "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"

APP="$OUT/Dirigible.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Dirigible" "$APP/Contents/MacOS/Dirigible"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

echo "$APP"
