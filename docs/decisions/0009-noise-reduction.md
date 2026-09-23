# 0009. Noise reduction: AUSoundIsolation offline, vDSP spectral gating as fallback

- Status: accepted
- Date: 2026-09-24

## Context

R8 asks for noise reduction filters. The evidence is in `docs/research/export-and-dsp.md` section 6:

- `AUSoundIsolation` (`kAudioUnitSubType_AUSoundIsolation`, macOS 13 and later) loads and renders offline through `AVAudioEngine` manual rendering on macOS 15.7.9. It lowered white noise from -24.8 to -80.8 dBFS (tested). Apple does not document it well, and Audacity users reported load failures on macOS 13.
- Voice processing and the Voice Isolation microphone mode work only on live input. They cannot process a file.
- RNNoise (BSD-3-Clause) and DeepFilterNet (MIT or Apache-2.0, Rust) are open options.

## Decision

- First method: `AUSoundIsolation`, run offline on each clip through `AVAudioEngine` manual rendering. It is non-destructive: the session stores the effect and its one dial, `WetDryMixPercent`, like the single noise reduction control in Hindenburg. Use `HighQualityVoice` on macOS 15 and later, and `Voice` on macOS 14.
- Before the Release 3 noise reduction run builds it, a manual check on a macOS 14 machine confirms that the unit loads and renders at 44.1 and 48 kHz.
- If that check fails, use spectral gating with vDSP. Its tests are exact: a sine plus noise keeps the sine level within ±0.5 dB, and the noise floor goes down by 10 dB or more.
- Tests with generated signals: white noise alone goes down by 20 dB or more. Voice quality is a manual check with a recording in `.scratchpads/`, never in git.
- Release 3 (see `docs/requirements/releases.md`).

## Consequences

- The session XML gets an `<effect>` element in a later schema version (0003).
- The effect renders on each playback and export. A cache of rendered clips can come later if playback is slow.
- Later: hum and buzz notch filters (`vDSP.Biquad` at 50 or 60 Hz and harmonics). RNNoise or DeepFilterNet only if users need more, each with its own decision record.

## Alternatives considered

- **Spectral gating first.** Rejected as the first method: more DSP work, and AUSoundIsolation already cuts noise by 56 dB on a test signal. Kept as the fallback.
- **RNNoise.** Deferred: a C dependency, 48 kHz only, and no clear gain over AUSoundIsolation yet.
- **Voice processing on live input.** Rejected: live only, and it changes the raw capture (0004).
