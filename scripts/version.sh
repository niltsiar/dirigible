#!/bin/bash
# Print the app version of the git work tree at $1 (default: the working folder), from the
# nearest annotated tag v<digit>... (docs/requirements/releases.md, Versions): the tag without
# its v, plus the describe suffix for a commit after the tag (0.3.4-2-gc197e40). A lightweight
# tag does not count. With no such tag, or with no git work tree, it prints 0.0.0. The same
# fallback is in Support/Info.plist and Sources/DirigibleCLI/Dirigible.swift.
set -uo pipefail
v="$(git -C "${1:-.}" describe --match 'v[0-9]*' 2>/dev/null)" || v=v0.0.0
echo "${v#v}"
