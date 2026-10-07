# Product brief

This file keeps the original request from the user, word for word, and an English version in ASD-STE100 style. The Spanish text is the source of truth. The requirement IDs let plans, tests, and commits refer to one requirement.

## Original request (Spanish, verbatim)

> Hazme un clon de Hindenburg (grabación de audio para podcast) que funciona a partir de macos Sonoma. No te olvides de su funcionalidad pro de grabar varias fuentes en diferentes pistas

> Hazme un clon de Hindenburg (grabación de audio para podcast) que funciona a partir de macos Sonoma. No te olvides de su funcionalidad pro de grabar varias fuentes en diferentes pistas sin usar aggregate de mac. La grabación guarda un XML con la info de las pistas y los fragmentos que se guardan en su propia carpeta en formato wav o flac El editor debe tener las mismas características de Hindenburg. Quiero aplicar filtros de reducción de ruido. Quiero autonivelado de volumen por fragmentos. En general quiero las opciones que hacen a hindenburg pro el mejor y mas orientado a grabación de podcast que garage band

## Requirements (English, STE)

R1-R10 come from the original request. R11-R15 come from later messages of the user (2026-09-23). R16 comes from a message of the user (2026-10-07).

| ID | Requirement |
|---|---|
| R1 | The app is a podcast recorder and editor, similar to Hindenburg (Hindenburg PRO feature set). |
| R2 | The app runs on macOS 14 Sonoma and later. |
| R3 | The app records more than one audio source at the same time. Each source goes to its own track. |
| R4 | Multi-source recording does not use a macOS aggregate device. |
| R5 | A recording session saves an XML file. The XML file describes the tracks and the clips. |
| R6 | Each clip is an audio file in WAV or FLAC format. The clip files are in their own folder. |
| R7 | The editor has the same features as the Hindenburg editor. |
| R8 | The user can apply noise reduction filters. |
| R9 | The app levels the volume of each clip automatically. |
| R10 | The app includes the podcast-focused features that make Hindenburg PRO better than GarageBand for podcast work. |
| R11 | The app exports the final mix in the usual podcast formats: MP3 and AAC (in an `.m4a` MP4 container), plus WAV and FLAC. |
| R12 | The app records audio from other apps, for example a Microsoft Teams, Slack, or Zoom call, so the user can record a remote guest. Each source goes to its own track, the same as a device (R3). |
| R13 | The UI is in English and Spanish. English is the default. The app follows the language of macOS. A preference lets the user select English, Spanish, or the macOS language. |
| R14 | The app removes the remote guest's audio that leaks into the local microphone track, by echo cancellation or offline bleed removal. It is not in the first release. |
| R15 | The user sets each track to mono or stereo, and exports the mix in mono or stereo. |
| R16 | Dirigible gives an MCP (Model Context Protocol) server to agents such as Claude Code. The `dirigible mcp` command reads and edits session packages that the app does not have open. The app also has an agent server, which is off by default. When the user turns it on in Settings, an agent can also control the running app: read the session and the selection, play, stop, locate, and edit, with each edit as one undo step. Both servers use the same tools. An agent can start a recording only after the user clicks Record in a consent sheet of the app. An agent never writes a package that the app has open, except through the app. |

## Constraints from the team

| ID | Constraint |
|---|---|
| C1 | No Apple developer account. The app is not on the App Store and is not notarized. Local builds use an ad-hoc signature. |
| C2 | No CI service for now. All checks run locally with `make check`. The code is on GitHub at https://github.com/niltsiar/dirigible. |
| C3 | The app is native. |
| C4 | Code, docs, and commits are English. The UI languages are in R13. |

## Answered questions

The first planning run (2026-09-24) answered the open questions. Each answer links to its decision.

- Which features are in the first release, and in which order? A thin record, edit, and export path first. See [releases.md](releases.md) and the feature catalog in `docs/research/podcast-features.md`.
- What is the XML schema of a session? Our own versioned XML in a document package. No open format stores the capture timing of each device. See [0003](../decisions/0003-session-file-format.md).
- How does the app align tracks from devices that have different clocks? Timing checkpoints for each device, a drift fit, and a resample at stop. See [0004](../decisions/0004-capture-pipeline.md).
- How does capture survive a crash? Capture to CAF segments, finalize to WAV at stop, and recovery when the session opens. See [0004](../decisions/0004-capture-pipeline.md).
- How does the input callback hand buffers to its writer without allocation or locks? An SPSC ring with apple/swift-atomics. See [0005](../decisions/0005-swift-atomics.md).
- How does the app capture the audio of another app, and which permission text does it need? Core Audio process taps with `NSAudioCaptureUsageDescription`. See [0006](../decisions/0006-app-audio-process-taps.md).
- How does the app stop the remote guest from leaking into the local microphone track? Headphones and a warning in Release 2, offline removal in Release 3 (R14). See [0004](../decisions/0004-capture-pipeline.md).
- Which encoder does MP3 export use? LAME as a static C target, with the LGPL obligations. See [0007](../decisions/0007-export-formats-and-encoders.md).
- Do exports carry podcast metadata? Yes, in Release 3. See [releases.md](releases.md).
- How does SwiftPM ship localized UI strings, and how does the preference override the macOS language? `.lproj` tables with `Bundle.main`, and `AppleLanguages`. See [0010](../decisions/0010-ui-strings.md).
- Which loudness target does export use? -16 LUFS for stereo, -19 LUFS for mono, and -1 dBTP. See [0008](../decisions/0008-loudness-and-auto-level.md).
- WAV or FLAC by default? 24-bit WAV, because FLAC seeks slowly. AudioToolbox encodes FLAC for export. See [0003](../decisions/0003-session-file-format.md) and [0007](../decisions/0007-export-formats-and-encoders.md).
- Which noise reduction method? AUSoundIsolation offline, with vDSP spectral gating as the fallback. See [0009](../decisions/0009-noise-reduction.md).
- What loudness target does auto-leveling use? -16 LUFS for a stereo clip and -19 LUFS for a mono clip, as a static clip gain. See [0008](../decisions/0008-loudness-and-auto-level.md).
- Which SwiftPM targets make up the app? Two libraries and a thin app. See [0002](../decisions/0002-module-map.md).
