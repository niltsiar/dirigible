#!/bin/bash
# Check verify-copy.sh in a temp repo. Fakes on PATH replace open, osascript, tccutil, defaults,
# and swift, so no case launches the app, shows a prompt, or changes TCC or the preferences. The
# fake open starts a compiled dummy at the copy path, so pgrep and kill are real. Each fake gives
# the exit code and the text of the real tool for the no-data case (decisions.tsv of run
# 2026-10-01-verify-copy, U14 and U15). Run by `make test-hooks`.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
# A short root: TMPDIR is long, and the socket path of a copy may hold 103 bytes only.
tmp="$(cd "$(mktemp -d /tmp/verify-copy.XXXXXX)" && pwd -P)"
# Run from the temp folder, not from a repo: a script that finds the root in the working folder
# then fails, and never acts on the real build/.
cd "$tmp" || exit 1
started=()
# Kill each process that the test or a fake open started and that still runs a file of the temp
# folder (a pid of an ended process can belong to another process), then remove the temp folders.
trap 'for p in "${started[@]}" $(cat "$tmp"/case-*/state/pids 2>/dev/null); do [[ "$(ps -o command= -p "$p" 2>/dev/null)" != *"$tmp"* ]] || kill -9 "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
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
# With open.fail, exit 1 and start nothing.
echo "$*" >>"$FAKE_STATE/open.log"
echo open >>"$FAKE_STATE/order.log"
[[ ! -f "$FAKE_STATE/open.fail" ]] || exit 1
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
# The global accent (-g AppleAccentColor) is the file accent: a read prints it, or exits 1 with the
# text of the real tool when it is absent, or exits with accent.read.code and the text of
# accent.read.err; a write sets it, or exits 1 with accent.write.fail; a delete removes it, or
# exits 1 with the text of the real tool when it is absent, or exits 1 with accent.delete.fail.
echo "$*" >>"$FAKE_STATE/defaults.log"
echo "defaults $*" >>"$FAKE_STATE/order.log"
if [[ "${2:-}" == -g ]]; then
    case "$1" in
        read)
            if [[ -f "$FAKE_STATE/accent.read.code" ]]; then
                cat "$FAKE_STATE/accent.read.err" >&2
                exit "$(cat "$FAKE_STATE/accent.read.code")"
            fi
            [[ ! -f "$FAKE_STATE/accent" ]] || { cat "$FAKE_STATE/accent" && exit 0; }
            printf '2026-10-28 01:28:58.378 defaults[53404:70880742] \nThe domain/default pair of (kCFPreferencesAnyApplication, %s) does not exist\n' "$3" >&2
            exit 1 ;;
        write)
            [[ ! -f "$FAKE_STATE/accent.write.fail" ]] || { echo "Could not write domain kCFPreferencesAnyApplication; exiting" >&2 && exit 1; }
            echo "$5" >"$FAKE_STATE/accent"
            exit 0 ;;
        delete)
            [[ ! -f "$FAKE_STATE/accent.delete.fail" ]] || { echo "Could not write domain kCFPreferencesAnyApplication; exiting" >&2 && exit 1; }
            [[ -f "$FAKE_STATE/accent" ]] ||
                { printf '2026-10-28 02:42:00.799 defaults[86858:75086082] \nDomain (kCFPreferencesAnyApplication) not found.\nDefaults have not been changed.\n' >&2 && exit 1; }
            rm -f "$FAKE_STATE/accent" && exit 0 ;;
    esac
fi
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
# With SOCK_LEN set, the folder of the repo gets a name that makes the socket path of the copy
# SOCK_LEN bytes long; with SOCK_MULTIBYTE also set, the name holds one two-byte character.
sock_tail=/build/verify/mcp.sock
n=0
new_case() {
    n=$((n + 1))
    local dir="$tmp/case-$n" name=repo pad
    if [[ -n "${SOCK_LEN:-}" ]]; then
        pad=$((SOCK_LEN - ${#sock_tail} - ${#dir} - 1))
        if [[ -n "${SOCK_MULTIBYTE:-}" ]]; then
            name="$(printf 'x%.0s' $(seq $((pad - 2))))é"
        else
            name="$(printf 'x%.0s' $(seq "$pad"))"
        fi
    fi
    repo="$dir/$name" state="$dir/state"
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
    # The --env words of the open line: the socket and the journal folder, then the no-device mode.
    sock="$repo/build/verify/mcp.sock" logs="$repo/build/verify/logs"
    envs="--env DIRIGIBLE_MCP_SOCKET=$sock --env DIRIGIBLE_LOG_FOLDER=$logs"
    noaudio="--env DIRIGIBLE_AUDIO_OUTPUT=none"
    export FAKE_STATE="$state" FAKE_COPY="$copy" HOME="$dir/home"
    export PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    script="$repo/scripts/verify-copy.sh"
    saved="$HOME/Library/Saved Application State"
    copy_id="$("$script" id 2>/dev/null)"
}

# run <args...>: run the script; set out, err, and code. out1 and out2 are the first two lines of
# out: start prints the PID, then the DIRIGIBLE_MCP_SOCKET line.
run() {
    out="$("$script" "$@" 2>"$tmp/err")"
    code=$?
    err="$(cat "$tmp/err")"
    out1="${out%%$'\n'*}"
    out2="$(sed -n 2p <<<"$out")"
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
pid="$out1"
[[ $code -eq 0 ]] || fail "start new: exit $code: $err"
is_copy "$pid" || fail "start new: '$pid' is not the PID of the copy"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$copy/Contents/Info.plist" 2>&1)" == "$copy_id" ]] ||
    fail "start new: the copy has another bundle ID"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$real/Contents/Info.plist" 2>&1)" == "$real_id" ]] ||
    fail "start new: the bundle ID of build/Dirigible.app changed"
codesign --verify "$copy" 2>/dev/null || fail "start new: codesign --verify of the copy failed"
[[ "$(cat "$state/open.log" 2>/dev/null)" == "-a $copy $envs $noaudio" ]] || fail "start new: open got: $(cat "$state/open.log" 2>/dev/null)"
[[ "$out2" == "DIRIGIBLE_MCP_SOCKET=$sock" && "$(grep -c . <<<"$out")" == 2 ]] || fail "start new: stdout is not the PID and the socket line: $out"
run stop
run start "$repo/Pilot.dirigible"
[[ $code -eq 0 ]] && is_copy "$out1" || fail "start new with a package: exit $code: $err"
[[ "$(tail -1 "$state/open.log" 2>/dev/null)" == "-a $copy $envs $noaudio $repo/Pilot.dirigible" ]] ||
    fail "start new with a package: open got: $(tail -1 "$state/open.log" 2>/dev/null)"
run stop

# C3d a package with a device route (<route device=) opens with no flag. A --live-input flag gets
# the usage text.
pkg="$repo/Live.dirigible"
mkdir -p "$pkg"
printf '<session><tracks><track name="Host"><route device="BuiltInMicrophoneDevice" channels="1"/></track></tracks></session>\n' >"$pkg/session.xml"
: >"$state/open.log"
run start "$pkg"
[[ $code -eq 0 ]] && is_copy "$out1" || fail "device route: exit $code: $err"
[[ "$(tail -1 "$state/open.log" 2>/dev/null)" == "-a $copy $envs $noaudio $pkg" ]] ||
    fail "device route: open got: $(tail -1 "$state/open.log" 2>/dev/null)"
run stop
: >"$state/open.log"
run start --live-input c3 "$pkg"
[[ $code -eq 2 && "$err" == *"usage: verify-copy.sh"* ]] || fail "--live-input: exit $code: $err"
[[ ! -s "$state/open.log" ]] || fail "--live-input: open got: $(cat "$state/open.log")"

# C3b start with arguments
new_case
run start -- --args -AppleLanguages "(es)"
pid="$out1"
[[ $code -eq 0 ]] || fail "start with arguments: exit $code: $err"
[[ "$(cat "$state/open.log" 2>/dev/null)" == "-a $copy $envs $noaudio --args -AppleLanguages (es)" ]] ||
    fail "start with arguments: open got: $(cat "$state/open.log" 2>/dev/null)"
[[ "$pid" =~ ^[0-9]+$ && "$(ps -o command= -p "$pid")" == "$exe -AppleLanguages (es)" ]] ||
    fail "start with arguments: '$pid' is not the copy with the arguments"
run stop
[[ $code -eq 0 ]] && gone "$pid" || fail "start with arguments: stop did not kill $pid: $err"

# C3e the socket path of the copy is at most 103 bytes (sun_path with its NUL): 103 starts, 104
# exits 1 before the screen lock and before open, also when a two-byte character makes the path
# 103 characters.
SOCK_LEN=103 new_case
run start
[[ $code -eq 0 && "$(head -1 "$state/open.log")" == *"--env DIRIGIBLE_MCP_SOCKET=$repo/build/verify/mcp.sock"* ]] ||
    fail "socket path of 103 bytes: exit $code: $err"
run stop
for variant in ascii multibyte; do
    if [[ $variant == multibyte ]]; then export SOCK_MULTIBYTE=1; fi
    SOCK_LEN=104 new_case
    unset SOCK_MULTIBYTE
    run start
    [[ $code -eq 1 && "$err" == *"$repo/build/verify/mcp.sock"* && "$err" == *"103 bytes"* ]] ||
        fail "socket path of 104 bytes ($variant): exit $code: $err"
    [[ ! -s "$state/open.log" && ! -e "$repo/.git/dirigible-screen" && ! -e "$repo/build/verify" ]] ||
        fail "socket path of 104 bytes ($variant): open, the screen lock, or build/verify was made"
done

# C3f start --agents turns the agents switch on: after --args, in the one --args list, and only
# when asked.
new_case
run start --agents
[[ $code -eq 0 && "$(cat "$state/open.log")" == "-a $copy $envs $noaudio --args -agents.edit.open.sessions YES" ]] ||
    fail "start --agents: exit $code: $err: $(cat "$state/open.log")"
run stop
: >"$state/open.log"
run start --agents "$repo/Pilot.dirigible" -- --args -AppleLanguages "(es)"
[[ $code -eq 0 && "$(cat "$state/open.log")" == "-a $copy $envs $noaudio $repo/Pilot.dirigible --args -AppleLanguages (es) -agents.edit.open.sessions YES" ]] ||
    fail "start --agents with a package and arguments: exit $code: $err: $(cat "$state/open.log")"
run stop
: >"$state/open.log"
run start "$repo/Pilot.dirigible"
[[ $code -eq 0 && "$(cat "$state/open.log")" != *agents.edit* ]] || fail "start with no --agents: open got: $(cat "$state/open.log")"
run stop

# C12 start plays to no device unless --audible; each start sets the journal folder. The two flags
# come before the package, in any order.
new_case
run start
[[ $code -eq 0 && "$(cat "$state/open.log")" == "-a $copy $envs $noaudio" ]] ||
    fail "C12 start plays to no device: exit $code: $err: $(cat "$state/open.log")"
[[ "$(cat "$state/open.log")" == *"--env DIRIGIBLE_LOG_FOLDER=$repo/build/verify/logs"* ]] ||
    fail "C12 start sets the journal folder: $(cat "$state/open.log")"
run stop
: >"$state/open.log"
run start --audible
[[ $code -eq 0 && "$(cat "$state/open.log")" == "-a $copy $envs" ]] ||
    fail "C12 start --audible: exit $code: $err: $(cat "$state/open.log")"
run stop
for flags in "--agents --audible" "--audible --agents"; do
    : >"$state/open.log"
    run start $flags
    [[ $code -eq 0 && "$(cat "$state/open.log")" == "-a $copy $envs --args -agents.edit.open.sessions YES" ]] ||
        fail "C12 start $flags: exit $code: $err: $(cat "$state/open.log")"
    run stop
done
: >"$state/open.log"
run start --audible "$repo/Pilot.dirigible" -- --args -AppleLanguages "(es)"
[[ $code -eq 0 && "$(cat "$state/open.log")" == "-a $copy $envs $repo/Pilot.dirigible --args -AppleLanguages (es)" ]] ||
    fail "C12 start --audible with a package and arguments: exit $code: $err: $(cat "$state/open.log")"
run stop
: >"$state/open.log"
run start --audible --live-input "$repo/Pilot.dirigible"
[[ $code -eq 2 && "$err" == *"usage: verify-copy.sh"* && ! -s "$state/open.log" ]] ||
    fail "C12 start --audible --live-input: exit $code: $err: $(cat "$state/open.log")"

# C3c start from another folder
new_case
out="$(cd / && "$script" start 2>"$tmp/err")"
code=$?
pid="$(head -1 <<<"$out")"
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
first="$out1"
run start
[[ $code -eq 0 ]] || fail "start running: exit $code: $err"
is_copy "$out1" && [[ "$out1" != "$first" ]] || fail "start running: no new copy: '$out1'"
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
pid="$out1"
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

# copy_state <id>: the state folders of a bundle ID in the fake HOME, each with one file.
copy_state() {
    mkdir -p "$HOME/Library/Application Support/$1" "$HOME/Library/Caches/$1/Peaks"
    echo x >"$HOME/Library/Application Support/$1/active-recordings.plist"
    echo x >"$HOME/Library/Caches/$1/Peaks/p.peaks"
}
# has_copy_state <id>: true when both folders of the ID exist.
has_copy_state() { [[ -d "$HOME/Library/Application Support/$1" && -d "$HOME/Library/Caches/$1" ]]; }
# no_copy_state <id>: true when neither folder of the ID exists.
no_copy_state() { [[ ! -e "$HOME/Library/Application Support/$1" && ! -e "$HOME/Library/Caches/$1" ]]; }

# C13 only stop deletes the state of the copy ID: its two folders and build/verify/logs. The two
# folders of the real ID stay. start keeps the folders and the logs.
new_case
run start
copy_state "$copy_id"
copy_state "$real_id"
mkdir -p "$logs"
echo x >"$logs/app.log"
run start
[[ $code -eq 0 ]] || fail "C13 second start: exit $code: $err"
has_copy_state "$copy_id" || fail "C13 start deleted a copy ID folder"
[[ -f "$logs/app.log" ]] || fail "C13 start deleted the logs"
run stop
[[ $code -eq 0 ]] || fail "C13 stop: exit $code: $err"
no_copy_state "$copy_id" || fail "C13 stop left a copy ID folder"
[[ ! -e "$logs" && ! -e "$repo/build/verify" ]] || fail "C13 stop left build/verify/logs"
has_copy_state "$real_id" || fail "C13 stop deleted a folder of the real ID"

# C14 after kill -9 of the copy, stop exits 0 and C13 holds.
new_case
run start
pid="$out1"
copy_state "$copy_id"
copy_state "$real_id"
mkdir -p "$logs"
echo x >"$logs/app.log"
kill -9 "$pid"
gone "$pid" || fail "C14 the copy $pid did not end"
run stop
[[ $code -eq 0 ]] || fail "C14 stop after kill -9: exit $code: $err"
no_copy_state "$copy_id" || fail "C14 stop left a copy ID folder"
[[ ! -e "$logs" ]] || fail "C14 stop left the logs"
has_copy_state "$real_id" || fail "C14 stop deleted a folder of the real ID"

# C14b after kill -9 of the copy, start keeps the recovery hint and the journal, and deletes the
# old socket.
new_case
run start
pid="$out1"
copy_state "$copy_id"
echo "/x/Pilot.dirigible" >"$HOME/Library/Application Support/$copy_id/active-recordings.plist"
mkdir -p "$logs"
echo x >"$logs/app.log"
kill -9 "$pid"
gone "$pid" || fail "C14b the copy $pid did not end"
touch "$sock"
run start
[[ $code -eq 0 ]] || fail "C14b start after kill -9: exit $code: $err"
grep -q 'Pilot.dirigible' "$HOME/Library/Application Support/$copy_id/active-recordings.plist" 2>/dev/null ||
    fail "C14b start deleted the recovery hint"
[[ -f "$logs/app.log" ]] || fail "C14b start deleted the journal"
[[ ! -e "$sock" ]] || fail "C14b start kept the old socket"
run stop

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
    pid="$out1"
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
    pid="$out1"
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

# C10 screen lock: one verify copy on the screen at a time. Two worktrees share the git common dir,
# so a start in the second tree waits for the copy of the first, prints the holder once at the
# start of the wait, and exits 1 with the holder after VERIFY_COPY_SCREEN_WAIT s.
new_case
wt="$tmp/case-$n/wt"
git -C "$repo" worktree add -q "$wt" 2>/dev/null
mkdir -p "$wt/build"
cp -R "$real" "$wt/build/Dirigible.app"
script2="$wt/scripts/verify-copy.sh"
run start
first_pid="$out1"
[[ $code -eq 0 ]] || fail "screen lock: the first start: exit $code: $err"
VERIFY_COPY_SCREEN_WAIT=2 "$script2" start >"$tmp/out2" 2>"$tmp/err2" &
second=$!
for _ in $(seq 30); do grep -q 'holds the screen' "$tmp/err2" && break; sleep 0.1; done
kill -0 "$second" 2>/dev/null && grep -q 'holds the screen' "$tmp/err2" ||
    fail "a second start waits for the screen lock: no holder line while it waits: $(cat "$tmp/err2")"
wait "$second"
code=$?
[[ $code -eq 1 && "$(grep -c "PID $first_pid" "$tmp/err2")" -ge 1 ]] ||
    fail "a second start waits for the screen lock and exits 1 with the holder: exit $code: $(cat "$tmp/err2")"
[[ "$(grep -c 'holds the screen' "$tmp/err2")" == 1 ]] || fail "screen lock: the holder line is not printed once: $(cat "$tmp/err2")"
# The timeout message tells the agent to wait and start again, never to stop the copy of another run.
grep -q 'start again' "$tmp/err2" && grep -q 'scripts/wiki.py runs shows that run done' "$tmp/err2" && ! grep -q 'stop it with' "$tmp/err2" ||
    fail "screen lock: the timeout message does not say to wait, start again, and stop only a done run: $(cat "$tmp/err2")"
[[ "$(wc -l <"$state/open.log" | tr -d ' ')" == 1 ]] || fail "screen lock: the second start opened a copy: $(cat "$state/open.log")"
# A stop in the second tree leaves the lock of the first tree.
"$script2" stop >/dev/null 2>&1
VERIFY_COPY_SCREEN_WAIT=1 "$script2" start >/dev/null 2>"$tmp/err2"
code=$?
[[ $code -eq 1 ]] || fail "screen lock: a stop in the second tree removed the lock of the first: exit $code"
# After the first stop, a start in the second tree goes on.
run stop
VERIFY_COPY_SCREEN_WAIT=1 "$script2" start >"$tmp/out2" 2>"$tmp/err2"
code=$?
[[ $code -eq 0 ]] || fail "screen lock: a start after the first stop: exit $code: $(cat "$tmp/err2")"
# A lock whose copy is dead is taken over.
kill -9 "$(head -1 "$tmp/out2")" 2>/dev/null
gone "$(head -1 "$tmp/out2")" || fail "screen lock: the copy of the second tree did not end"
VERIFY_COPY_SCREEN_WAIT=1 run start
[[ $code -eq 0 ]] || fail "screen lock: the lock of a dead copy was not taken over: exit $code: $err"
run stop

# accent_case: a new case; lock is the screen lock folder and saved_accent the file of the old
# global accent beside it. g_calls prints the defaults calls on the global domain.
accent_case() {
    new_case
    lock="$repo/.git/dirigible-screen" saved_accent="$repo/.git/dirigible-screen-accent-old"
}
g_calls() { grep -- '^[a-z]* -g ' "$state/defaults.log" 2>/dev/null; }

# Accent: start --accent -1 reads the old global accent (not set) and writes -1 before open; stop
# deletes the key that was not set, and removes the saved value.
accent_case
run start --accent -1
[[ $code -eq 0 ]] || fail "accent -1: exit $code: $err"
[[ "$(g_calls)" == $'read -g AppleAccentColor\nwrite -g AppleAccentColor -int -1' ]] || fail "accent -1: -g calls: $(g_calls)"
[[ "$(grep -v '^defaults [a-z]* [^-]' "$state/order.log" | tr '\n' '|')" == "defaults read -g AppleAccentColor|defaults write -g AppleAccentColor -int -1|open|" ]] ||
    fail "accent -1: the write is not before open: $(cat "$state/order.log")"
[[ "$(cat "$saved_accent" 2>/dev/null)" == unset ]] || fail "accent -1: the saved value is not unset: $(cat "$saved_accent" 2>&1)"
run stop
[[ $code -eq 0 && "$(g_calls | tail -1)" == "delete -g AppleAccentColor" && ! -e "$saved_accent" ]] ||
    fail "accent -1: stop: exit $code: $err: $(g_calls)"

# The saved value is unset and the key is already gone: stop removes the file, the delete error
# does not fail it, and a later start and stop also exit 0.
accent_case
run start --accent -1
rm -f "$state/accent"
run stop
[[ $code -eq 0 && ! -e "$saved_accent" && ! -e "$lock" ]] || fail "accent unset, key gone: stop: exit $code: $err: $(g_calls)"
run start --accent 2
[[ $code -eq 0 ]] || fail "accent unset, key gone: a later start: exit $code: $err"
run stop
[[ $code -eq 0 ]] || fail "accent unset, key gone: a later stop: exit $code: $err"
# The first write fails with no old value: start exits 1, the file goes, and the next start works.
accent_case
touch "$state/accent.write.fail"
run start --accent -1
[[ $code -eq 1 && ! -e "$saved_accent" && ! -e "$state/accent" ]] || fail "accent unset, failed write: exit $code: $err: $(g_calls)"
rm -f "$state/accent.write.fail"
run start --accent 2
[[ $code -eq 0 && "$(cat "$saved_accent" 2>/dev/null)" == unset ]] || fail "accent unset, failed write: the next start: exit $code: $err"
run stop
# A delete that fails while the key is still set keeps the file and exits 1.
accent_case
run start --accent -1
touch "$state/accent.delete.fail"
run stop
[[ $code -eq 1 && "$err" == *"$saved_accent"* && "$(cat "$saved_accent" 2>/dev/null)" == unset ]] ||
    fail "accent unset, failed delete: exit $code: $err"

# Accent 6 with an old value 3: the file holds 3, and stop writes 3 back and removes the file.
accent_case
echo 3 >"$state/accent"
run start --accent 6
[[ $code -eq 0 && "$(cat "$saved_accent" 2>/dev/null)" == 3 && "$(cat "$state/accent")" == 6 ]] ||
    fail "accent 6: exit $code: $err: saved $(cat "$saved_accent" 2>&1)"
run stop
[[ $code -eq 0 && "$(g_calls | tail -1)" == "write -g AppleAccentColor -int 3" && ! -e "$saved_accent" && "$(cat "$state/accent")" == 3 ]] ||
    fail "accent 6: stop: exit $code: $err: $(g_calls)"

# A value out of -1 to 6, or no value, gets the usage before the screen lock: no defaults or open call.
for value in 7 -2 x ""; do
    accent_case
    if [[ -n "$value" ]]; then run start --accent "$value"; else run start --accent; fi
    [[ $code -eq 2 && "$err" == *"usage: verify-copy.sh start [--agents] [--accent <n>]"* ]] || fail "accent '$value': exit $code: $err"
    [[ ! -s "$state/defaults.log" && ! -s "$state/open.log" && ! -e "$lock" ]] ||
        fail "accent '$value': a defaults call, an open call, or the screen lock"
done

# A second start of the tree puts the first value back before its own write, with and without
# --accent; the file keeps the true original.
accent_case
echo 3 >"$state/accent"
run start --accent 2
run start --accent 5
[[ $code -eq 0 && "$(g_calls | tail -3 | tr '\n' '|')" == "write -g AppleAccentColor -int 3|read -g AppleAccentColor|write -g AppleAccentColor -int 5|" ]] ||
    fail "accent second start: exit $code: $err: $(g_calls)"
[[ "$(cat "$saved_accent" 2>/dev/null)" == 3 ]] || fail "accent second start: the file does not hold 3: $(cat "$saved_accent" 2>&1)"
run start
[[ $code -eq 0 && "$(g_calls | tail -1)" == "write -g AppleAccentColor -int 3" && ! -e "$saved_accent" ]] ||
    fail "accent second start with no --accent: exit $code: $err: $(g_calls)"
run stop
[[ "$(g_calls | wc -l | tr -d ' ')" == 6 ]] || fail "accent second start: stop made a -g call with no saved value: $(g_calls)"

# A stop of a tree that does not hold the lock makes no -g call and keeps the file.
accent_case
other="$(dummy "$tmp/case-$n/other/Dirigible")"
started+=("$other")
mkdir -p "$lock" && echo /other/root >"$lock/root" && echo "$other" >"$lock/pid"
echo 3 >"$saved_accent"
run stop
[[ $code -eq 0 && -z "$(g_calls)" && "$(cat "$saved_accent")" == 3 ]] || fail "accent stop of another tree: exit $code: $err: $(g_calls)"
# A second tree: start waits for the live holder, exits 1, and makes no -g call.
VERIFY_COPY_SCREEN_WAIT=1 run start --accent 2
[[ $code -eq 1 && -z "$(g_calls)" && "$(cat "$saved_accent")" == 3 && ! -s "$state/open.log" ]] ||
    fail "accent second tree: exit $code: $err: $(g_calls)"

# A failed cleanup at stop still puts the accent back and removes the lock.
accent_case
echo 3 >"$state/accent"
run start --accent 2
echo "tccutil: Failed to reset All approval status for $copy_id" >"$state/tccutil.fail"
echo 1 >"$state/tccutil.code"
run stop
[[ $code -eq 1 && "$(g_calls | tail -1)" == "write -g AppleAccentColor -int 3" && ! -e "$lock" && ! -e "$saved_accent" ]] ||
    fail "accent stop with a failed tccutil: exit $code: $err: $(g_calls)"

# A read that fails another way stops start with no write and no open.
for read_fail in "1:Could not read domain" "2:defaults: bad arguments"; do
    accent_case
    echo "${read_fail%%:*}" >"$state/accent.read.code"
    echo "${read_fail#*:}" >"$state/accent.read.err"
    run start --accent 2
    [[ $code -eq 1 && "$err" == *"defaults read -g AppleAccentColor failed"* && "$err" == *"${read_fail#*:}"* ]] ||
        fail "accent read error ($read_fail): exit $code: $err"
    [[ "$(g_calls)" == "read -g AppleAccentColor" && ! -s "$state/open.log" && ! -e "$saved_accent" ]] ||
        fail "accent read error ($read_fail): a write, an open, or a saved value: $(g_calls)"
done

# A start that fails after the write (open fails) puts the old value back.
accent_case
echo 3 >"$state/accent"
touch "$state/open.fail"
run start --accent 2
[[ $code -ne 0 && "$(g_calls | tail -2 | tr '\n' '|')" == "write -g AppleAccentColor -int 2|write -g AppleAccentColor -int 3|" ]] ||
    fail "accent failed open: exit $code: $err: $(g_calls)"
[[ "$(cat "$state/accent")" == 3 && ! -e "$saved_accent" ]] || fail "accent failed open: the accent is not 3, or the file stayed"

# A takeover after a dead copy puts the saved value back before its own write.
accent_case
sh -c 'exit 0' &
dead=$!
wait "$dead"
mkdir -p "$lock" && echo /other/root >"$lock/root" && echo "$dead" >"$lock/pid"
echo 3 >"$saved_accent"
echo 5 >"$state/accent"
run start --accent 2
[[ $code -eq 0 && "$(g_calls | tr '\n' '|')" == "write -g AppleAccentColor -int 3|read -g AppleAccentColor|write -g AppleAccentColor -int 2|" ]] ||
    fail "accent takeover: exit $code: $err: $(g_calls)"
[[ "$(cat "$saved_accent" 2>/dev/null)" == 3 ]] || fail "accent takeover: the file does not hold 3"
run stop

# A failed restore keeps the file and exits 1 with no open, at start (also when the read gives
# another value) and at stop; at stop the lock folder is gone.
accent_case
echo 3 >"$state/accent"
run start --accent 2
touch "$state/accent.write.fail"
: >"$state/open.log"
run start --accent 4
[[ $code -eq 1 && "$err" == *"$saved_accent"* && "$(cat "$saved_accent" 2>/dev/null)" == 3 && ! -s "$state/open.log" ]] ||
    fail "accent failed restore at start: exit $code: $err"
run stop
[[ $code -eq 1 && "$(cat "$saved_accent" 2>/dev/null)" == 3 && ! -e "$lock" ]] || fail "accent failed restore at stop: exit $code: $err"

# --agents and --accent in each order.
for order in "--agents --accent 2" "--accent 2 --agents"; do
    accent_case
    run start $order
    [[ $code -eq 0 && "$(cat "$state/open.log")" == *"--args -agents.edit.open.sessions YES" && "$(g_calls | tail -1)" == "write -g AppleAccentColor -int 2" ]] ||
        fail "accent with --agents ($order): exit $code: $err: $(cat "$state/open.log")"
    run stop
done

# C17: no stop by name, and each delete acts on build/verify, the copy bundle, the state folders of
# the copy ID, the socket, or the files of the screen lock and of the saved accent.
grep -nE 'pkill|killall' "$here/verify-copy.sh" && fail "C17: a stop by name"
grep -q 'rm -rf' "$here/verify-copy.sh" 2>/dev/null || fail "C17: no rm -rf line"
while IFS= read -r line; do
    operands="$(sed -E 's/.*rm -r?f //' <<<"$line")"
    case "$operands" in
        '"$root/build/verify"' | '"$HOME/Library/Saved Application State/$copy_id.savedState"' | '"$copy"') ;;
        '"$HOME/Library/Application Support/$copy_id"' | '"$HOME/Library/Caches/$copy_id"') ;;
        '"$socket" "$root/build/verify/source-mtime"' | '"$saved_accent"' | '"$screen/root" "$screen/pid"') ;;
        '"$errf"'\'' EXIT') ;;
        *) fail "C17: a delete of another path: $line" ;;
    esac
done < <(grep -hE 'rm -r?f ' "$here/verify-copy.sh" 2>/dev/null)

[[ $failures -eq 0 ]] && echo "verify-copy tests: all passed" || { echo "verify-copy tests: $failures failed"; exit 1; }
