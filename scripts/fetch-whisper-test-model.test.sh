#!/bin/bash
# Check fetch-whisper-test-model.sh with file:// URLs: a file with the wrong SHA-256 exits 1 and
# leaves no file, and a file that matches stays and is not fetched again.
# Run by `make test-hooks`.
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd -P)/fetch-whisper-test-model.sh"
failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/source" "$work/cache"
printf 'not a model' >"$work/source/ggml-base.bin"

out="$(XDG_CACHE_HOME="$work/cache" WHISPER_MODEL_BASE_URL="file://$work/source" WHISPER_VAD_BASE_URL="file://$work/source" \
    "$script" 2>&1)"
code=$?
[[ $code -eq 1 ]] || fail "wrong hash: exit $code, not 1"
[[ "$out" == *"ggml-base.bin has the wrong SHA-256; removed"* ]] || fail "wrong hash: no message: $out"
[[ -z "$(ls -A "$work/cache/dirigible/whisper")" ]] || fail "wrong hash: files left: $(ls "$work/cache/dirigible/whisper")"

# A file that is there with the right hash is kept; the next file has no source and exits 1.
mkdir -p "$work/cache/dirigible/whisper"
printf 'x' >"$work/source/x"
real="$(shasum -a 256 "$work/source/x" | cut -d ' ' -f 1)"
sed "s/60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe/$real/" "$script" >"$work/fetch.sh"
cp "$work/source/x" "$work/cache/dirigible/whisper/ggml-base.bin"
rm "$work/source/ggml-base.bin"
out="$(XDG_CACHE_HOME="$work/cache" WHISPER_MODEL_BASE_URL="file://$work/source" WHISPER_VAD_BASE_URL="file://$work/source" \
    bash "$work/fetch.sh" 2>&1)"
code=$?
[[ $code -eq 1 ]] || fail "missing tiny: exit $code, not 1"
[[ "$out" == *"ggml-base.bin is there"* ]] || fail "matching file: no message: $out"
[[ -f "$work/cache/dirigible/whisper/ggml-base.bin" ]] || fail "matching file: removed"

if ((failures > 0)); then
    echo "fetch-whisper-test-model.test.sh: $failures failures"
    exit 1
fi
echo "fetch-whisper-test-model.test.sh: pass"
