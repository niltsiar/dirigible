#!/bin/bash
# Check verify-copy.sh in a temp repo. Fakes on PATH replace open, osascript, tccutil, defaults,
# and swift, so no case launches the app, shows a prompt, or changes TCC or the preferences. The
# fake open starts a compiled dummy at the copy path, so pgrep and kill are real. Each fake gives
# the exit code and the text of the real tool for the no-data case (decisions.tsv of run
# 2026-10-01-verify-copy, U14 and U15). Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
# Run from the temp folder, not from a repo: a script that finds the root in the working folder
# then fails, and never acts on the real build/.
cd "$tmp" || exit 1
started=()
# Kill each process that the test or a fake open started, then remove the temp folders.
trap 'for p in "${started[@]}" $(cat "$tmp"/case-*/state/pids 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
failures=0
# Each case repo has its own copy ID (verify-copy.sh id); new_case sets copy_id.
real_id=com.delineas.dirigible

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# A copy of /bin/sleep gets a SIGKILL (code signature), so compile a process named Dirigible.
printf '#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n' | cc -x c - -o "$tmp/Dirigible"

# The fakes. Each one reads the state of the case from $FAKE_STATE and logs one line per call.
mkdir -p "$tmp/bin" "$tmp/badpgrep"
cat >"$tmp/bin/open" <<'FAKE'
#!/bin/bash
# Log the arguments. Start <path after -a>/Contents/MacOS/Dirigible with the arguments after --args.
echo "$*" >>"$FAKE_STATE/open.log"
app="" args=() after=0
while [[ $# -gt 0 ]]; do
    if [[ $after -eq 1 ]]; then args+=("$1")
    elif [[ "$1" == -a ]]; then app="$2"; shift
    elif [[ "$1" == --args ]]; then after=1
    fi
    shift
done
"$app/Contents/MacOS/Dirigible" ${args[@]+"${args[@]}"} </dev/null >/dev/null 2>&1 &
echo $! >>"$FAKE_STATE/pids"
disown
exit 0
FAKE
cat >"$tmp/bin/tccutil" <<'FAKE'
#!/bin/bash
# Log whether the copy bundle is on disk, then the arguments.
[[ -e "$FAKE_COPY" ]] && where=on-disk || where=absent
echo "$where: $*" >>"$FAKE_STATE/tccutil.log"
if [[ -f "$FAKE_STATE/tccutil.fail" ]]; then
    cat "$FAKE_STATE/tccutil.fail" >&2
    exit "$(cat "$FAKE_STATE/tccutil.code")"
fi
echo "Successfully reset $2 approval status for $3"
FAKE
cat >"$tmp/bin/defaults" <<'FAKE'
#!/bin/bash
# Log the arguments. A delete of a domain that the case did not set gives the text of the real tool.
echo "$*" >>"$FAKE_STATE/defaults.log"
if [[ -f "$FAKE_STATE/defaults.fail" ]]; then
    cat "$FAKE_STATE/defaults.fail" >&2
    exit 1
fi
if [[ "$1" == delete ]] && grep -qx "$2" "$FAKE_STATE/domains" 2>/dev/null; then
    grep -vx "$2" "$FAKE_STATE/domains" >"$FAKE_STATE/domains.new"
    mv "$FAKE_STATE/domains.new" "$FAKE_STATE/domains"
    exit 0
fi
printf '2026-10-01 22:41:46.686 defaults[34134:28029470] \nDomain (%s) not found.\nDefaults have not been changed.\n' "$2" >&2
exit 1
FAKE
cat >"$tmp/bin/swift" <<'FAKE'
#!/bin/bash
# Log the bundle ID variable and the arguments. `swift -` is the lock snippet: print the lock
# state of the case (default unlocked). Else it is ax.swift: print the dump of the case (default:
# one window), and exit with the exit code and the stderr of the case.
echo "DIRIGIBLE_BUNDLE_ID=${DIRIGIBLE_BUNDLE_ID-unset} $*" >>"$FAKE_STATE/swift.log"
if [[ "${1:-}" == - ]]; then
    cat >/dev/null
    cat "$FAKE_STATE/lock" 2>/dev/null || echo unlocked
    exit "$(cat "$FAKE_STATE/lock.code" 2>/dev/null || echo 0)"
fi
if [[ -f "$FAKE_STATE/ax.out" ]]; then cat "$FAKE_STATE/ax.out"; else
    printf 'Role=AXApplication Title=Dirigible\n Role=AXWindow Title=Pilot Episode\n'
fi
[[ ! -f "$FAKE_STATE/ax.err" ]] || cat "$FAKE_STATE/ax.err" >&2
exit "$(cat "$FAKE_STATE/ax.code" 2>/dev/null || echo 0)"
FAKE
cat >"$tmp/bin/osascript" <<'FAKE'
#!/bin/bash
# Log the arguments and the script on stdin. Print the status line that the case set. With no
# status line, fail as the AppleScript with no prompt window, or with the error text of the case.
echo "$*" >>"$FAKE_STATE/osascript.log"
cat >>"$FAKE_STATE/osascript.script"
if [[ -f "$FAKE_STATE/osascript.status" ]]; then
    cat "$FAKE_STATE/osascript.status"
    exit 0
fi
if [[ -f "$FAKE_STATE/osascript.fail" ]]; then
    cat "$FAKE_STATE/osascript.fail" >&2
    exit 1
fi
echo "execution error: no prompt window (-1719)" >&2
exit 1
FAKE
cat >"$tmp/badpgrep/pgrep" <<'FAKE'
#!/bin/bash
echo "pgrep: illegal pattern" >&2
exit 2
FAKE
mkdir -p "$tmp/badcodesign"
cat >"$tmp/badcodesign/codesign" <<'FAKE'
#!/bin/bash
echo "${@: -1}: bundle format unrecognized, invalid, or unsuitable" >&2
exit 1
FAKE
chmod +x "$tmp"/bin/* "$tmp/badpgrep/pgrep" "$tmp/badcodesign/codesign"

# new_case <name>: a fresh temp repo with a copy of the script, a fake build/Dirigible.app, and
# a fake HOME. It sets repo, copy, exe, real, and state, and exports the state for the fakes.
n=0
new_case() {
    n=$((n + 1))
    local dir="$tmp/case-$n"
    repo="$dir/repo" state="$dir/state"
    mkdir -p "$repo/scripts" "$repo/Sources" "$repo/Support" "$state" "$dir/home"
    echo "// x" >"$repo/Sources/x.swift"
    echo x >"$repo/Support/x.txt"
    echo "// swift-tools-version:6.2" >"$repo/Package.swift"
    echo "// stub" >"$repo/scripts/ax.swift"
    cp "$here/verify-copy.sh" "$repo/scripts/" 2>/dev/null
    git -C "$repo" init -q
    git -C "$repo" add -A
    git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
    real="$repo/build/Dirigible.app"
    mkdir -p "$real/Contents/MacOS"
    cp "$tmp/Dirigible" "$real/Contents/MacOS/Dirigible"
    cat >"$real/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Dirigible</string>
<key>CFBundleIdentifier</key><string>$real_id</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    copy="$repo/build/verify/Dirigible-verify.app"
    exe="$copy/Contents/MacOS/Dirigible"
    export FAKE_STATE="$state" FAKE_COPY="$copy" HOME="$dir/home"
    export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    script="$repo/scripts/verify-copy.sh"
    saved="$HOME/Library/Saved Application State"
    copy_id="$("$script" id 2>/dev/null)"
}

# run <args...>: run the script; set out, err, and code.
run() {
    out="$("$script" "$@" 2>"$tmp/err")"
    code=$?
    err="$(cat "$tmp/err")"
}

# dummy <path>: start the compiled dummy at <path> in a subshell, so launchd reaps it when it dies
# and kill -0 then fails. Print its PID.
dummy() {
    mkdir -p "$(dirname "$1")"
    [[ -e "$1" ]] || cp "$tmp/Dirigible" "$1"
    ("$1" </dev/null >/dev/null 2>&1 & echo $!)
}

# gone <pid>: true when the process ends within 5 s.
gone() {
    local i
    for i in $(seq 50); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}

# A PID that the script printed is a process whose executable is the copy.
is_copy() { [[ "$1" =~ ^[0-9]+$ ]] && [[ "$(ps -o command= -p "$1")" == "$exe"* ]]; }

# C1 usage
new_case
run
[[ $code -eq 2 && "$err" == *"usage: verify-copy.sh"* ]] || fail "usage: no command: exit $code: $err"
run walk
[[ $code -eq 2 && "$err" == *"usage: verify-copy.sh"* ]] || fail "usage: unknown command: exit $code: $err"

# C2 no build
new_case
rm -rf "$real"
run start
[[ $code -eq 1 && "$err" == *"run make app"* ]] || fail "no build: exit $code: $err"
[[ ! -e "$repo/build/verify" ]] || fail "no build: build/verify was made"
[[ ! -s "$state/open.log" ]] || fail "no build: open got a call"

# C3 start new, with and without a package
new_case
run start
pid="$out"
[[ $code -eq 0 ]] || fail "start new: exit $code: $err"
is_copy "$pid" || fail "start new: '$pid' is not the PID of the copy"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$copy/Contents/Info.plist" 2>&1)" == "$copy_id" ]] ||
    fail "start new: the copy has another bundle ID"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$real/Contents/Info.plist" 2>&1)" == "$real_id" ]] ||
    fail "start new: the bundle ID of build/Dirigible.app changed"
codesign --verify "$copy" 2>/dev/null || fail "start new: codesign --verify of the copy failed"
[[ "$(cat "$state/open.log" 2>/dev/null)" == "-a $copy" ]] || fail "start new: open got: $(cat "$state/open.log" 2>/dev/null)"
run stop
run start "$repo/Pilot.dirigible"
[[ $code -eq 0 ]] && is_copy "$out" || fail "start new with a package: exit $code: $err"
[[ "$(tail -1 "$state/open.log" 2>/dev/null)" == "-a $copy $repo/Pilot.dirigible" ]] ||
    fail "start new with a package: open got: $(tail -1 "$state/open.log" 2>/dev/null)"
run stop

# C3d a package that routes a track to an input device opens with no flag (user decision
# 2026-10-12: a check can use the internal mic). The removed --live-input flag gets the usage text.
pkg="$repo/Live.dirigible"
mkdir -p "$pkg"
printf '<session><tracks><track name="Host"><route device="BuiltInMicrophoneDevice" channels="1"/></track></tracks></session>\n' >"$pkg/session.xml"
: >"$state/open.log"
run start "$pkg"
[[ $code -eq 0 ]] && is_copy "$out" || fail "device route: exit $code: $err"
[[ "$(tail -1 "$state/open.log" 2>/dev/null)" == "-a $copy $pkg" ]] ||
    fail "device route: open got: $(tail -1 "$state/open.log" 2>/dev/null)"
run stop
: >"$state/open.log"
run start --live-input c3 "$pkg"
[[ $code -eq 2 && "$err" == *"usage: verify-copy.sh"* ]] || fail "--live-input: exit $code: $err"
[[ ! -s "$state/open.log" ]] || fail "--live-input: open got: $(cat "$state/open.log")"

# C3b start with arguments
new_case
run start -- --args -AppleLanguages "(es)"
pid="$out"
[[ $code -eq 0 ]] || fail "start with arguments: exit $code: $err"
[[ "$(cat "$state/open.log" 2>/dev/null)" == "-a $copy --args -AppleLanguages (es)" ]] ||
    fail "start with arguments: open got: $(cat "$state/open.log" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ && "$(ps -o command= -p "$pid")" == "$exe -AppleLanguages (es)" ]] ||
    fail "start with arguments: '$pid' is not the copy with the arguments"
run stop
[[ $code -eq 0 ]] && gone "$pid" || fail "start with arguments: stop did not kill $pid: $err"

# C3c start from another folder
new_case
out="$(cd / && "$script" start 2>"$tmp/err")"
code=$?
pid="$out"
[[ $code -eq 0 ]] && is_copy "$pid" || fail "start from another folder: exit $code: $(cat "$tmp/err")"
[[ -d "$copy" ]] || fail "start from another folder: no copy in build/verify of the repo"
(cd / && "$script" stop >/dev/null 2>&1)
gone "$pid" && [[ ! -e "$copy" ]] || fail "start from another folder: stop left the copy"

# C4 start stale
new_case
mkdir -p "$copy/Contents"
touch "$copy/marker"
echo 1 >"$repo/build/verify/source-mtime"
touch -t 202609301200 "$real/Contents/MacOS/Dirigible"
run start
[[ $code -eq 0 ]] || fail "start stale: exit $code: $err"
[[ ! -e "$copy/marker" ]] || fail "start stale: the old copy stayed"
[[ "$(cat "$repo/build/verify/source-mtime" 2>/dev/null)" == "$(stat -f %m "$real/Contents/MacOS/Dirigible")" ]] ||
    fail "start stale: source-mtime is not the new mtime"
run stop

# C4b start clean
new_case
mkdir -p "$saved/$copy_id.savedState"
echo "$copy_id" >"$state/domains"
run start
[[ $code -eq 0 ]] || fail "start clean: exit $code: $err"
[[ ! -e "$saved/$copy_id.savedState" ]] || fail "start clean: the saved state stayed"
grep -qx "absent: reset All $copy_id" "$state/tccutil.log" 2>/dev/null || fail "start clean: no tccutil reset"
grep -qx "delete $copy_id" "$state/defaults.log" 2>/dev/null || fail "start clean: no defaults delete"
[[ ! -s "$state/domains" ]] || fail "start clean: the domain stayed"
run stop

# C5 start running
new_case
run start
first="$out"
run start
[[ $code -eq 0 ]] || fail "start running: exit $code: $err"
is_copy "$out" && [[ "$out" != "$first" ]] || fail "start running: no new copy: '$out'"
gone "$first" || fail "start running: the old copy $first still runs"
run stop

# C6 second Dirigible (start and stop; the doctor part is in a later case)
new_case
other="$(dummy "$tmp/case-$n/other/Dirigible")"
started+=("$other")
run start
kill -0 "$other" 2>/dev/null || fail "second Dirigible: start stopped the other Dirigible"
run stop
kill -0 "$other" 2>/dev/null || fail "second Dirigible: stop stopped the other Dirigible"

# Each worktree root gets its own copy ID, so the copies of two worktrees can run at the same
# time, and a stop in one tree does not reset the grants of the copy of another tree.
new_case
first="$copy_id"
[[ "$first" =~ ^com\.delineas\.dirigible\.verify-[0-9a-f]{8}$ ]] || fail "id: not the copy ID form: '$first'"
run id
[[ $code -eq 0 && "$out" == "$first" ]] || fail "id: a second call in one root gives '$out' (exit $code), not '$first'"
new_case
[[ -n "$copy_id" && "$copy_id" != "$first" ]] || fail "id: two roots give one ID: '$copy_id'"
run start
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$copy/Contents/Info.plist" 2>&1)" == "$copy_id" ]] ||
    fail "id: start does not set the ID of its root"
mkdir -p "$saved/$first.savedState"
run stop
[[ -d "$saved/$first.savedState" ]] || fail "id: stop removed the saved state of the ID of another root"
! grep -qF "$first" "$state/tccutil.log" "$state/defaults.log" 2>/dev/null || fail "id: stop reset the ID of another root"

# C15 stop
new_case
run start
pid="$out"
mkdir -p "$saved/$copy_id.savedState"
run stop
[[ $code -eq 0 ]] || fail "stop: exit $code: $err"
gone "$pid" || fail "stop: the copy $pid still runs"
grep -qx "on-disk: reset All $copy_id" "$state/tccutil.log" 2>/dev/null ||
    fail "stop: no tccutil reset with the copy on disk: $(cat "$state/tccutil.log" 2>/dev/null)"
grep -qx "delete $copy_id" "$state/defaults.log" 2>/dev/null || fail "stop: no defaults delete"
[[ ! -e "$saved/$copy_id.savedState" && ! -e "$repo/build/verify" ]] || fail "stop: a folder stayed"

# C15b stop touches only the copy
new_case
mkdir -p "$saved/$real_id.savedState"
realpid="$(dummy "$real/Contents/MacOS/Dirigible")"
started+=("$realpid")
run start
kill -0 "$realpid" 2>/dev/null || fail "only the copy: start stopped the process at the real app path"
run stop
kill -0 "$realpid" 2>/dev/null || fail "only the copy: stop stopped the process at the real app path"
[[ -d "$saved/$real_id.savedState" ]] || fail "only the copy: the saved state of the real ID is gone"
[[ $(grep -c . "$state/tccutil.log" 2>/dev/null) -eq 2 && $(grep -c . "$state/defaults.log" 2>/dev/null) -eq 2 ]] ||
    fail "only the copy: not one tccutil and one defaults call for each of start and stop"
while IFS= read -r line; do
    [[ "$line" == *" $copy_id" ]] || fail "only the copy: a call not of the copy ID: $line"
    [[ "$line" != *" $real_id" ]] || fail "only the copy: a call of the real ID: $line"
done < <(cat "$state/tccutil.log" "$state/defaults.log" 2>/dev/null)
while IFS= read -r line; do
    words=(${line#*: })
    [[ ${#words[@]} -ge 3 ]] || fail "only the copy: tccutil with no bundle ID: $line"
done < <(cat "$state/tccutil.log" 2>/dev/null)

# C16 stop idle: tccutil exits 0 (U14 probe), then with the no-bundle text
for variant in success no-bundle; do
    new_case
    mkdir -p "$saved/$copy_id.savedState" "$repo/build/verify"
    if [[ $variant == no-bundle ]]; then
        printf 'tccutil: No such bundle identifier "%s": The operation couldn’t be completed.\n' "$copy_id" >"$state/tccutil.fail"
        echo 1 >"$state/tccutil.code"
    fi
    run stop
    [[ $code -eq 0 ]] || fail "stop idle ($variant): exit $code: $err"
    [[ "$out$err" == *"No verify copy runs"* ]] || fail "stop idle ($variant): no message: $out $err"
    [[ ! -e "$saved/$copy_id.savedState" && ! -e "$repo/build/verify" ]] || fail "stop idle ($variant): a folder stayed"
done

# C16b stop cleanup error: defaults with another text; tccutil with the no-bundle text and the copy on disk
for tool in defaults tccutil; do
    new_case
    run start
    pid="$out"
    mkdir -p "$saved/$copy_id.savedState"
    if [[ $tool == defaults ]]; then
        echo "Could not write domain $copy_id; exiting" >"$state/defaults.fail"
    else
        printf 'tccutil: No such bundle identifier "%s": The operation couldn’t be completed.\n' "$copy_id" >"$state/tccutil.fail"
        echo 1 >"$state/tccutil.code"
    fi
    run stop
    [[ $code -eq 1 && "$err" == *"$tool"* ]] || fail "stop cleanup error ($tool): exit $code: $err"
    gone "$pid" || fail "stop cleanup error ($tool): the copy still runs"
    [[ ! -e "$saved/$copy_id.savedState" && ! -e "$repo/build/verify" ]] || fail "stop cleanup error ($tool): a folder stayed"
done

# C16b start cleanup error: no copy and no open call
for tool in defaults tccutil; do
    new_case
    if [[ $tool == defaults ]]; then
        echo "Could not write domain $copy_id; exiting" >"$state/defaults.fail"
    else
        echo "tccutil: Failed to reset All approval status for $copy_id" >"$state/tccutil.fail"
        echo 1 >"$state/tccutil.code"
    fi
    run start
    [[ $code -eq 1 && "$err" == *"$tool"* ]] || fail "start cleanup error ($tool): exit $code: $err"
    [[ ! -e "$copy" ]] || fail "start cleanup error ($tool): the copy was made"
    [[ ! -s "$state/open.log" ]] || fail "start cleanup error ($tool): open got a call"
done

# codesign error: start exits 1 with the output of codesign, and opens no copy.
new_case
PATH="$tmp/badcodesign:$PATH" run start
[[ $code -eq 1 && "$err" == *"codesign failed:"*"bundle format unrecognized"* ]] || fail "start codesign error: exit $code: $err"
[[ ! -s "$state/open.log" ]] || fail "start codesign error: open got a call"

# pgrep error: stop exits 2 with the stderr of pgrep, and build/verify stays.
new_case
run start
PATH="$tmp/badpgrep:$PATH" run stop
[[ $code -eq 2 && "$err" == *"pgrep: illegal pattern"* ]] || fail "pgrep error: exit $code: $err"
[[ -d "$copy" ]] || fail "pgrep error: build/verify was deleted"
run stop

# C7 ax: ax.swift of the repo gets the copy ID and the arguments.
new_case
run ax dump 1
[[ $code -eq 0 ]] || fail "ax: exit $code: $err"
[[ "$(cat "$state/swift.log" 2>/dev/null)" == "DIRIGIBLE_BUNDLE_ID=$copy_id $repo/scripts/ax.swift dump 1" ]] ||
    fail "ax: swift got: $(cat "$state/swift.log" 2>/dev/null)"

# now: the time in seconds, with a fraction.
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
# run_limited <args...>: run as run, but stop the script after 20 s (a missing poll limit).
run_limited() {
    out="$(perl -e 'alarm 20; exec @ARGV' "$script" "$@" 2>"$tmp/err")"
    code=$?
    err="$(cat "$tmp/err")"
}
calls() { grep -c . "$state/osascript.log" 2>/dev/null || true; }

# C9 prompt shown: one osascript call that checks the window and clicks in the same script. The
# names come from the prompt of the copy (.scratchpads/verify/live-take-e6fddc5/prompt-ax.txt).
new_case
echo clicked >"$state/osascript.status"
run prompt Allow
[[ $code -eq 0 ]] || fail "prompt shown: exit $code: $err"
[[ "$(calls)" -eq 1 ]] || fail "prompt shown: $(calls) osascript calls, not 1"
[[ "$(cat "$state/osascript.log" 2>/dev/null)" == "- Dirigible-verify.app Allow" ]] ||
    fail "prompt shown: osascript got: $(cat "$state/osascript.log" 2>/dev/null)"
script_text="$(cat "$state/osascript.script" 2>/dev/null)"
[[ "$script_text" == *"exists window 1"* && "$script_text" == *"click button"* ]] ||
    fail "prompt shown: the AppleScript does not check the window and click in one script"

# C10 prompt not shown: poll to the limit, then exit 1 with the last stderr line.
new_case
t0="$(now)"
VERIFY_COPY_PROMPT_WAIT=1 run_limited prompt Allow
elapsed="$(echo "$(now) - $t0" | bc)"
[[ $code -eq 1 && "$err" == *"no privacy prompt"* && "$err" == *"no prompt window (-1719)"* ]] ||
    fail "prompt not shown: exit $code: $err"
[[ "$(calls)" -ge 2 ]] || fail "prompt not shown: $(calls) osascript calls, not 2 or more"
[[ "$(echo "$elapsed >= 1" | bc)" -eq 1 ]] || fail "prompt not shown: it ended after $elapsed s, before the limit"

# C10b prompt error: no Automation grant (-1743), and a -1719 text with no "no prompt window".
for text in "execution error: Not authorized to send Apple events to System Events. (-1743)" \
    "execution error: System Events got an error: osascript is not allowed assistive access. (-1719)"; do
    new_case
    echo "$text" >"$state/osascript.fail"
    VERIFY_COPY_PROMPT_WAIT=1 run_limited prompt Allow
    [[ $code -eq 2 && "$err" == *"$text"* ]] || fail "prompt error ($text): exit $code: $err"
    [[ "$(calls)" -eq 1 ]] || fail "prompt error ($text): $(calls) osascript calls, not 1"
done

# C11 prompt of another app
new_case
echo "app “Other.app” would like to access the microphone." >"$state/osascript.status"
run prompt Allow
[[ $code -eq 1 && "$err" == *"“Other.app” would like to access the microphone."* ]] ||
    fail "prompt of another app: exit $code: $err"

# C12 prompt wrong button
new_case
echo "buttons Don’t Allow, Allow" >"$state/osascript.status"
run prompt Permitir
[[ $code -eq 1 && "$err" == *"Permitir"* && "$err" == *"Don’t Allow, Allow"* ]] ||
    fail "prompt wrong button: exit $code: $err"

# doctor_case: a new case whose sources are older than the app executable, then start.
doctor_case() {
    new_case
    touch -t 202601010000 "$repo/Sources/x.swift" "$repo/Support/x.txt" "$repo/Package.swift" "$repo/Sources" "$repo/Support"
    touch -t 202609010000 "$real/Contents/MacOS/Dirigible"
    run start
    pid="$out"
}
# expect_doctor_fail <case> <fact> [<text>]: doctor exits 1 and names the fact (and the text).
expect_doctor_fail() {
    run doctor
    [[ $code -eq 1 ]] || fail "$1: exit $code, not 1: $out $err"
    grep -q "^FAIL $2" <<<"$out" || fail "$1: no FAIL line for $2: $out"
    [[ -z "${3:-}" || "$out$err" == *"$3"* ]] || fail "$1: no \"$3\": $out $err"
}

# C13 doctor ok: four ok lines, for the facts (a) to (f).
doctor_case
run doctor
[[ $code -eq 0 ]] || fail "doctor ok: exit $code: $out $err"
[[ "$(grep -c '^ok ' <<<"$out")" -eq 4 && "$(grep -c . <<<"$out")" -eq 4 ]] || fail "doctor ok: not four ok lines: $out"
[[ "$out" == *"PID $pid"* ]] || fail "doctor ok: no PID $pid: $out"
grep -qx "DIRIGIBLE_BUNDLE_ID=$copy_id $repo/scripts/ax.swift dump 2" "$state/swift.log" ||
    fail "doctor ok: no ax dump 2 of the copy: $(cat "$state/swift.log")"
run stop

# C6 doctor part: doctor prints the PID of the copy, not of the other Dirigible.
doctor_case
other="$(dummy "$tmp/case-$n/other/Dirigible")"
started+=("$other")
run doctor
[[ "$out" == *"PID $pid"* && "$out" != *"$other"* ]] || fail "second Dirigible: doctor: $out"
kill -0 "$other" 2>/dev/null || fail "second Dirigible: doctor stopped the other Dirigible"
run stop

# C14 (a) no copy runs
doctor_case
run stop
expect_doctor_fail "doctor a" "(a)"

# C14 (b) the executable of build/Dirigible.app changed after start; (c) still holds.
doctor_case
touch -t 202609020000 "$real/Contents/MacOS/Dirigible"
expect_doctor_fail "doctor b" "(b)"
grep -q "^FAIL (c)" <<<"$out" && fail "doctor b: (c) failed: $out"
run stop

# C14 (c) a source is newer than the app executable; (b) still holds.
doctor_case
run doctor
grep -q "^FAIL (c)" <<<"$out" && fail "doctor c: (c) failed before the touch: $out"
touch -t 202609020000 "$repo/Sources/x.swift"
expect_doctor_fail "doctor c" "(c)" "Sources/x.swift"
grep -q "^FAIL (b)" <<<"$out" && fail "doctor c: (b) failed: $out"
run stop

# C14 (c) find error: with no Sources, find exits 1, and (c) prints its stderr.
doctor_case
rm -rf "$repo/Sources"
expect_doctor_fail "doctor c find error" "(c)" "Sources: No such file or directory"
run stop

# C14 (d) no window, and another ax exit
doctor_case
echo "Role=AXApplication Title=Dirigible" >"$state/ax.out"
expect_doctor_fail "doctor d" "(d)"
echo "No app with the bundle ID $copy_id runs." >"$state/ax.err"
echo 1 >"$state/ax.code"
expect_doctor_fail "doctor d ax failed" "(d)" "ax failed: No app with the bundle ID $copy_id runs."
run stop

# C14 (e) no Accessibility trust: ax exits 3.
doctor_case
: >"$state/ax.out"
echo "No Accessibility trust. Add the terminal app in System Settings > Privacy & Security > Accessibility." >"$state/ax.err"
echo 3 >"$state/ax.code"
expect_doctor_fail "doctor e" "(e)" "No Accessibility trust"
run stop

# C14 (f) the screen is locked, and the lock snippet finds no session.
doctor_case
echo locked >"$state/lock"
expect_doctor_fail "doctor f" "(f)" "manual"
: >"$state/lock"
echo 1 >"$state/lock.code"
expect_doctor_fail "doctor f no session" "(f)" "manual"
run stop

# C17: no stop by name, and each recursive delete acts on build/verify or the saved state of the copy.
grep -nE 'pkill|killall' "$here/verify-copy.sh" && fail "C17: a stop by name"
grep -q 'rm -rf' "$here/verify-copy.sh" 2>/dev/null || fail "C17: no rm -rf line"
while IFS= read -r line; do
    operand="${line#*rm -rf }"
    [[ "$operand" == '"$root/build/verify"' || "$operand" == '"$HOME/Library/Saved Application State/$copy_id.savedState"' ]] ||
        fail "C17: rm -rf of another path: $line"
done < <(grep -h 'rm -rf' "$here/verify-copy.sh" 2>/dev/null)

[[ $failures -eq 0 ]] && echo "verify-copy tests: all passed" || { echo "verify-copy tests: $failures failed"; exit 1; }
