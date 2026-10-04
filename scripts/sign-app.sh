#!/bin/bash
# Sign an app bundle. bundle.sh calls it. SIGN_IDENTITY defaults to "-" (ad-hoc).
# Usage: scripts/sign-app.sh <bundle>
set -euo pipefail
app="${1:?usage: sign-app.sh <bundle>}"
# A copied file can have extended attributes, for example a guide image from a screen capture
# (com.apple.FinderInfo). codesign refuses them as "detritus", so clear them first.
xattr -cr "$app"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app"
