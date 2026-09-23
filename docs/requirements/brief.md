# Product brief

This file keeps the original request from the user, word for word, and an English version in ASD-STE100 style. The Spanish text is the source of truth. The requirement IDs let plans, tests, and commits refer to one requirement.

## Original request (Spanish, verbatim)

> Hazme un clon de Hindenburg (grabación de audio para podcast) que funciona a partir de macos Sonoma. No te olvides de su funcionalidad pro de grabar varias fuentes en diferentes pistas

> Hazme un clon de Hindenburg (grabación de audio para podcast) que funciona a partir de macos Sonoma. No te olvides de su funcionalidad pro de grabar varias fuentes en diferentes pistas sin usar aggregate de mac. La grabación guarda un XML con la info de las pistas y los fragmentos que se guardan en su propia carpeta en formato wav o flac El editor debe tener las mismas características de Hindenburg. Quiero aplicar filtros de reducción de ruido. Quiero autonivelado de volumen por fragmentos. En general quiero las opciones que hacen a hindenburg pro el mejor y mas orientado a grabación de podcast que garage band

## Requirements (English, STE)

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

## Constraints from the team

| ID | Constraint |
|---|---|
| C1 | No Apple developer account. The app is not on the App Store and is not notarized. Local builds use an ad-hoc signature. |
| C2 | No remote server and no CI service for now. All checks run locally with `make check`. |
| C3 | The app is native. |
| C4 | The user-facing language of the app is Spanish. Code, docs, and commits are English. |

## Open questions

The first planning run answers these questions and records each answer as a decision in `docs/decisions/`.

- Which Hindenburg PRO features are in the first release, and in which order? R7 and R10 are too wide to build at one time.
- What is the XML schema of a session? Is it compatible with a known format, or our own format?
- How does the app align tracks from devices that have different clocks (R3, R4)?
- How does capture survive a crash? `AVAudioFile` writes the WAV data size only at close. Options: capture to CAF and convert to WAV or FLAC at stop, or update the WAV header while recording and repair it at launch.
- How does the input callback of each device hand buffers to its file writer without allocation or locks? Options: a ring buffer with preallocated storage in Swift, or a small C target.
- WAV or FLAC by default? FLAC needs an encoder. Check what macOS 14 gives through AudioToolbox before you add a library.
- Which noise reduction method (R8): spectral gating, RNNoise, or an Apple voice-processing unit?
- What loudness target does auto-leveling use (R9)? Hindenburg uses loudness (LUFS) targets per clip.
