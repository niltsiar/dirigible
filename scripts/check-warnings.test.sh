#!/bin/bash
# Check that check-warnings.sh passes a good manifest and fails each manifest that lets a warning
# through. Run by `make check`. dump-package reads only the manifest, so the fixtures need no
# source folders, no build, and no network.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-warnings.sh"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Writes a manifest with a library target A and a test target B, with these Swift settings.
manifest() {
  printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(\n    name: "F",\n    targets: [\n        .target(name: "A", swiftSettings: [%s]),\n        .testTarget(name: "B", swiftSettings: [%s]),\n    ])\n' \
    "$1" "$2" > "$tmp/Package.swift"
}

expect() {
  local want="$1" name="$2" got
  "$check" "$tmp" >/dev/null 2>&1 && got=pass || got=fail
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

strict='.treatAllWarnings(as: .error)'
manifest "$strict" "$strict"; expect pass 'each target treats warnings as errors'
manifest "$strict" ''; expect fail 'a test target without the setting'
manifest '' "$strict"; expect fail 'a library target without the setting'
manifest '.treatAllWarnings(as: .error, .when(configuration: .debug))' "$strict"; expect fail 'the setting only in debug'
manifest "$strict, .treatWarning(\"DeprecatedDeclaration\", as: .warning)" "$strict"; expect fail 'an exception for one warning'
manifest "$strict, .treatAllWarnings(as: .warning)" "$strict"; expect fail 'a second setting back to warnings'
manifest "$strict, .unsafeFlags([\"-suppress-warnings\"])" "$strict"; expect fail 'an unsafe flag'

[[ $failures -eq 0 ]] && echo "check-warnings tests: all passed"
exit $((failures > 0))
