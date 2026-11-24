# How Dirigible was made

1. We wrote the code of Dirigible for this project. The exceptions are the third-party parts in the table of this file, each with its license and notice.
2. We did not decompile, disassemble, or copy the code of a closed app.
3. We learned how closed apps behave (for example Hindenburg PRO, Logic Pro, GarageBand, Final Cut Pro, Adobe Audition, Descript, Reaper, and Pro Tools) from their public documentation, from use and measurement of the apps, and from text in installed apps, such as menu and command names. That text comes from Final Cut Pro, Logic Pro, GarageBand, and the macOS system apps. We also read one option name in the text of one closed command-line tool. Each research note in docs/research names its sources.
4. We read Audacity code (GPL-3.0) to learn an approach. We did not copy, port, or translate it. Some features have the behavior or a default value of Audacity, for example the file names of an export for each chapter.
5. We read soundcraft code (MIT or Apache-2.0) to learn an approach and default values. No soundcraft code is in the repo. A port of soundcraft code keeps its license notice.
6. LAME 4.0 (LGPL-2.0-or-later) is in Sources/CLame, with no decoder. The app carries the LGPL text and a notice with the build commit. Sources/CLame/README.dirigible lists each changed file.
7. The repo holds no asset, screenshot, string table, or manual of a closed app.

## Third-party parts

| Part | Folder or file | License | Notice file | Notice file in the app |
|---|---|---|---|---|
| LAME 4.0, the MP3 encoder | `Sources/CLame` | LGPL-2.0-or-later | `Support/Resources/LAME-COPYING.txt` and `Support/Resources/LAME-NOTICE.txt` | `Contents/Resources/LAME-COPYING.txt` and `Contents/Resources/LAME-NOTICE.txt` |
| whisper.cpp v1.9.5 and ggml, the transcription engine | `Sources/CWhisper` | MIT | `Support/Resources/whisper.cpp-LICENSE.txt` | `Contents/Resources/whisper.cpp-LICENSE.txt` |
| The YaRN code in ggml | `Sources/CWhisper/ggml/src/ggml-cpu/ops.cpp` | MIT | `Support/Resources/yarn-LICENSE.txt` | `Contents/Resources/yarn-LICENSE.txt` |
| The Silero VAD v6.2.0 model | `Support/Resources/ggml-silero-v6.2.0.bin` | MIT | `Support/Resources/silero-vad-LICENSE.txt` | `Contents/Resources/silero-vad-LICENSE.txt` |
| The agent skills and one hook | `.claude/skills` and `.claude/hooks/git-guardrails.sh` | MIT | [`.claude/skills/THIRD_PARTY.md`](../.claude/skills/THIRD_PARTY.md) | None |
| The packages swift-argument-parser and swift-atomics | `Package.swift` | Apache-2.0 with the Runtime Library Exception | None | None |

The rules for new code are in [`CODING_STANDARDS.md`](../CODING_STANDARDS.md), Open-source code.
