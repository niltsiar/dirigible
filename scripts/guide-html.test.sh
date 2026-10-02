#!/bin/bash
# Check that guide-html.swift converts each element of the guide, prints the image paths, and
# refuses an element that it cannot convert. Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

cat > "$tmp/good.md" <<'EOF'
# Guía *one*

## Put a track

### The dirigible tool

Text with **bold**, `a < b`, [the top](#gua-one), and [Apple](https://www.apple.com).

![The window](images/shot.png)

- one
- two

1. first
2. second

> **Warning.** Record **replaces** audio.

| Command | Key |
|---|---|
| **Cut** | Command-X |

```sh
swift run dirigible --help
```
EOF

images="$(swift "$here/guide-html.swift" "$tmp/good.md" "$tmp/good.html")"
status=$?
[[ $status -eq 0 ]] || fail "good fixture exits $status"
[[ "$images" == "images/shot.png" ]] || fail "printed images: '$images'"
for want in \
    '<meta charset="utf-8">' \
    '<title>Guía one</title>' \
    '<h1 id="gua-one">Guía <em>one</em></h1>' \
    '<h2 id="put-a-track">Put a track</h2>' \
    '<h3 id="the-dirigible-tool">The dirigible tool</h3>' \
    '<strong>bold</strong>' \
    '<code>a &lt; b</code>' \
    '<a href="#gua-one">the top</a>' \
    '<a href="https://www.apple.com">Apple</a>' \
    '<img src="images/shot.png" alt="The window">' \
    '<ul><li><p>one</p>' \
    '<ol><li><p>first</p>' \
    '<blockquote><p><strong>Warning.</strong> Record <strong>replaces</strong> audio.</p>' \
    '<table><tr><th>Command</th><th>Key</th></tr>' \
    '<tr><td><strong>Cut</strong></td><td>Command-X</td></tr>' \
    '<pre><code>swift run dirigible --help'; do
    grep -qF -- "$want" "$tmp/good.html" 2>/dev/null || fail "no '$want' in the HTML"
done

# refuse <name> <reason> <markdown>: exit 1 with the reason, and no output file.
refuse() {
    printf '%s\n' "$3" > "$tmp/bad.md"
    rm -f "$tmp/bad.html"
    output="$(swift "$here/guide-html.swift" "$tmp/bad.md" "$tmp/bad.html" 2>&1)"
    status=$?
    [[ $status -eq 1 ]] || fail "$1: exit $status, not 1"
    grep -qF "guide-html: $2" <<<"$output" || fail "$1: no '$2' in: $output"
    [[ ! -e "$tmp/bad.html" ]] || fail "$1: wrote an output file"
}
refuse 'inline HTML' 'raw HTML' 'Text <img src="images/shot.png"> here.'
refuse 'block HTML' 'raw HTML' '<img src="images/shot.png">'
refuse 'image outside images/' 'image outside images/: ../secret.png' '![x](../secret.png)'
refuse 'remote image' 'image outside images/: https://a.b/x.png' '![x](https://a.b/x.png)'

output="$(swift "$here/guide-html.swift" "$tmp/missing.md" "$tmp/missing.html" 2>&1)"
status=$?
[[ $status -eq 2 ]] || fail "missing input: exit $status, not 2"
grep -qF "guide-html: no file" <<<"$output" || fail "missing input: no reason in: $output"
[[ ! -e "$tmp/missing.html" ]] || fail "missing input: wrote an output file"

[[ $failures -eq 0 ]] && echo "guide-html.test.sh: all checks passed"
exit "$failures"
