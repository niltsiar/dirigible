#!/bin/bash
# Fetch the whisper.cpp model files of the engine tests and benches (decision 0065, C18) into
# ${XDG_CACHE_HOME:-~/.cache}/dirigible/whisper/, under the file names of the catalog of
# WhisperModel.swift: base (the default), tiny-q5_1 (the push guard of the abort patch), and the
# Silero VAD model. Each file must match its SHA-256. A file with another hash is removed, and the
# script exits 1. A file that matches is not fetched again. A test points the tests at the folder
# with DIRIGIBLE_MODELS_FOLDER.
# Usage: scripts/fetch-whisper-test-model.sh
# WHISPER_MODEL_BASE_URL and WHISPER_VAD_BASE_URL replace the pinned URLs (the .test.sh uses file://).
set -euo pipefail
folder="${XDG_CACHE_HOME:-$HOME/.cache}/dirigible/whisper"
models="${WHISPER_MODEL_BASE_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1}"
vad="${WHISPER_VAD_BASE_URL:-https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b}"
mkdir -p "$folder"

hash_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

# fetch <base URL> <file name> <SHA-256>
fetch() {
    local file="$folder/$2"
    if [[ -f "$file" && "$(hash_of "$file")" == "$3" ]]; then
        echo "fetch-whisper-test-model: $2 is there"
        return 0
    fi
    rm -f "$file"
    if ! curl -fsSL -o "$file.download" "$1/$2"; then
        rm -f "$file.download"
        echo "fetch-whisper-test-model: no file at $1/$2" >&2
        return 1
    fi
    if [[ "$(hash_of "$file.download")" != "$3" ]]; then
        rm -f "$file.download"
        echo "fetch-whisper-test-model: $2 has the wrong SHA-256; removed" >&2
        return 1
    fi
    mv "$file.download" "$file"
    echo "fetch-whisper-test-model: $2 fetched"
}

fetch "$models" ggml-base.bin 60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe
fetch "$models" ggml-tiny-q5_1.bin 818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7
fetch "$vad" ggml-silero-v6.2.0.bin 2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987
