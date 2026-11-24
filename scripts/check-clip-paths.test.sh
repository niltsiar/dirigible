#!/bin/bash
# Check that check-clip-paths.sh fails each Swift line under Sources/ that builds a clip path by hand,
# and each open sink in Sources/DirigibleAudio/Import, Render, or Transcribe, that has no allow
# entry; that an allow entry with a reason passes its line; and that an allow entry with no reason,
# or with no line, fails. Each case runs in a new tree in a temporary folder. Run by `make test-hooks`.
set -uo pipefail
check="$(cd "$(dirname "$0")" && pwd)/check-clip-paths.sh"
failures=0
cases=0
tmp="$(mktemp -d)"
trap 'chmod -R u+rw "$tmp"; rm -rf "$tmp"' EXIT

tree() {
  chmod -R u+rw "$tmp"
  rm -rf "${tmp:?}"/*
  mkdir -p "$tmp/scripts" "$tmp/Sources/DirigibleCore" "$tmp/Sources/DirigibleAudio/Import" \
    "$tmp/Sources/DirigibleAudio/Render" "$tmp/Sources/DirigibleAudio/Transcribe" "$tmp/Sources/DirigibleAudio/Finalize"
  : > "$tmp/scripts/check-clip-paths.allow"
}
# plant <path> <line>: write the line as the third line of a Swift file, after two lines with no match.
plant() { printf 'import Foundation\n\n%s\n' "$2" >> "$tmp/$1"; }
allow() { printf '%b' "$1" > "$tmp/scripts/check-clip-paths.allow"; }

# expect pass <name>, or expect fail|error <name> <message>. A fail is exit 1, an error is exit 2;
# each counts only with its message. A pass prints nothing.
expect() {
  local want="$1" name="$2" message="${3:-}" got output code
  cases=$((cases + 1))
  output="$("$check" "$tmp" 2>&1)"
  code=$?
  case $code in 0) got=pass ;; 1) got=fail ;; 2) got=error ;; *) got="exit $code" ;; esac
  if [[ "$got" == "$want" && "$want" != pass ]] && ! grep -qF -- "check-clip-paths: $message" <<<"$output"; then
    got="$got without '$message' in [$output]"
  elif [[ "$got" == pass && -n "$output" ]]; then
    got="pass with output [$output]"
  fi
  [[ "$got" == "$want" ]] || { echo "FAIL: expected $want, got $got: $name"; failures=$((failures + 1)); }
}

path_line='        let url = package.appending(path: "\(clipsFolderName)/\(file.path)")'
path_text='let url = package.appending(path: "\(clipsFolderName)/\(file.path)")'

tree; plant Sources/DirigibleCore/A.swift 'let x = 1'; expect pass 'a tree with no clip path and no sink'
tree; plant Sources/DirigibleCore/A.swift "$path_line"
expect fail 'a clip path built by hand' "Sources/DirigibleCore/A.swift:3: a clip path built by hand: $path_text"
tree; plant Sources/DirigibleAudio/Finalize/A.swift '    let url = clips.appending(path: name)'
expect fail 'a clips.appending(path: call' 'Sources/DirigibleAudio/Finalize/A.swift:3: a clip path built by hand: let url = clips.appending(path: name)'
tree; plant Sources/DirigibleCore/Session+Archive.swift "$path_line"; expect pass 'a clip path in the resolver file'
tree; plant Sources/DirigibleCore/A.txt "$path_line"; expect pass 'a clip path in a file that is not Swift'
tree; plant Sources/DirigibleCore/A.swift "    // $path_text"; expect pass 'a clip path in a comment'
tree; plant Sources/DirigibleCore/A.swift "$path_line"
allow "# a comment\n\nSources/DirigibleCore/A.swift\t$path_text\ta writer of a new clip\n"
expect pass 'a clip path with an allow entry and a reason'
tree; plant Sources/DirigibleCore/A.swift "$path_line"; plant Sources/DirigibleCore/A.swift "  $path_text"
allow "Sources/DirigibleCore/A.swift\t$path_text\ta writer of a new clip\n"
expect pass 'one allow entry for two lines with the same text in one file'
tree; plant Sources/DirigibleCore/A.swift "$path_line"; plant Sources/DirigibleCore/B.swift "$path_line"
allow "Sources/DirigibleCore/A.swift\t$path_text\ta writer of a new clip\n"
expect fail 'an allow entry for the same text in another file' "Sources/DirigibleCore/B.swift:3: a clip path built by hand"
tree; plant Sources/DirigibleCore/A.swift "$path_line"
allow "Sources/DirigibleCore/A.swift\t$path_text\t \n"
expect fail 'an allow entry with no reason' "scripts/check-clip-paths.allow:1: an allow entry with no reason"
tree; plant Sources/DirigibleCore/A.swift "$path_line"
allow "Sources/DirigibleCore/A.swift\t$path_text\n"
expect fail 'an allow entry with no reason field' "scripts/check-clip-paths.allow:1: an allow entry with no reason"
tree; plant Sources/DirigibleCore/A.swift 'let x = 1'
allow "Sources/DirigibleCore/A.swift\t$path_text\ta writer of a new clip\n"
expect fail 'an allow entry that matches no line' "scripts/check-clip-paths.allow:1: an allow entry that matches no line: Sources/DirigibleCore/A.swift"
tree; plant Sources/DirigibleCore/A.swift "$path_line"
allow "Sources/DirigibleCore/A.swift\tlet url = package.appending(path:  \"\\(clipsFolderName)/\\(file.path)\")\ta writer of a new clip\n"
expect fail 'an allow entry with other text inside the line' "Sources/DirigibleCore/A.swift:3: a clip path built by hand"

# The open sinks: each spelling in each guarded folder fails with no allow entry.
for folder in Import Render Transcribe; do
  for sink in '    let audio = try AVAudioFile(forReading: url)' '    let fd = openat(folder, name, O_RDONLY)' \
    '    let fd = open(url.path, O_RDONLY | O_CLOEXEC)' '    let opened = try openAudio(url)' \
    '    guard let reopened = try? openChecked(path, in: packageFD) else { throw .sourceChanged(path) }'; do
    tree; plant "Sources/DirigibleAudio/$folder/A.swift" "$sink"
    expect fail "an open sink in $folder: ${sink#    }" "Sources/DirigibleAudio/$folder/A.swift:3: an open sink with no allow entry: ${sink#    }"
  done
done
tree; plant Sources/DirigibleAudio/Import/TemplateCopy.swift '        do { return try openChecked(path, in: packageFD) } catch {'
expect fail 'the TemplateCopy shape' 'Sources/DirigibleAudio/Import/TemplateCopy.swift:3: an open sink with no allow entry: do { return try openChecked(path, in: packageFD) } catch {'
tree; plant Sources/DirigibleAudio/Import/A.swift '    let fd = open(url.path, O_RDONLY)'
allow 'Sources/DirigibleAudio/Import/A.swift\tlet fd = open(url.path, O_RDONLY)\tan import source that the user picked\n'
expect pass 'an open sink with an allow entry and a reason'
tree; plant Sources/DirigibleAudio/Import/A.swift '    let file = try openChecked("\(clipsFolderName)/\(path)", in: folder)'
allow 'Sources/DirigibleAudio/Import/A.swift\tlet file = try openChecked("\(clipsFolderName)/\(path)", in: folder)\tresolver name: path\n'
expect pass 'one allow entry for a line that is a clip path and a sink'
tree; plant Sources/DirigibleAudio/Finalize/A.swift '    let audio = try AVAudioFile(forReading: url)'
plant Sources/DirigibleCore/A.swift '    let fd = open(url.path, O_RDONLY)'
expect pass 'an open sink outside the guarded folders'
tree
for line in '    let fd = handle.open(url)' '    let fd = reopen(url)' '    let fd = my_open(url)' \
  '    /// Opens the file with `AVAudioFile(forReading:)` and `open(2)`.' '    // let fd = open(url.path, O_RDONLY)' \
  '    let audio = try AVAudioFile(forWriting: url, settings: settings)'; do
  plant Sources/DirigibleAudio/Render/A.swift "$line"
done
expect pass 'a method call, a longer name, a comment, and a write open are no sink'
tree; plant Sources/DirigibleAudio/Render/A.swift '    let fd = open(url.path, O_RDONLY)'
plant Sources/DirigibleAudio/Render/A.swift "$path_line"
expect fail 'two problems in one file, each with its line' 'Sources/DirigibleAudio/Render/A.swift:6: a clip path built by hand'
tree; plant Sources/DirigibleCore/A.swift "$path_line"; chmod 000 "$tmp/scripts/check-clip-paths.allow"
expect error 'an allow file that cannot be read' 'scripts/check-clip-paths.allow cannot be read'

echo "check-clip-paths.test: $cases cases, $failures failed"
[[ $failures -eq 0 ]]
