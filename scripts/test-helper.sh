#!/bin/bash
# Run a test bundle outside `swift test`: the one runner of scripts/bench.sh --trace and
# scripts/sanitize.sh. It runs an ad-hoc signed copy of the Xcode swiftpm-testing-helper with the
# entitlement get-task-allow, because dyld refuses a sanitizer runtime in the Apple-signed helper
# ("Sanitizer load violates platform policy").
# Usage: [TEST_HELPER_INSERT=<dylib>] scripts/test-helper.sh --test-bundle-path <Mach-O of the
#        .xctest> --testing-library swift-testing [--filter <regex>] [--skip <regex>] ...
# The copy is .build/test-helper/swiftpm-testing-helper of the repo that holds this script, so the
# script works from any working folder. It signs the copy again only when the shasum of the Xcode
# helper differs from the stamp, or the copy has no get-task-allow: it copies to a temporary file,
# signs it, checks the entitlement, moves it into place, and then writes the stamp. make clean
# removes the copy, and the next call signs it again. TEST_HELPER_SOURCE names another source.
# macOS removes each DYLD variable when it starts /bin/bash (SIP), so a caller cannot pass them:
# this script sets DYLD_FRAMEWORK_PATH and DYLD_LIBRARY_PATH (the paths of swift test), and
# DYLD_INSERT_LIBRARIES from TEST_HELPER_INSERT, and then execs the copy. Swift Testing prints
# its report line on stderr, and xctrace --target-stdout logs only stdout, so stderr goes to stdout.
# scripts/test-helper.test.sh tests it.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)/.build/test-helper"
copy="$dir/swiftpm-testing-helper"
source="${TEST_HELPER_SOURCE:-$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper}"
sum="$(shasum < "$source")"
allowed() { codesign -d --entitlements - "$1" 2>/dev/null | grep -q com.apple.security.get-task-allow; }
if [[ "$(cat "$dir/stamp" 2>/dev/null)" != "$sum" ]] || ! allowed "$copy"; then
    mkdir -p "$dir"
    cat > "$dir/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
EOF
    temp="$(mktemp "$dir/swiftpm-testing-helper.XXXXXX")"
    trap 'rm -f "$temp"' EXIT
    cp "$source" "$temp"
    chmod 755 "$temp"
    { codesign -f -s - --entitlements "$dir/entitlements.plist" "$temp" && allowed "$temp"; } ||
        { echo "test-helper: cannot sign $temp with get-task-allow" >&2; exit 1; }
    mv -f "$temp" "$copy"
    trap - EXIT
    echo "$sum" > "$dir/stamp"
fi
dev="$(xcode-select -p)"
export DYLD_FRAMEWORK_PATH="$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks"
export DYLD_LIBRARY_PATH="$dev/Platforms/MacOSX.platform/Developer/usr/lib"
[[ -z "${TEST_HELPER_INSERT:-}" ]] || export DYLD_INSERT_LIBRARIES="$TEST_HELPER_INSERT"
exec "$copy" "$@" 2>&1
