#!/bin/bash
# Check that text-tells.sh counts each tell pattern on a fixture table with one value per pattern,
# counts none on a clean table, reads only the value part of a line, and refuses a missing file.
# A value that is a tell of two patterns counts in both: the expected counts name each overlap.
# Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tells="$here/text-tells.sh"
command -v rg >/dev/null || { echo "FAIL: rg is missing"; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

dot=$'\xc2\xb7'
ellipsis=$'\xe2\x80\xa6'

cat >"$tmp/tells.strings" <<EOF
"a.colon" = "No call track: the first track wins";
"a.count" = "Clips changed: %lld.";
"a.sentences" = "Saved. Check the file";
"a.subject" = "Dirigible keeps the file";
"error.opener" = "Dirigible cannot open the file";
"a.because" = "Open the file because it moved";
"a.passive" = "The clip is trimmed";
"a.dot" = "48 kHz $dot 2 tracks";
"a.periods" = "Loading...";
"a.bang" = "Done!";
"a.contraction" = "Don't Save";
"a.negation" = "The clip does not move";
"a.owner" = "Dirigible could not sync";
EOF

cat >"$tmp/clean.strings" <<EOF
"c.ellipsis" = "Choose Input$ellipsis";
"c.result" = "Changed 3 clips.";
"c.record" = "Record";
"error.open" = "Open failed";
"c.take" = "The take saved to Desktop";
"c.count" = "Tracks 2";
"c.speed" = "48 kHz";
"c.state" = "The take is ready";
EOF

expect_tells="values 13
colon_fact 2
count_after_colon 1
two_sentences 1
app_name_subject 3
error_opener 1
contraction 1
uncontracted_negation 3
passive 1
because 1
middle_dot 1
three_periods 1
exclamation 1"

expect_clean="values 8
colon_fact 0
count_after_colon 0
two_sentences 0
app_name_subject 0
error_opener 0
contraction 0
uncontracted_negation 0
passive 0
because 0
middle_dot 0
three_periods 0
exclamation 0"

# The tell text sits in the key, not the value: the counter reads values only.
cat >"$tmp/keys.strings" <<EOF
"a.Dirigible cannot: be Done!" = "Record";
EOF
expect_keys="values 1
colon_fact 0
count_after_colon 0
two_sentences 0
app_name_subject 0
error_opener 0
contraction 0
uncontracted_negation 0
passive 0
because 0
middle_dot 0
three_periods 0
exclamation 0"

check() {
  local label="$1" file="$2" want="$3" got
  got="$(bash "$tells" "$file" 2>&1)"
  [[ "$got" == "$want" ]] || fail "$label: expected
$want
got
$got"
}

check "fixture with one value per pattern" "$tmp/tells.strings" "$expect_tells"
check "clean fixture" "$tmp/clean.strings" "$expect_clean"
check "tell text in a key only" "$tmp/keys.strings" "$expect_keys"

bash "$tells" "$tmp/missing.strings" >"$tmp/out" 2>&1
code=$?
[[ $code -eq 2 ]] || fail "missing file: expected exit 2, got $code"
rg -q 'missing.strings' "$tmp/out" || fail "missing file: the message does not name the file: $(cat "$tmp/out")"

if [[ $failures -eq 0 ]]; then echo "text-tells.test.sh: all passed"; else exit 1; fi
