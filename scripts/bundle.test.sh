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

# sign-app.sh signs the dirigible tool in Contents/Helpers before the app. An unsigned helper
# fails the app sign ("In subcomponent"). A cc binary is linker-signed only on arm64, so the case
# removes its signature.
tool="$app/Contents/Helpers/dirigible"
mkdir -p "${tool%/*}"
printf 'int main(void) { return 0; }\n' | cc -x c - -o "$tool"
codesign --remove-signature "$tool" 2>/dev/null || true
output="$(SIGN_IDENTITY=- "$here/sign-app.sh" "$app" 2>&1)"
status=$?
if [[ $status -ne 0 ]] || ! codesign --verify --strict --deep "$app" 2>/dev/null \
    || ! grep -qx 'Identifier=com.delineas.dirigible.cli' <<<"$(codesign -dv "$tool" 2>&1)"; then
    echo "FAIL: sign-app.sh did not sign the helper before the app (exit $status): $output"
    failures=$((failures + 1))
fi
rm -rf "$tmp"

# version.sh prints the app version from the annotated v<digit> tags (releases.md, Versions).
# Each case uses a new repo; no global hook or signing setting of the caller reaches it.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
tmp="$(mktemp -d)"
g() { git -C "$1" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    -c tag.gpgsign=false "${@:2}" >/dev/null 2>&1; }
repo() { mkdir "$tmp/$1" && g "$tmp/$1" init -q && g "$tmp/$1" commit -q --allow-empty -m one; }
expect_version() {
    local output status
    output="$("$here/version.sh" "$tmp/$1" 2>&1)"
    status=$?
    if [[ $status -ne 0 ]] || ! [[ "$output" =~ $2 ]]; then
        echo "FAIL: version.sh in the repo $1 printed '$output' (exit $status), expected $2"
        failures=$((failures + 1))
    fi
}
repo tagged && g "$tmp/tagged" tag -a v0.3.4 -m run
expect_version tagged '^0\.3\.4$'
repo fourth && g "$tmp/fourth" tag -a v0.3.4.1 -m run
expect_version fourth '^0\.3\.4\.1$'
repo after && g "$tmp/after" tag -a v0.3.4 -m run && g "$tmp/after" commit -q --allow-empty -m two
expect_version after '^0\.3\.4-1-g[0-9a-f]{7,}$'
# Only annotated tags count: a lightweight v0.9.9 on a later commit is not the version.
repo light && g "$tmp/light" tag -a v0.3.4 -m run && g "$tmp/light" commit -q --allow-empty -m two \
    && g "$tmp/light" tag v0.9.9
expect_version light '^0\.3\.4-1-g[0-9a-f]{7,}$'
repo other && g "$tmp/other" tag -a build-1 -m build
expect_version other '^0\.0\.0$'
repo next && g "$tmp/next" tag -a vnext -m next
expect_version next '^0\.0\.0$'
repo untagged
expect_version untagged '^0\.0\.0$'
mkdir "$tmp/nogit"
expect_version nogit '^0\.0\.0$'
rm -rf "$tmp"

# tag-release.sh makes the tags that version.sh reads. It has no Makefile line of its own (a
# Makefile change makes the push class bundle): its test runs here.
bash "$here/tag-release.test.sh" || failures=$((failures + 1))

[[ $failures -eq 0 ]] && echo "bundle.test.sh: all checks passed"
exit "$failures"
