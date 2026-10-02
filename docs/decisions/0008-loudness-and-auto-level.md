# 0008. Loudness: our own BS.1770 meter, -16 LUFS export, static clip gain

- Status: accepted
- Date: 2026-09-24

## Context

R9 asks for automatic volume leveling of each clip. The export needs a loudness target. The evidence is in `docs/research/export-and-dsp.md` sections 3 to 5:

- macOS has no public API that measures LUFS.
- Apple Podcasts asks for -16 LKFS ±1 and a true peak of -1 dBFS.
- BS.1770 measures a mono file 3 LU lower than the same signal in both channels of a stereo file. A mono 1 kHz sine at -23.0 dBFS reads -26.0 LUFS; the same sine in both channels reads -23.0. A player sends a mono file to both speakers, so a mono file at -19 LUFS sounds as loud as a stereo file at -16 LUFS. Podnews states the same rule.
- Hindenburg sets one level per clip at record or import time, and levels again with Tools > Auto Level.

## Decision

**Meter.** Implement ITU-R BS.1770-5 in a new `DSP/` folder of `DirigibleAudio` (0002) with Accelerate:

- K-weighting biquads computed for each sample rate from the analog prototype.
- 400 ms blocks with 75% overlap, an absolute gate at -70 LUFS, and a relative gate at -10 LU.
- True peak with the 4x FIR of Annex 2.
- Tests generate the EBU Tech 3341 signals in code: cases 1 to 6 within ±0.1 LU; cases 15 to 19 within +0.2/-0.4 dB true peak. A mono 1 kHz sine at -23.0 dBFS reads -26.0 ±0.1 LUFS. Silence and a 300 ms clip give "no measurement", not a number.

**Export target.** -16 LUFS integrated for a stereo export and -19 LUFS for a mono export (R15), true peak at or below -1 dBTP. Presets: -16 (podcast), -18 (AES77 speech), -23 (EBU R 128), -24 (US broadcast), each 3 LU lower for a mono export. At export: measure the mix, apply one static gain, then a true-peak limiter at -1 dBTP. Measure again and show the result in the export report.

**Auto-level (R9).** At stop and at import, measure the gated integrated loudness of each clip. Store a static clip gain in the session XML: `gain = clipTarget - measured`, clamped to ±20 dB. The audio file does not change. `clipTarget` is -16 LUFS for a stereo clip and -19 LUFS for a mono clip: a mono track feeds both mix channels at unity (0007), so it reads 3 LU higher in the stereo mix. A clip with no gated block keeps 0 dB.

**Releases.** The meter, auto-level, and export normalization are Release 2. One meter serves all three.

## Consequences

- The limiter is Apple's `kAudioUnitSubType_PeakLimiter` first. It is probably a sample-peak limiter, so its ceiling is set lower than -1 dBTP, and our true-peak meter checks the result.
- A one-time cross-check against libebur128 or `ffmpeg -af ebur128` on real speech goes in the run ledger as a manual check.
- Later: a speech-only measurement (a voice detector before the meter) and a leveler inside a clip.

## Alternatives considered

- **libebur128 (MIT) as a C target.** Rejected as a dependency: the algorithm is small, and Tech 3341 gives exact tests. Kept as a manual cross-check.
- **-16 LUFS for mono exports too.** Rejected: a mono file at -16 plays 3 LU louder than a stereo file at -16, and it contradicts the -3 LU rule for mono clips in this record.
- **Destructive leveling (write new audio).** Rejected: a static clip gain is non-destructive and can be changed.
