#!/bin/bash
# Check that bundle.sh refuses a bundle path outside build/ before it builds or deletes
# anything. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
failures=0

for path in /private/tmp/dirigible-guard.app build/../dirigible-guard.app; do
    output="$("$here/bundle.sh" "$path" 2>&1)"
    status=$?
    if [[ $status -ne 2 ]] || ! grep -qF "bundle.sh: the bundle path must be build/<name>.app" <<<"$output"; then
        echo "FAIL: bundle.sh accepted a path outside build/: $path (exit $status)"
        failures=$((failures + 1))
    fi
done

# sign-app.sh signs a bundle that holds a file with extended attributes, for example a guide image
# from a screen capture (com.apple.FinderInfo). codesign alone refuses it as "detritus".
tmp="$(mktemp -d)"
app="$tmp/Fake.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
printf 'int main(void) { return 0; }\n' | cc -x c - -o "$app/Contents/MacOS/Fake"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>test.fake</string></dict></plist>\n' >"$app/Contents/Info.plist"
printf 'png' >"$app/Contents/Resources/image.png"
xattr -wx com.apple.FinderInfo "504E4766 3F3F3F3F $(printf '0%.0s' {1..48})" "$app/Contents/Resources/image.png"
output="$(SIGN_IDENTITY=- "$here/sign-app.sh" "$app" 2>&1)"
status=$?
if [[ $status -ne 0 ]] || ! codesign --verify "$app" 2>/dev/null; then
    echo "FAIL: sign-app.sh did not sign a bundle with an extended attribute (exit $status): $output"
    failures=$((failures + 1))
fi
rm -rf "$tmp"

[[ $failures -eq 0 ]] && echo "bundle.test.sh: all checks passed"
exit "$failures"
