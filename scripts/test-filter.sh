#!/bin/bash
# Run only the tests of a slice: process 1 skips the app bundle, disk image, and CLI tests, with
# one --filter for each name. Process 2 runs the CLI tests of a name that a file under
# Tests/DirigibleCLITests/ has, in its own process, as the CLI shard of make test.
# Process 2 runs also when process 1 fails, as in make test. It fails closed: it exits with the
# first nonzero swift status, and with 1 when no process ran a test. swift test exits 0 when a
# filter matches no test, so the script reads the two no-test strings of mutate.py; one string
# alone means that tests ran. Each process runs through scripts/swift-test.sh, so a process
# that ends with exit 0 and no report line fails.
# A name can match no test while the other names run tests. When a name shows in no started line
# of the test output ("◇ Test <name>(" with --exact; else "◇ Test" or "◇ Suite" with the name in
# the text), the script makes one `swift test list --skip-build` call. It exits 1 with
# "test-filter: no test ID matches <names>" for each name that no listed ID matches: process 1
# takes the IDs that it does not skip, and process 2 the CLI IDs of a name that a CLI file has.
# A list exit 75 gives exit 75. Any other list failure gives exit 1 and "test list failed".
# A refused name that is the file name of a Swift file under Tests/ with no type of that name, and
# whose extension blocks extend a suite, also gets a line "test-filter: <path> declares no suite
# <name>; it extends <suite>: give FILTER the suite name <suite>" for each such suite (with --exact:
# "run the suite name <suite> without --exact"). A suite is a
# type with a @Test in a top-level block under Tests/ (its declaration or an extension). The hint
# reads the source files and runs no swift call.
# With --exact, each name is the whole name of a Swift Testing test: the filter is '/<name>\(' with
# the regex characters escaped, so a name that is a prefix of another test name runs only its own
# test. The CLI process then takes a name that a CLI test file has as 'func <name>('. With
# --no-parallel, both swift calls get --no-parallel (a rerun of slow tests, scripts/run-checks.sh).
# With --skip-build, both swift calls get --skip-build --disable-xctest (a mutant that its build
# command built already), and the Swift Testing no-test string alone means that no test ran.
# Usage: scripts/test-filter.sh [--exact] [--no-parallel] [--skip-build] <name>...
#        make test-filter FILTER='<name> <name>'
# scripts/test-filter.test.sh tests it.
set -euo pipefail
exact=0 serial=0 built=0
while [[ "${1:-}" =~ ^--(exact|no-parallel|skip-build)$ ]]; do
    case "$1" in --exact) exact=1 ;; --no-parallel) serial=1 ;; *) built=1 ;; esac
    shift
done
[[ $# -gt 0 ]] || { echo "usage: scripts/test-filter.sh [--exact] [--no-parallel] [--skip-build] <test or suite name>..." >&2; exit 2; }
cd "$(dirname "$0")/.."
out="$(mktemp)" started="$(mktemp)"
trap 'rm -f "$out" "$started"' EXIT

# decl_awk: the awk function decl(line) returns the type name of a top-level struct, class, enum,
# actor, or extension line at column 0 (attributes and modifiers can come first) and sets kind.
decl_awk='function decl(l,   n, w) {
    kind = ""
    if (!match(l, "^((@[A-Za-z_][A-Za-z0-9_]*(\\([^)]*\\))?|public|internal|private|fileprivate|final|open)[ \t]+)*(struct|class|enum|actor|extension)[ \t]+[A-Za-z_][A-Za-z0-9_.]*")) return ""
    n = split(substr(l, RSTART, RLENGTH), w, /[ \t]+/)
    kind = w[n - 1]
    return w[n]
}'
# A block runs from its declaration line to the next declaration line or a line that starts with }.
suite_awk='FNR == 1 { cur = "" }
{
    d = decl($0)
    if (d != "") cur = d
    if (cur != "" && $0 !~ /^[ \t]*\/\// && $0 ~ /@Test([^A-Za-z0-9_]|$)/) suite[cur] = 1
    if (d != "" && $0 ~ /\{.*\}[ \t]*$/) cur = ""
    else if ($0 ~ /^\}/) cur = ""
}
END { for (s in suite) print s }'
file_awk='{ d = decl($0); if (d != "") print (kind == "extension" ? "E " : "D ") d }'
suites=""
# hint_suite <name>: prints the hint lines of a refused name to stderr.
hint_suite() {
    local name="$1" file kinds s shown=""
    while IFS= read -r file; do
        kinds="$(awk "$decl_awk $file_awk" "$file")"
        ! grep -qxF -- "D $name" <<<"$kinds" || continue
        [[ -n $suites ]] || suites="$(find Tests -type f -name '*.swift' -exec awk "$decl_awk $suite_awk" {} + | sort -u)"
        while IFS= read -r s; do
            ! grep -qxF -- "$s" <<<"$shown" || continue
            grep -qxF -- "$s" <<<"$suites" || continue
            shown+="$s"$'\n'
            if [[ $exact -eq 1 ]]; then
                echo "test-filter: $file declares no suite $name; it extends $s: run the suite name $s without --exact" >&2
            else
                echo "test-filter: $file declares no suite $name; it extends $s: give FILTER the suite name $s" >&2
            fi
        done < <(sed -n 's/^E //p' <<<"$kinds")
    done < <(find Tests -type f -name "$name.swift" 2>/dev/null | sort)
}

ran=0 status=0
# run <swift test arguments>: keeps the first nonzero swift status; sets ran when tests ran, and
# adds the started lines of the test output to $started.
run() {
    local code=0
    scripts/swift-test.sh "$@" 2>&1 | tee "$out" || code=$?
    grep -E '^◇ (Test|Suite) .* started\.$' "$out" | grep -vxF '◇ Test run started.' >> "$started" || true
    [[ $status -ne 0 ]] || status=$code
    { [[ $built -eq 1 ]] || grep -qF 'No matching test cases were run' "$out"; } && grep -qF 'Test run with 0 tests' "$out" || ran=1
}

p1=(--skip AppBundleTests --skip DiskImageTests --skip DirigibleCLITests) p2=()
names=("$@") rx=() inCLI=()
for name in "$@"; do
    cli=0
    if [[ $exact -eq 1 ]]; then
        anchored="/$(sed 's/[][\.*^$+?(){}|/]/\\&/g' <<<"$name")\\("
        p1+=(--filter "$anchored")
        grep -rqF -- "func $name(" Tests/DirigibleCLITests 2>/dev/null && { p2+=(--filter "DirigibleCLITests.*$anchored"); cli=1; }
        rx+=("$anchored")
    else
        p1+=(--filter "$name")
        grep -rqF -- "$name" Tests/DirigibleCLITests 2>/dev/null && { p2+=(--filter "DirigibleCLITests.*$name"); cli=1; }
        rx+=("$name")
    fi
    inCLI+=("$cli")
done
[[ $serial -eq 0 ]] || { p1+=(--no-parallel); [[ ${#p2[@]} -eq 0 ]] || p2+=(--no-parallel); }
[[ $built -eq 0 ]] || { p1+=(--skip-build --disable-xctest); [[ ${#p2[@]} -eq 0 ]] || p2+=(--skip-build --disable-xctest); }
run "${p1[@]}"
[[ ${#p2[@]} -eq 0 ]] || run "${p2[@]}"
[[ $status -eq 0 ]] || exit $status
[[ $ran -eq 1 ]] || {
    echo "test-filter: no test matched $*" >&2
    for name in "${names[@]}"; do hint_suite "$name"; done
    exit 1
}

# A name that shows in no started line gets the list check. The text of the started lines is kept
# in a variable and read with a here-string: grep -q on a pipe can end the writer early.
shown="$(sed -E 's/^◇ (Test|Suite) (.*) started\.$/\2/' "$started")"
unseen=()
for i in "${!names[@]}"; do
    if [[ $exact -eq 1 ]]; then
        grep -Eq -- "^◇ Test ${rx[$i]#/}" "$started" || unseen+=("$i")
    else
        grep -qF -- "${names[$i]}" <<<"$shown" || unseen+=("$i")
    fi
done
[[ ${#unseen[@]} -gt 0 ]] || exit 0
list_args=(test list --skip-build)
[[ $built -eq 0 ]] || list_args+=(--disable-xctest)
list_code=0
listing="$(scripts/with-lock.sh swift "${list_args[@]}")" || list_code=$?
[[ $list_code -ne 75 ]] || exit 75
[[ $list_code -eq 0 ]] || { echo "test-filter: test list failed (exit $list_code)" >&2; exit 1; }
ids="$(grep -E '^[A-Za-z_][A-Za-z0-9_]*\.[^[:space:]]+$' <<<"$listing" || true)"
p1_ids="$(grep -vE 'AppBundleTests|DiskImageTests|DirigibleCLITests' <<<"$ids" || true)"
cli_ids="$(grep -E 'DirigibleCLITests' <<<"$ids" || true)"
missing=()
for i in "${unseen[@]}"; do
    grep -Eq -- "${rx[$i]}" <<<"$p1_ids" && continue
    [[ ${inCLI[$i]} -eq 1 ]] && grep -Eq -- "DirigibleCLITests.*${rx[$i]}" <<<"$cli_ids" && continue
    missing+=("${names[$i]}")
done
[[ ${#missing[@]} -eq 0 ]] || {
    echo "test-filter: no test ID matches ${missing[*]}" >&2
    for name in "${missing[@]}"; do hint_suite "$name"; done
    exit 1
}
