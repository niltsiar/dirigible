# 0007. Export: WAV, AAC, FLAC through AVAudioFile; MP3 through LAME

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-25. The export writes through `ExtAudioFile`, not `AVAudioFile`, because `AVAudioFile` does not convert the rate. WAV and FLAC are 16 or 24-bit. AAC takes 64 to 256 kbit/s at 48 kHz or less (see 0019).
- Amended: 2026-10-03, MP3 run. MP3 uses LAME 4.0, not 3.100. The bundle files are `LAME-COPYING.txt` and `LAME-NOTICE.txt`. Warnings in the vendored code are fixed at the cause (see 0034).

## Context

R11 asks for MP3, AAC in `.m4a`, WAV, and FLAC. R15 asks for a mono or stereo mix. The evidence is in `docs/research/export-and-dsp.md` section 1 and a local FLAC encode check:

- `AVAudioFile` writes WAV, AAC in `.m4a`, and FLAC on macOS 15.7.9 (tested). Apple lists `kAudioFormatFLAC` from macOS 10.13.
- AudioToolbox has no MP3 encoder: `afconvert -d .mp3` fails with `fmt?`.
- No MP3 encoder of good quality has an MIT or BSD license. LAME is LGPL-2.0-or-later; its mpglib decoder is GPL. Shine is LGPL with lower quality. The MP3 patents expired in 2017.

## Decision

- **Release 1:** WAV (24-bit), AAC in `.m4a`, and FLAC, all through `AVAudioFile`. No new dependency.
- **Mix layout (R15):** the export takes `.mono` or `.stereo`. The mix renders stereo. A mono track feeds both channels at unity. A mono export folds down after the render as `0.5 * (L + R)`, in our own code, pinned by tests. A mono-only session therefore exports at the track level.
- **Release 2:** MP3 through LAME 4.0, built from source as the static SwiftPM C target `CLame` (0002).
  - Build without the decoder, so no GPL code is in the app.
  - Ship the LGPL text (`LAME-COPYING.txt`) and a LAME notice (`LAME-NOTICE.txt`) in `Contents/Resources`.
  - The app source is public under Apache-2.0, so a user can relink with another LAME. Change to a dynamic library only if a reviewer finds that static linking does not meet LGPL section 6.
  - Publish any change to the LAME source.

## License

| Code | License | Obligations |
|---|---|---|
| LAME 4.0 `libmp3lame` | LGPL-2.0-or-later | LGPL text and notice in the bundle, relinking possible, changes published, decoder off |

This is our reading of the license, not legal advice.

## Consequences

- Release 1 exports cover Apple Podcasts (AAC) and archive use (WAV, FLAC). Hosts that ask for MP3 wait for Release 2.
- FLAC encoding has no test on a macOS 14 machine yet. It is a manual check in the Release 1 export run.
- `AppBundleTests` checks that `LAME-COPYING.txt` and `LAME-NOTICE.txt` are in the bundle, from Release 2.

## Alternatives considered

- **Shine.** Rejected: also LGPL, and lower quality.
- **ffmpeg with an MP3 encoder.** Rejected: a large dependency with the same LGPL obligations.
- **No MP3.** Rejected: R11 asks for it, and many podcast hosts expect it.
