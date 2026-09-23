# 0003. Session file: a document package with our own XML

- Status: accepted
- Date: 2026-09-24

## Context

R5 asks for an XML file that describes the tracks and the clips. R6 asks for clip files in WAV or FLAC in their own folder. The user asked for our own format unless a strong open format fits. `docs/research/session-formats.md` compares AES31-3, AES31-4, OpenTimelineIO, AAF, FCPXML, and Hindenburg `.nhsx`. None stores the capture timing of each device, and each has another gap: AES31-3 is not XML, the AES31-4 spec is behind a paywall, OTIO is JSON, AAF is binary, FCPXML is built for video.

`docs/research/export-and-dsp.md` section 2 measured seeking in a FLAC file through `AVAudioFile`: 0.65 s at minute 28, against less than 1 ms for WAV.

## Decision

**Layout.** A session is a document package, `<Name>.dirigible/` (`LSTypeIsPackage`), with `session.xml` and a `Clips/` folder inside. Finder moves and copies the XML and its clips as one item. A clip refers to its file by a path relative to `Clips/`.

**Clip files.** 24-bit WAV at the session sample rate. Capture writes CAF first and converts at stop (0004). FLAC is a later preference, because it seeks slowly.

**Schema, version 1.** Our own XML, namespace `https://github.com/niltsiar/dirigible/session`.

- `<session version="1" sampleRate="48000">` holds `<captures>`, `<files>`, `<tracks>`, `<markers>`, and, during a take, `<recording>`.
- `<capture id>` is one device segment (0004): `deviceUID`, `deviceName`, `hostTimeNanos` and `sampleTime` of the first frame, `nominalSampleRate`, `measuredSampleRate`, `latency`, and `resampledFromRate` or `driftCorrected="false"` when finalize applied or refused a correction.
- `<file id path channels length capture>`: `channels` is 1 or 2; the parser refuses any other value. `capture` refers to a `<capture id>`. An imported file has no `capture`.
- `<track id name gain layout="mono|stereo">` with an optional `<route device="UID" channels="1 2"/>` and its `<clip id file start offset length gain/>` children. A file's channel count must match its track's layout; the parser refuses a mismatch.
- `<marker id name position kind="marker|chapter"/>`.
- `<recording takeStart="..." take="3">` lists the armed track IDs. It is present only while a take runs, and recovery removes it (0004).

**Rules.**

- Every position and length is an integer frame count at the session rate. No decimal seconds.
- Gain is in dB. Zero values are written, not left out.
- The take anchor: timeline start = playhead at record start + (first-frame host time - take start host time) - latency. Host time is compared only inside one take.
- Save atomically: write a temporary file, then replace `session.xml`.
- The reader refuses a version higher than it knows, with a clear error. Each new element or attribute that carries user data raises the version. An old app that skips an unknown element and saves would delete that data.
- The XML code is in `DirigibleCore` (0002), with `XMLDocument` for writing and reading.

**Interchange.** The first export for other editors is the AES31-3 ADL: sample-accurate, audio-first, and a small plain-text writer. FCPXML and OTIO can follow. A best-effort `.nhsx` import comes later.

## Consequences

- Later versions add fades, gain envelopes, effects (R8, R9), pan, mute, solo, chapter metadata, and loudness per file. Each raises the version.
- A user who wants the WAV files opens the package with "Show Package Contents". The Release 1 run decides whether the app also offers "Reveal clips in Finder".
- The UTI and the `LSTypeIsPackage` entry go in `Support/Info.plist` in the Release 1 session run, checked by `AppBundleTests`.

## Alternatives considered

- **A session file with a sibling clips folder** (like Hindenburg). Rejected by the plan gate: a user who moves only the XML file loses the audio.
- **An open format as the native file.** Rejected for the reasons in the context. Each can still be an export target.
- **Positions in decimal seconds** (like `.nhsx`). Rejected: not sample-exact.
- **FLAC clips by default.** Rejected for Release 1: seeking is too slow for scrubbing.
