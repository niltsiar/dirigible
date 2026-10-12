#!/bin/bash
# Check that trace-top.py counts the leaf frame of each sample of a time-profile export, with
# frames and whole backtraces given once by id and then by ref, keeps only the samples under a
# frame with --under, and exits 1 on an unresolved ref or on no sample under the frame.
# The first fixture is hand-made; scripts/trace-top.fixture.xml is 24 rows of a real export of
# the Command-F bench (its first line was counted by an independent regex count).
# make test-hooks runs it.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# Three samples: two with the leaf A under X (the second gives its whole stack as a backtrace ref),
# one with the leaf B under main (main given by ref). A sentinel row has no backtrace.
cat > "$tmp/small.xml" <<'EOF'
<?xml version="1.0"?>
<trace-query-result><node><schema name="time-profile"/>
<row><weight id="1" fmt="1.00 ms">1000000</weight><backtrace id="10"><frame id="11" name="A" addr="0x1"/><frame id="12" name="X" addr="0x2"/><frame id="13" name="main" addr="0x3"/></backtrace></row>
<row><weight ref="1"/><backtrace ref="10"/></row>
<row><weight ref="1"/><backtrace id="20"><frame id="21" name="B" addr="0x4"><binary id="22" name="b"/></frame><frame ref="13"/></backtrace></row>
<row><weight ref="1"/><sentinel/></row>
</node></trace-query-result>
EOF
sed 's/<frame ref="13"\/>/<frame ref="99"\/>/' "$tmp/small.xml" > "$tmp/unresolved.xml"

out="$("$here/trace-top.py" "$tmp/small.xml" 2>&1)" || fail "all samples: exit $?: $out"
[[ "$out" == $'A 2 66.7%\nB 1 33.3%' ]] || fail "all samples: $out"
out="$("$here/trace-top.py" --under X "$tmp/small.xml" 2>&1)" || fail "under X: exit $?: $out"
[[ "$out" == 'A 2 100.0%' ]] || fail "under X: $out"
out="$("$here/trace-top.py" --top 1 "$tmp/small.xml" 2>&1)" || fail "top 1: exit $?: $out"
[[ "$out" == 'A 2 66.7%' ]] || fail "top 1: $out"
out="$("$here/trace-top.py" --under Y "$tmp/small.xml" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'no sample under Y'* ]] || fail "under Y: exit $code: $out"
out="$("$here/trace-top.py" "$tmp/unresolved.xml" 2>&1)"
code=$?
[[ $code -eq 1 && "$out" == *'unresolved ref 99'* ]] || fail "unresolved ref: exit $code: $out"

# A frame with no name and no address counts as "?", also with --under.
sed 's/<frame id="21" name="B" addr="0x4">/<frame id="21">/' "$tmp/small.xml" > "$tmp/nameless.xml"
out="$("$here/trace-top.py" --under main "$tmp/nameless.xml" 2>&1)" || fail "nameless frame: exit $?: $out"
[[ "$out" == $'A 2 66.7%\n? 1 33.3%' ]] || fail "nameless frame: $out"

out="$("$here/trace-top.py" "$here/trace-top.fixture.xml" 2>&1)" || fail "real export: exit $?: $out"
[[ "$(head -1 <<<"$out")" == '0x7ff803c57ebf 3 13.0%' ]] || fail "real export: $out"

[[ $failures -eq 0 ]] && echo "trace-top tests: all passed"
exit $((failures > 0))
