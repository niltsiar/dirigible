# Product brief

This file keeps the original request from the user, word for word, and an English version in ASD-STE100 style. The Spanish text is the source of truth. The requirement IDs let plans, tests, and commits refer to one requirement.

## Original request (Spanish, verbatim)

> Hazme un clon de Hindenburg (grabación de audio para podcast) que funciona a partir de macos Sonoma. No te olvides de su funcionalidad pro de grabar varias fuentes en diferentes pistas

> Hazme un clon de Hindenburg (grabación de audio para podcast) que funciona a partir de macos Sonoma. No te olvides de su funcionalidad pro de grabar varias fuentes en diferentes pistas sin usar aggregate de mac. La grabación guarda un XML con la info de las pistas y los fragmentos que se guardan en su propia carpeta en formato wav o flac El editor debe tener las mismas características de Hindenburg. Quiero aplicar filtros de reducción de ruido. Quiero autonivelado de volumen por fragmentos. En general quiero las opciones que hacen a hindenburg pro el mejor y mas orientado a grabación de podcast que garage band

## Requirements (English, STE)

R1-R10 come from the original request. R11-R13 come from later messages of the user (2026-09-23).

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
| R11 | The app exports the final mix in the usual podcast formats: MP3 and AAC (in an `.m4a` MP4 container), plus WAV and FLAC. Exports carry podcast metadata (title, artwork, chapters). |
| R12 | The app records audio from other apps, for example a Microsoft Teams, Slack, or Zoom call, so the user can record a remote guest. Each source goes to its own track, the same as a device (R3). |
| R13 | The UI is in English and Spanish. English is the default. The app follows the language of macOS. A preference lets the user select English, Spanish, or the macOS language. |

## Constraints from the team

| ID | Constraint |
|---|---|
| C1 | No Apple developer account. The app is not on the App Store and is not notarized. Local builds use an ad-hoc signature. |
| C2 | No CI service for now. All checks run locally with `make check`. The code is on GitHub at https://github.com/niltsiar/dirigible. |
| C3 | The app is native. |
| C4 | Code, docs, and commits are English. The UI languages are in R13. |

## Open questions

The first planning run answers these questions and records each answer as a decision in `docs/decisions/`.

- Which features are in the first release, and in which order? R7 and R10 are too wide to build at one time. Method from the user: mine the features of Hindenburg PRO, GarageBand, and Logic Pro that are really useful for podcasters. Write the catalog to `docs/research/`, rank it by value for a podcaster, and order the releases from it. The first release is a thin path from record to edit to export.
- What is the XML schema of a session? Guidance from the user: use our own format, because it can follow our features, unless a strong open format already fits. Check the open formats first (for example AES31-3, OpenTimelineIO, AAF, FCPXML) and record why each fits or does not. An open format can still be an import or export target.
- How does the app align tracks from devices that have different clocks (R3, R4)?
- How does capture survive a crash? `AVAudioFile` writes the WAV data size only at close. Options: capture to CAF and convert to WAV or FLAC at stop, or update the WAV header while recording and repair it at launch.
- How does the input callback of each device hand buffers to its file writer without allocation or locks? Options: a ring buffer with preallocated storage in Swift, or a small C target.
- How does the app capture the audio of another app (R12)? Options: Core Audio process taps (`AudioHardwareCreateProcessTap`, macOS 14.2 and later) or ScreenCaptureKit audio (macOS 13 and later, needs the Screen Recording permission). macOS 14.0 and 14.1 have no process taps. Which permission text does each need?
- How does the app stop the remote guest from leaking into the local microphone track? Headphones, echo cancellation, or both?
- Which encoder does MP3 export use (R11)? AudioToolbox encodes AAC but has no MP3 encoder. An MP3 library (for example LAME, LGPL) needs a decision record and a license check against Apache-2.0.
- Which loudness target does export use? Common podcast targets are -16 LUFS for stereo and -19 LUFS for mono.
- WAV or FLAC by default? FLAC needs an encoder. Check what macOS 14 gives through AudioToolbox before you add a library.
- Which noise reduction method (R8): spectral gating, RNNoise, or an Apple voice-processing unit?
- What loudness target does auto-leveling use (R9)? Hindenburg uses loudness (LUFS) targets per clip.
