#!/bin/bash
# Compile Support/AppIcon.icon into build/icon/Assets.car and build/icon/AppIcon.icns
# (decision 0026). scripts/bundle.sh runs it. Usage: scripts/icon.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
out="$root/build/icon"

xcrun --find actool > /dev/null 2>&1 || { echo "icon.sh: no actool; install Xcode 26 and select it with xcode-select" >&2; exit 1; }

# Remove the old catalog first, so a failed compile leaves no stale icon for bundle.sh.
rm -rf "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# actool needs the absolute path of the .icon. When it cannot read the .icon or a layer, it
# writes no file, prints a warning, and exits 0. So check its output and its files too.
status=0
log="$(xcrun actool "$root/Support/AppIcon.icon" --compile "$tmp" --app-icon AppIcon --platform macosx \
    --target-device mac --minimum-deployment-target 14.0 --include-all-app-icons \
    --output-partial-info-plist "$tmp/partial.plist" --output-format human-readable-text \
    --errors --warnings 2>&1)" || status=$?
# The dyld lines are noise of the Xcode tools on this macOS, not of the compile.
log="$(grep -v '^dyld\[' <<<"$log" || true)"
if [[ $status -ne 0 ]] || grep -qE 'error:|warning:' <<<"$log" \
    || [[ ! -f "$tmp/Assets.car" || ! -f "$tmp/AppIcon.icns" ]]; then
    echo "icon.sh: actool did not compile $root/Support/AppIcon.icon" >&2
    echo "$log" >&2
    exit 1
fi
mkdir -p "$root/build"
mv "$tmp" "$out"
