# Dynamic leveler ("Level Over Time") in reference apps

Date: 2026-10-14

This file covers effects that ride the gain of speech over time. It does not repeat `docs/research/auto-level-reference-apps.md` (static Auto Level). Grades: **P** primary, **S** secondary, **U** user post. "Unconfirmed" means that no source answers. "Inference:" marks our reading. No probe or build ran. The PDF text extraction dropped minus signs. The signs below come from the standards.

## 1. Hindenburg PRO: Magic Levels

- Function: "Reduces microphone bleed", "Applies loudness-based gain riding", "Automatically ducks music under speech" [HFH] (P). It can "auto-mix multiple recordings" [HSE] (P).
- Scope: "Just select the desired regions and click" [HSE] (P). Menu path: Unconfirmed.
- Speech detection: 2.02 build 2570 (2023-10-26) fixed "Magic Levels not detecting some speech" [HR2570] (P).
- Method: "adaptive levels, automix, de-bleed and auto-ducking" [PVC] (S, 2020). Staff called it a non-destructive side-chained gate [HUV] (U, search summary only).
- Controls, measure, target, max gain, timing, destructive: Unconfirmed. Inference: no controls ("one-click" [HSE]).

## 2. Adobe Audition

- **Speech Volume Leveler** (Effects > Amplitude and Compression): "a compression effect that optimizes dialogue, even out levels, and removes background noise" [ASV] (P). Controls: Target Volume Level ("relative to zero dBFS"). Leveling Amount ("At low settings, amplifies speech slightly without boosting the noise floor"). Boost Low Signals (off for "smoother sound"). Target Dynamic Range: best "between -45dB and -60dB", range -30 to -80 dB, and a lower value levels more but "can amplify the background noise". Compressor. Noise Gate ("when the signal drops by an offset you specify") [ASV] (P). Other ranges, window, attack, release: Unconfirmed. Default target -12 dB [ACS] (U).
- **Dynamics Processing**: graph compressor or expander. It has a Level Detector (Input Gain, Attack, Release, Peak or RMS) and a Gain Processor (Attack, Release), plus Look-Ahead Time, Noise Gating ("expanded below a 50-to-1 ratio"), Link Channels, and Band Limiting [ASV] (P). It has no target.
- **Essential Sound Loudness**: "To make the loudness level uniform throughout the clip, expand Loudness and click Auto Match" [AES] (P). Inference: static. Clarity > Dynamics (0 to 10) is a compressor [AES] (P).
- Destructive in the Waveform Editor: "use a copy of the original file" [ASV] (P).

## 3. iZotope RX Leveler (and Nectar)

- It "rides the gain in your file". It is "a compressor with a makeup gain" toward a "Target RMS level". "The level detector stage includes the K-weighting filter" [RX9] (P).
- Output: "a Clip Gain envelope, which can be viewed and edited" [RX9] (P).
- Controls [RX9] (P):
  - Optimize For: Dialogue or Music, "different handling of the noise floor".
  - Target Level: "not a loudness compliant leveling tool".
  - Responsiveness: "integration time for RMS level detection".
  - Preserve Dynamics: "the maximal amount of gain applied".
  - Ess Reduction (dB): "avoids adding any boost to esses".
  - Breath Control: a dB level for detected breaths, analysis "regardless of level".
- A fixed internal limiter: "This cannot be adjusted" [RX6] (P).
- Ranges, defaults, look-ahead, stereo link: Unconfirmed. In RX 11 or 12: Unconfirmed. RX 10 and 11 help returned 403. A search summary lists the Leveler in RX 11 Advanced [RXP] (S).
- Nectar Auto Level Mode: real-time, default "target RMS of -8 dB" [NEC] (P, the page mixes Nectar 3 and 4).

## 4. Logic Pro and Final Cut Pro

- Final Cut Pro Loudness: Amount ("overall loudness (compression)") and Uniformity ("dynamic range affected") [FEA] (P). Ranges: Unconfirmed. It is a compressor.
- Logic Mastering Assistant: Loudness knob, center about -14 LUFS-I, true peak -1 dBFS, on the stereo output [LMA] (P, search summary). It does not ride speech. No Logic gain rider was found (Unconfirmed).

## 5. Descript

- Help: auto-leveling "nudges every clip's loudness to a consistent target (around -16 dB)" [DAL] (P).
- Blog, updated 2026-07-29: "When volume peaks above that threshold, Descript reduces it in small steps that are practically undetectable to the ear". "Leveling runs on import" [DBL] (P). The help page and the blog disagree on static or dynamic.
- Dynamic path: Show settings > Mix Audio with Auphonic > Master > Leveler, which "Uses Auphonic's Adaptive Leveler" [DAM] (P).
- Studio Sound: an Intensity slider, no level text [DSS] (P).

## 6. Auphonic Adaptive Leveler

- It classifies "speech, music and background segments". It excludes "noise, wind, breaths, silence etc." from amplification [AUS] (P).
- Leveler Strength: 0 to 100 % ("100% means full leveling"). 110 % is Fast Leveler ("reacts much faster"). 120 % is Amplify Everything (it "also amplifies non-speech background sounds like noise") [AUP] (P). Default: Unconfirmed.
- Compressor: Auto, Soft, Medium (default), Hard, Off. Off gives "only mid-term leveling" [AUP] (P).
- Broadcast Mode: MaxLRA (LU), MaxS (3 s), and MaxM (0.4 s), relative to the loudness target [AUP] (P).
- Multitrack: background segments "won't be amplified". Remove Mic Bleed [AUM] (P).
- Max gain, attack, release: Unconfirmed. Scope: whole file. Inference: it writes a new file.

## 7. Waves Vocal Rider

Values from the vendor PDF [WVR] (P):

- Vocal Sensitivity: -12 to +12 dB, default 0. It separates the vocal from "noise floor, spill, and ambience".
- Attack: Fast or Slow, default Slow.
- Range Min: -12 to +11 dB, default -6 (maximum attenuation).
- Range Max: -11 to +12 dB, default +6 (maximum gain).
- Effective Range: 1 to 24 dB, default 12.
- Idle Arrow: the gain "when there is no vocal activity", to avoid "drastic gain changes between words". Range -12 to +12, default 0.
- Music Sensitivity: needs the music on the sidechain.
- Output: -12 to +12 dB.
- Automation Write.
- "Real-Time means zero latency and no pre-scan needed."

Target: 0 to -42 dBFS, default -21 [WVS] (S). The extracted PDF text did not have this row.

## 8. soundcraft (commit c0cb993, 2026-10-13, MIT or Apache-2.0)

soundcraft has no leveler, AGC, or rider [SC] (P, code search).

- Compressor: feed-forward, soft knee, stereo-linked (the loudest channel drives one gain). Threshold -60 to 0 dB, ratio 1 to 100, attack 0.01 to 300 ms, release 5 to 3000 ms, look-ahead 0 to 10 ms. Code: `crates/dsp/src/plugins/dynamics.rs:3, 13-31, 35-45, 159-190`.
- Gate: threshold -80 to 0 dB, range 0 to 80 dB, hold 0 to 2000 ms. Code: `dynamics.rs:202-209, 271-293`.
- LoudnessMeter: K-weighting and 100 ms sub-blocks. Momentary uses the last 4 sub-blocks and short-term uses the last 30. Integrated uses a -70 LUFS floor and a -10 LU relative gate. Code: `crates/dsp/src/meter.rs:132-135, 222, 343-367`. No LRA.
- Normalize is peak only. Code: `crates/dsp/src/offline.rs:60-80`.

## 9. Audacity (manual only, no code)

- Old Leveller: "a simple, combined compressor and limiter". Degree Light to Heaviest (default Moderate). Threshold for Noise -20 to -80 dB (default -70 dB) [ALV] (P, mirror). It is now a Distortion preset [ADI] (P).
- Legacy Compressor (3.5 and earlier): RMS by default. Its Noise Floor works "to prevent the gain increasing during pauses and so over-amplifying the background noise" [ALG] (P).
- Compressor (3.6 and later): threshold, make-up, knee, ratio, lookahead, attack, release. Its meters show "short-time peak value" [ALC] (P).

## 10. Apple AudioToolbox

Source: `AudioUnitParameters.h`, Xcode 26 macOS SDK [AUH] (P).

- AUDynamicsProcessor ('dcmp'): Threshold -40 to 20 dB (default -20). HeadRoom 0.1 to 40 dB (default 5). ExpansionRatio 1 to 50 (default 2). Attack 0.0001 to 0.2 s. Release 0.01 to 3 s. OverallGain ±40 dB. It "does not have fixed compression ratios": HeadRoom sets the ratio.
- AUMultibandCompressor ('mcmp'): 4 bands. Attack 0.001 to 0.2 s (default 0.08). Release 0.01 to 3 s (default 0.12).
- AUPeakLimiter ('lmtr'): attack, decay, pre-gain ±40 dB.
- AGC: only `kAUVoiceIOProperty_VoiceProcessingEnableAGC`, "On by default", on the live voice-processing IO unit.
- Verdict: these are compressors and limiters, not loudness riders. Detector type: Unconfirmed.

## 11. ITU-R BS.1770-5 and EBU Tech 3341 / 3342

- BS.1770-5 (11/2023): gating of "400 ms blocks (overlapping by 75%)". Absolute threshold -70 LKFS. Relative threshold 10 below the absolute-gated loudness (eq. 6) [BS] (P).
- Tech 3341 v4 §2.2: momentary loudness "uses a sliding rectangular time window of length 0.4 s. The measurement is not gated." Short-term uses 3 s [T41] (P).
- Tech 3342 §3: short-term values ("length 3 seconds", overlap of 2.9 s or more). Absolute gate -70 LUFS, relative gate -20 LU. "LRA is defined as the difference between the estimates of the 10th and the 95th percentiles" [T42] (P).

## Summary table

| App | Measure | Target | Max boost/cut | Noise, silence | Timing | Look-ahead | Link | Scope | Output |
|---|---|---|---|---|---|---|---|---|---|
| Hindenburg Magic Levels | "loudness-based" | Unconfirmed | Unconfirmed | Speech detection | Unconfirmed | Unconfirmed | Unconfirmed | Regions | Unconfirmed |
| Audition SVL | Unconfirmed | dBFS | Leveling Amount | Dynamic range, gate | Unconfirmed | Unconfirmed | Unconfirmed | Selection | File |
| RX Leveler | K-weighted RMS | RMS | Preserve Dynamics | Breath, ess, mode | Responsiveness | Unconfirmed | Unconfirmed | Selection | Clip gain |
| Auphonic | Classifier | LUFS, MaxLRA | Unconfirmed | Classifier | Strength 110 % | Offline | Unconfirmed | File | New file |
| Vocal Rider | Vocal detector | dBFS | ±6 dB default | Idle Arrow | Fast/Slow | None | Stereo part | Track | Automation |
| Audacity Legacy | RMS or peak | Threshold | Ratio | Noise Floor hold | Attack, release | No | Unconfirmed | Selection | Destructive |
| AUDynamicsProcessor | Unconfirmed | None | HeadRoom | Expander | Attack, release | Unconfirmed | Unconfirmed | Stream | Stream |

## Best ideas for Dirigible

- Hold the gain during pauses instead of gating (Audacity Noise Floor, Vocal Rider Idle Arrow). Room tone stays steady.
- Classify speech frames before any boost (Auphonic, Hindenburg). Breaths and noise get no boost.
- Use separate max boost and max cut, with a default of ±6 dB (Vocal Rider, RX Preserve Dynamics). This puts a limit on how much noise goes up.
- Use a K-weighted detector over a speech-length window (RX, EBU 400 ms or 3 s). `Sources/DirigibleAudio/DSP/LoudnessMeter.swift` already K-weights.
- Use two-pass analysis with look-ahead. This costs nothing offline, but Vocal Rider cannot do it in real time.
- Put a fixed limiter after the gain (RX). The new WAV cannot clip.
- Use LRA (Tech 3342) as the test metric (Auphonic MaxLRA): LRA after < LRA before.
- Give one strength control and a speed choice (Auphonic Strength, Fast Leveler).

## Open questions for the plan

- Hindenburg Magic Levels controls and output. No text source lists them.
- Descript: static or dynamic? The help page and the blog disagree.
- Waves Target range: check the official PDF by eye.
- Does RX 12 keep the Leveler? What are its ranges and defaults?
- Auphonic Strength default and max gain.
- Window: 400 ms, 3 s, or a value in between?
- Stereo: one linked gain or a gain per channel?
- Detector: K-weighting or plain RMS?

## Sources

- [HFH] https://hindenburg.com/academy/lessons/feature-highlights/ (P)
- [HSE] https://hindenburg.com/hindenburg-pro-features/story-editing/ (P)
- [HR2570] https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2570/ (P)
- [PVC] https://www.provideocoalition.com/hindenburg-adds-magic-level-automix-de-bleed-and-more/ (S)
- [HUV] support.hindenburg.com UserVoice, via search summary (U)
- [ASV] https://web.archive.org/web/20260130145839/https://helpx.adobe.com/audition/using/amplitude-compression-effects.html (P, page updated 2026-01-21)
- [AES] https://web.archive.org/web/20260609225350/https://helpx.adobe.com/audition/desktop/editing-audio-files/essential-sound-panel.html (P, page updated 2021-04-27)
- [ACS] https://community.adobe.com/questions-544/how-to-change-settings-in-speech-volume-leveller-157592 (U)
- [RX9] https://s3.amazonaws.com/izotopedownloads/docs/rx9/en/leveler/index.html (P)
- [RX6] https://s3.amazonaws.com/izotopedownloads/docs/rx610/en/45-leveler/index.html (P)
- [RXP] https://www.izotope.com/en/products/rx/features/leveler (S)
- [NEC] https://www.izotope.com/en/learn/automatically-set-vocal-levels-with-nectar-3-auto-leveler.html (P)
- [FEA] https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac (P)
- [LMA] https://support.apple.com/guide/logicpro/mastering-assistant-parameters-lgcpa4b810ba/mac (P)
- [DAL] https://help.descript.com/effects-animations-transitions/auto-leveling (P)
- [DBL] https://www.descript.com/blog/article/new-in-descript-automatic-volume-leveling-timeline-editing-improvements (P)
- [DAM] https://help.descript.com/hc/en-us/articles/23106157717133-Advanced-Audio-Mixing-Settings (P)
- [DSS] https://help.descript.com/effects-animations-transitions/studio-sound (P)
- [AUS] https://auphonic.com/help/algorithms/singletrack.html (P)
- [AUM] https://auphonic.com/help/algorithms/multitrack.html (P)
- [AUP] https://auphonic.com/help/web/production.html#adaptive-leveler-settings (P)
- [WVR] https://www.waves.com/1lib/pdf/plugins/vocal-rider.pdf (P)
- [WVS] https://www.scribd.com/document/200318652/Vocal-Rider (S)
- [SC] https://github.com/storytold/soundcraft at c0cb99340891d306e216582db465f3594b89dc1d (P)
- [ALV] https://docs.huihoo.com/audacity/2.0.3/man/leveller.html (P, mirror)
- [ADI] https://manual.audacityteam.org/man/distortion.html (P)
- [ALG] https://manual.audacityteam.org/man/legacy_compressor.html (P)
- [ALC] https://manual.audacityteam.org/man/compressor.html (P)
- [AUH] MacOSX.sdk AudioToolbox `AudioUnitParameters.h` 448-494, 839-907; `AUComponent.h` 448-510; `AudioUnitProperties.h` 2632-2648 (P)
- [BS] https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I!!PDF-E.pdf (P)
- [T41] https://tech.ebu.ch/docs/tech/tech3341.pdf (P)
- [T42] https://tech.ebu.ch/docs/tech/tech3342.pdf (P)
