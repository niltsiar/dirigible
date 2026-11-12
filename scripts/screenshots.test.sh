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

# A language with no folder in Support/Resources stops the script with exit 2, before a build, a
# folder, or a window.
err="$("$shots" "$tmp/shots-xx" xx 2>&1 >/dev/null)"
code=$?
[[ $code -eq 2 ]] || fail "an unknown language: exit $code, not 2"
[[ "$err" == *"Support/Resources/xx.lproj"* ]] || fail "an unknown language: the message does not name the folder: $err"
[[ ! -e "$tmp/shots-xx" ]] || fail "an unknown language: the folder was made"

# The images must not depend on the stored View preferences: the launch arguments pin the
# inspector hidden and the loudness meter shown. The argument domain wins over a stored value.
args="$(awk '/^open -a "\$app"/ { on = 1 } on { print } on && !/\\$/ { exit }' "$shots")"
[[ "$args" == *"-view.inspector.shown NO"* ]] || fail "the launch does not pin the inspector hidden: $args"
[[ "$args" == *"-view.loudness.shown YES"* ]] || fail "the launch does not pin the loudness meter shown: $args"

# The script ends the app with kill, so its journal ends unclean. The launch gets a log folder of its
# own under the script folder, made new and empty before the launch: no earlier journal shows the
# "did not quit in the normal way" banner in an image.
log_var="$(sed -n 's/.*--env "DIRIGIBLE_LOG_FOLDER=\$\([A-Za-z_]*\)".*/\1/p' <<<"$args")"
if [[ -z "$log_var" ]]; then
    fail "the launch has no --env DIRIGIBLE_LOG_FOLDER=\$<variable>: $args"
else
    grep -q "^$log_var=.*\\\$folder" "$shots" || fail "the log folder \$$log_var is not under the folder of the script"
    open_line="$(grep -n '^open -a "\$app"' "$shots" | head -n 1 | cut -d: -f1)"
    for step in "rm -rf \"\$$log_var\"" "mkdir -p \"\$$log_var\""; do
        at="$(grep -n -F -x "$step" "$shots" | head -n 1 | cut -d: -f1)"
        [[ -n "$at" && "$at" -lt "$open_line" ]] || fail "'$step' is not before the launch"
    done
fi

# An EXIT trap ends the launched app, so no app is left open when the script stops or fails.
exit_trap="$(sed -n "s/^trap \(.*\) EXIT\$/\1/p" "$shots")"
[[ "$exit_trap" == *'kill "$pid"'* ]] || fail "the script sets no EXIT trap that kills the launched app: '$exit_trap'"

# Each Support/Resources/<lang>.lproj folder has an arm in the language case of screenshots.sh, and
# its name passes the name check of the script (a region folder such as pt-PT included).
arms="$(awk '/^case "\$lang" in/ { on = 1; next } /^esac/ { on = 0 } on' "$shots")"
name_check="$(sed -n 's/^\[\[ "\$lang" =~ \(.*\) && -d .*/\1/p' "$shots")"
[[ -n "$name_check" ]] || fail "screenshots.sh has no name check of the language"
for dir in "$(dirname "$shots")"/../Support/Resources/*.lproj; do
    lang="$(basename "$dir" .lproj)"
    arm="(^|[[:space:]])$lang\) locale="
    [[ "$arms" =~ $arm ]] || fail "Support/Resources/$lang.lproj has no arm in the language case of screenshots.sh"
    [[ "$lang" =~ $name_check ]] || fail "Support/Resources/$lang.lproj fails the name check of screenshots.sh"
done

# Each image that the script shoots is in the final size check and in the header.
loop="$(sed -n 's/^for png in "\$images"\/screenshot-{\(.*\)}\.png; do$/\1/p' "$shots")"
[[ -n "$loop" ]] || fail "screenshots.sh has no final size check of the images"
header="$(sed -n '2,14p' "$shots" | tr -d '\n#')"
for name in $(sed -n 's/^shot screenshot-\(.*\)\.png$/\1/p' "$shots"); do
    [[ ",$loop," == *",$name,"* ]] || fail "screenshot-$name.png is not in the final size check"
    [[ "$header" == *"screenshot-$name.png"* ]] || fail "screenshot-$name.png is not in the header"
done

[[ $failures -eq 0 ]] && echo "screenshots tests: all passed" || { echo "screenshots tests: $failures failed"; exit 1; }
