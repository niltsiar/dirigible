#!/bin/bash
# Check that screenshots.sh refuses to start when a process named Dirigible runs, and does not
# stop that process. The case builds nothing and opens no window. Run by `make test-hooks`.
set -uo pipefail
shots="$(cd "$(dirname "$0")" && pwd -P)/screenshots.sh"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
pid=""
trap '[[ -z "$pid" ]] || kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A copy of /bin/sleep gets a SIGKILL (code signature), so compile a process named Dirigible.
printf '#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n' | cc -x c - -o "$tmp/Dirigible"
"$tmp/Dirigible" &
pid=$!
disown "$pid"
err="$("$shots" "$tmp/shots" 2>&1 >/dev/null)"
code=$?
[[ $code -eq 1 ]] || fail "a running Dirigible: exit $code, not 1"
[[ "$err" == *"Quit it"* ]] || fail "a running Dirigible: no refusal: $err"
kill -0 "$pid" 2>/dev/null || fail "a running Dirigible: the script stopped it"
[[ ! -e "$tmp/shots" ]] || fail "a running Dirigible: the folder was made"

[[ $failures -eq 0 ]] && echo "screenshots tests: all passed" || { echo "screenshots tests: $failures failed"; exit 1; }
