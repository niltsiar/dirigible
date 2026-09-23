# Export formats and audio DSP

Date: 2026-09-23

## Scope

This document answers the export and DSP questions in `docs/requirements/brief.md`: export formats and the MP3 encoder (R11), the default clip format (R6), loudness measurement, the export loudness target, auto-leveling per clip (R9), and noise reduction (R8). The limits come from `AGENTS.md` (Apple frameworks first, a decision record for each third-party dependency) and `docs/decisions/0001-native-swift-stack.md`.

Sources are the macOS 26 SDK headers on the development Mac (`xcrun --show-sdk-path`), Apple documentation, the standards, and the library repositories. The mark "(unconfirmed)" means that this research did not confirm the claim in a primary source. The mark "(tested)" means a local test on macOS 15.7.9, Intel x86_64, Xcode 26, on 2026-09-23. The test scripts are in the session scratchpad and are not in git. This document is not legal advice.

## 1. Export formats (R11)

### Facts

- **Encoders in AudioToolbox (tested).** `kAudioFormatProperty_EncodeFormatIDs` returns `aac aace aacf aacg aach aacl aacp alac alaw apac flac ilbc ima4 lpcm opus ulaw`. There is no `.mp3` encoder. `afconvert -f MPG3 -d .mp3` fails with `fmt?`.
- **WAV, AAC, FLAC through AVAudioFile (tested).** `AVAudioFile(forWriting:settings:)` writes a FLAC file (`AVFormatIDKey: kAudioFormatFLAC`, 24-bit source) and an `.m4a` file (`kAudioFormatMPEG4AAC`, 128 kbit/s). `afinfo` reads both files correctly.
- **FLAC version.** `kAudioFormatFLAC` is available from macOS 10.13 (Apple documentation JSON, `introducedAt: 10.13`). WWDC 2017 session 501 says: "On the FLAC side, we have the codec, file, and the streaming support." The FLAC encoder is thus in AudioToolbox from macOS 10.13, so it is on macOS 14. The encoder on macOS 14 is not tested on a macOS 14 machine (unconfirmed). Add a manual check to the first export run.
- **MP3 patents.** Fraunhofer IIS: "On April 23, 2017, Technicolor's mp3 licensing program for certain mp3 related patents and software of Technicolor and Fraunhofer IIS has been terminated."
- **LAME.** The license is the GNU Library GPL version 2 (`COPYING`), "or (at your option) any later version" (LGPL-2.0-or-later). The LAME license note says: link LAME as a separate library, acknowledge LAME with a link to its web site, and release modifications of LAME under the LGPL. The decoder part (mpglib) is GPL, not LGPL. Build LAME with the decoder disabled. The last release is 3.100 from 2017 (unconfirmed).
- **LGPL with an Apache-2.0 app.** The LGPL lets a program of any license link the library. The distributor must let the user change the library and relink the program. With dynamic linking, a replaceable `libmp3lame.dylib` meets this rule. With static linking, the distributor must supply the object code or source of the program so that the user can relink. Dirigible is open source, so the public repository and build scripts meet this rule (unconfirmed legal reading). In both cases, ship the LGPL text and a LAME notice in the app bundle.
- **Shine.** The license is also LGPL-2.0 (`COPYING` in `toots/shine`). Shine is fixed-point, CBR only, and has a simple psychoacoustic model. Its quality is lower than LAME (unconfirmed).
- **Permissive MP3 encoders.** This research found no MIT or BSD MP3 encoder of good quality (unconfirmed). minimp3 is a decoder only.
- **Hindenburg.** Hindenburg PRO exports `.wav, .mp3, .mp2, .aac, .m4a, .aif, .flac, .opus, .mp4, .mov` (Hindenburg features page).
- **Apple Podcasts.** Apple Podcasts Connect accepts WAV, FLAC, or MP3. RSS feeds use MP3 or AAC. The page recommends MP3 at 96–128 kbit/s mono and 128–256 kbit/s stereo, and AAC at 64–128 kbit/s mono and 128–256 kbit/s stereo, all at 44.1 or 48 kHz.

### Options for MP3

| Option | License | Quality | Build work |
|---|---|---|---|
| LAME, static, SwiftPM C target from source | LGPL-2.0+ | Reference quality | Vendor `libmp3lame/*.c`, write one `config.h`, exclude `mpglib` and `frontend`. No nasm, no assembly. |
| LAME, dynamic, `.dylib` in `Contents/Frameworks` | LGPL-2.0+ | Same | As above, plus a `.dynamic` product, an rpath, and a copy step in `scripts/bundle.sh`. |
| Shine | LGPL-2.0 | Lower | Same license obligations as LAME, and no gain. |
| No MP3. Export AAC only. | None | n/a | None. Some hosts ask for MP3 (unconfirmed). |

### Recommendation

- First release: WAV, AAC in `.m4a`, and FLAC. All three use `AVAudioFile` with a different settings dictionary. There is no new dependency.
- Next release: MP3 with LAME, static, as a SwiftPM C target built from source. Disable the decoder. Write a decision record that names the LGPL obligations. Put `COPYING` and a LAME notice in `Contents/Resources`. Change to dynamic linking only if a reviewer says that static linking does not meet LGPL section 6.

## 2. Default clip format (R6)

### Facts

- **Seek cost (tested).** `AVAudioFile` seek plus a 4800-frame read, 30-minute mono 48 kHz 24-bit file: FLAC 0.039 s at 60 s, 0.65 s at 1700 s. WAV under 0.001 s at both positions. The FLAC time grows with the position, so the decoder reads from the start. A forum report on macOS 26 gives the same result (Apple forum thread 819924). The editor seeks and scrubs often, so this cost is large.
- **Size (tested).** The same test signal (sine plus low noise) gives FLAC at 76% of the WAV size. Speech gives more compression, often about 50–60% (unconfirmed).
- **Capture.** FLAC encoding on the capture path adds CPU work and a file that a crash can leave without a valid end. `docs/research/capture.md` recommends a crash-safe capture file.
- **Hindenburg.** The Hindenburg Journalist 1.21 user guide says "all sessions are 16 bit" and uses 44.1 kHz by default. The current format of Hindenburg PRO clip files is not confirmed (unconfirmed). A session is a `.nhsx` file and a folder of audio files with the same name (Hindenburg support).

### Options

| Option | Seek | Disk | Risk |
|---|---|---|---|
| WAV, 24-bit PCM | Instant | 100% | 4 GiB limit: about 8 h mono at 48 kHz. |
| FLAC | Linear in `AVAudioFile` | About 50–76% | Slow scrub. Needs libFLAC for fast seek (new dependency). |
| WAV for editing, FLAC as a user choice for archive | Instant while editing | Smaller archive | One more code path, but it uses the same `AVAudioFile` call. |

### Recommendation

- WAV, 24-bit PCM, at the device sample rate, is the default clip format.
- Offer FLAC as a preference for new clips, with a note that scrubbing is slower. Do this after the first release.

Update 2026-09-23: decision 0003 stores clips at the session sample rate, not the device rate, because finalize resamples for drift anyway.
- Keep the crash-safe capture file from `docs/research/capture.md`. Finalize it to WAV (or FLAC) at stop.

## 3. Loudness measurement

### Facts

- **No public Apple API measures LUFS.** The SDK headers have `kAudioCodecPropertyProgramTargetLevel` (a decoder output target, not a measurement) and, from macOS 26, encoder DRC keys in `AVAudioSettings.h`. No header has a loudness meter. `afconvert` has `--soundcheck-generate` and `--anchor-generate` ("dialogue anchor level"), but no public API gives these values, and they are not BS.1770 integrated loudness (unconfirmed). There is no `afloudness` tool on macOS 15.7 (tested). `afclip` finds clipped samples with 4x upsampling, but it does not give loudness.
- **ITU-R BS.1770-5 (2023), Annex 1.** K-weighting is two biquads (a shelf and a high-pass). The published coefficients are for 48 kHz. Other rates need new coefficients with the same response. Loudness is `-0.691 + 10 log10(sum G_i * z_i)`. `G = 1.0` for L, R, and C, and 1.41 for the surround channels. Gating uses 400 ms blocks with 75% overlap, an absolute gate at -70 LKFS, and a relative gate at -10 dB under the loudness after the first gate.
- **BS.1770-5, Annex 2 (true peak).** 4x oversampling with a 48-tap, 4-phase FIR interpolator (the coefficient table is in the annex), then the absolute value, then `20 log10`. In floating point, the 12.04 dB attenuation step is not necessary. At 96 kHz, 2x oversampling is sufficient.
- **EBU Tech 3341 (2023), Table 1.** Case 1: stereo 1 kHz sine, -23.0 dBFS peak per channel, 20 s gives M, S, I = -23.0 ±0.1 LUFS. Case 2: the same at -33.0 dBFS gives -33.0 ±0.1 LUFS. Cases 3–6 test the gates. Cases 15–19 test true peak, for example a stereo sine at fs/4, 0.50 FFS, phase 45° gives -6.0 +0.2/-0.4 dBTP. Cases 20–23 give 0.0 +0.2/-0.4 dBTP.
- **Mono (computed).** A mono file is one channel with `G = 1.0`. The K-weighting gain at 1 kHz is +0.698 dB. A mono 1 kHz sine at -23.0 dBFS peak thus reads -26.0 LUFS. The same sine in both stereo channels reads -23.0 LUFS. libebur128 has `EBUR128_DUAL_MONO` ("a channel that is counted twice") for mono that plays on two speakers.
- **libebur128.** A C implementation with an MIT license (`jiixyj/libebur128`).

### Options

| Option | Work | Dependency |
|---|---|---|
| Own BS.1770 in Swift with Accelerate | About 200 lines: `vDSP.Biquad` for K-weighting, `vDSP.meanSquare` per 100 ms step, gating in Swift, polyphase FIR for true peak | None |
| Vendor libebur128 as a C target | Small wrapper | MIT, needs a decision record |

### Recommendation

- Implement BS.1770-5 in a DSP library target with Accelerate. The domain target does not import it.
- Compute the K-weighting coefficients from the analog prototype for each sample rate (the method of libebur128). Use the annex FIR for true peak at 44.1 and 48 kHz, and 2x at 88.2 and 96 kHz.
- Tests generate the signals in code at 44.1 and 48 kHz:
  - Tech 3341 cases 1–6: assert the value ±0.1 LU.
  - Mono 1 kHz sine at -23.0 dBFS: assert -26.0 ±0.1 LUFS.
  - Tech 3341 cases 15–19: assert the true peak within +0.2/-0.4 dB.
  - Silence and a 300 ms clip: assert "no measurement", not a number.
- Cross-check once with libebur128 or `ffmpeg -af ebur128` on real speech. Record it as a manual check in the run ledger.

Update 2026-09-23: decision 0002 puts the DSP code in the `DirigibleAudio` target, not in a separate DSP target.

## 4. Export loudness target

### Facts

- **Apple Podcasts:** "the overall loudness remains around -16 dB LKFS, with a +/- 1 dB tolerance", and "the true-peak value doesn't exceed -1 dB FS".
- **AES TD1004.1.15-10 (2015):** target loudness not higher than -16 LUFS and not lower than -20 LUFS. Maximum true peak -1 dBTP at the input of a lossy codec (secondary source: production-expert.com; the AES PDF blocks downloads).
- **AES TD1008 (2021) and AES77-2023:** distribution loudness -18 LUFS for speech and "assorted" content such as podcasts (secondary sources: productionadvice.co.uk, radioworld.com).
- **EBU R 128:** -23.0 LUFS for broadcast, maximum true peak -1 dBTP.
- **Spotify:** normalizes music playback to -14 LUFS (Spotify artist support). The podcast delivery specification was not readable (unconfirmed for podcasts).
- **Mono.** Podnews: "A mono file at -19 LUFS should sound just as loud as a stereo file at -16 LUFS." BS.1770 measures a mono file 3 LU lower than the same signal in two channels (section 3). A Buzzsprout review says that Hindenburg PRO detects a mono or stereo track at export and changes the loudness to fit.
- **Hindenburg PRO presets:** -23, -24, -18, -16 LUFS (Hindenburg features page).

### Recommendation

- Default: -16 LUFS integrated for a stereo export, -19 LUFS for a mono export, true peak at or below -1 dBTP.
- Preset list: -16 (podcast), -18 (AES77 speech), -23 (EBU R 128), -24 (US broadcast, ATSC A/85, unconfirmed source). Each preset uses -3 LU for mono.

Update 2026-09-24: decision 0008 keeps this recommendation: -16 LUFS for stereo and -19 LUFS for mono.
- The export report shows the measured integrated loudness and true peak after processing.

## 5. Auto-leveling per clip (R9)

### Facts

- **Hindenburg Journalist 1.21 user guide.** "Auto level will insure that all audio is perceived as equally loud." On import, the levels are set to Narration -21 LUFS, Music -23 LUFS (EU mode). The US mode uses -20 and -21 LUFS. Tools > Auto Level (⌘L) analyzes the selected regions again. A clip level can snap back to the auto level.
- **Transom.** Tools > Auto Level on a selected clip. A preference runs it after import and record.
- **Buzzsprout review.** "When you're finished recording and press Stop, Hindenburg will automatically analyze your audio file and balance the audio."
- **Gain type.** The guides describe one level per clip that the user can change after. This research did not confirm whether Hindenburg also changes the gain over time inside a clip (unconfirmed).

### Recommendation

1. At stop and at import, measure the gated integrated loudness of each clip (section 3).
2. Set a static clip gain: `gain = clipTarget - measured`. Store it as a clip property in the session XML. The audio file does not change.
3. `clipTarget` for a mono clip is the export target minus 3 LU (-19 LUFS for the default). A mono clip on a center pan gives both stereo channels the full signal, so it measures +3 LU in the stereo mix. Confirm this with the chosen pan law in a test.
4. Clamp the gain to ±20 dB (a starting value, tune it). A clip with no gated block (silence, or shorter than 400 ms) keeps 0 dB.
5. Do not limit per clip. The export limiter controls true peak (step 6).
6. At export: measure the mix, apply one static gain to the target, then a true-peak limiter at -1 dBTP. Measure again and report. Apple has `kAudioUnitSubType_PeakLimiter`. It can run offline with `AVAudioEngine` manual rendering (unconfirmed). It is a sample-peak limiter (unconfirmed), so set its ceiling lower than -1 dBTP and check the result with the true-peak meter.
7. Later: speech-only loudness (a voice detector before the measurement) and a short-term leveler inside a clip.

## 6. Noise reduction (R8)

### Facts

- **AUSoundIsolation.** `kAudioUnitSubType_AUSoundIsolation = 'vois'`, `API_AVAILABLE(macos(13.0))` (AUComponent.h). Parameters: `kAUSoundIsolationParam_WetDryMixPercent` and `kAUSoundIsolationParam_SoundToIsolate`. `kAUSoundIsolationSoundType_Voice` is macOS 13. `kAUSoundIsolationSoundType_HighQualityVoice` is macOS 15 (AudioUnitParameters.h). Apple documentation has no description of the unit.
- **AUSoundIsolation offline (tested).** The component "AUSoundIsolation v1.6.0" loads on macOS 15.7, Intel. It runs as an `AVAudioUnitEffect` in `AVAudioEngine` offline manual rendering at 48 kHz mono. White noise at -24.8 dBFS RMS comes out at -80.8 dBFS RMS. The quality on speech is not tested.
- **AUSoundIsolation risks.** Users of Audacity on macOS 13 reported "AUSoundIsolation failed to register: could not initialize component" (Audacity forum). It is a neural model for voice, so it can remove sounds that are not voice, for example music or ambience. The behavior on macOS 14 and the sample rates that it accepts are not tested (unconfirmed).
- **Voice processing I/O.** `AVAudioInputNode.setVoiceProcessingEnabled` (macOS 10.15) works when the engine renders to a device. It does not work in manual rendering mode (WWDC 2019 session 510). It is real-time only. It is useful for echo cancellation (the remote guest question in `docs/research/capture.md`), not for noise reduction on files.
- **Mic Mode "Voice Isolation".** The user selects it in Control Center. It applies to the live input of an app that uses voice processing (unconfirmed detail). It cannot process a file.
- **Hindenburg.** Hindenburg PRO has "Single Dial Noise Reduction" (features page). A secondary source says that it finds persistent noise in 3 bands (buzz, hum, hiss) and is non-destructive (unconfirmed). The Voice Profiler is an automatic EQ from a voice sample, not a noise filter (Hindenburg Journalist user guide).
- **RNNoise.** BSD-3-Clause, C, xiph. 48 kHz, frames of 480 samples (`FRAME_SIZE` in `src/denoise.h`). The build downloads model data from Xiph servers. The last commit is from 2025-02.
- **DeepFilterNet.** MIT or Apache-2.0. Rust (libDF) with C bindings. 48 kHz full band. The last commit is from 2024-10. It needs a Rust toolchain in the build.

### Options

| Option | Offline on files | Quality | Work | Dependency |
|---|---|---|---|---|
| AUSoundIsolation, wet/dry as the one dial | Yes (tested) | High on voice (unconfirmed), neural | About 60 lines | None, but undocumented |
| Spectral gating with `vDSP.FFT` | Yes | Medium, "musical noise" artifacts | About 250 lines | None |
| RNNoise as a C target | Yes | Medium to high on voice | Wrapper, resample to 48 kHz | BSD-3, model data in the repo |
| DeepFilterNet | Yes | High | Rust build in `make` | MIT/Apache, Rust toolchain |
| Voice processing I/O, Mic Mode | No, live only | n/a | n/a | n/a |

### Recommendation

- First method: AUSoundIsolation through offline `AVAudioEngine`, per clip, non-destructive. The one dial is `WetDryMixPercent`. Use `HighQualityVoice` on macOS 15 and later, and `Voice` on macOS 14.
- Before the plan gate, run a spike on a macOS 14 machine. Confirm that the unit loads and renders at 44.1 and 48 kHz. Record the result as a manual check.
- Tests use generated signals: white noise alone goes down by 20 dB or more. Voice quality is a manual check with a recording in `.scratchpads/`, never in git.
- If the spike fails, use spectral gating with vDSP as the fallback. Its tests are exact: a sine plus noise keeps the sine level within ±0.5 dB and lowers the noise floor by 10 dB or more.
- Later upgrade: hum and buzz notch filters (`vDSP.Biquad` at 50 or 60 Hz and harmonics) for the Hindenburg "buzz, hum, hiss" bands. Then RNNoise or DeepFilterNet only if users need more control than AUSoundIsolation gives. Each needs a decision record.

## License check

| Code | Use | License | Compatible with Apache-2.0 app | Obligations |
|---|---|---|---|---|
| LAME 3.100 (`libmp3lame`) | MP3 export, next release | LGPL-2.0-or-later. mpglib decoder is GPL. | Yes, as a linked library (unconfirmed legal reading) | Disable the decoder. Ship the LGPL text and a LAME notice. Keep relinking possible (public source, or a dylib). Publish changes to LAME. |
| Shine | Not recommended | LGPL-2.0 | Same as LAME | Same as LAME |
| libebur128 | Optional cross-check only | MIT | Yes | Keep the copyright notice |
| RNNoise | Later option for R8 | BSD-3-Clause | Yes | Keep the copyright notice. No endorsement. |
| DeepFilterNet | Later option for R8 | MIT or Apache-2.0 | Yes | Keep the notice. Rust build. |

## Sources

- SDK headers, macOS 26 SDK: `CoreAudioTypes/CoreAudioBaseTypes.h`, `AudioToolbox/AudioFile.h`, `AUComponent.h`, `AudioUnitParameters.h`, `AudioCodec.h`, `AVFAudio/AVAudioSettings.h`, `AVAudioIONode.h`.
- Apple, `kAudioFormatFLAC` availability: https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac
- Apple, WWDC 2017 session 501 "What's New in Audio" (transcript): https://asciiwwdc.com/2017/sessions/501
- Apple, WWDC 2019 session 510 "What's New in AVAudioEngine": https://developer.apple.com/videos/play/wwdc2019/510
- Apple forum, FLAC seek in `AVAudioFile`: https://developer.apple.com/forums/thread/819924
- Apple Podcasts audio requirements: https://podcasters.apple.com/support/893-audio-requirements
- ITU-R BS.1770-5 (11/2023): https://www.itu.int/rec/R-REC-BS.1770
- EBU Tech 3341 (2023): https://tech.ebu.ch/docs/tech/tech3341.pdf
- EBU R 128: https://tech.ebu.ch/docs/r/r128.pdf
- AES TD1004 summary: https://www.production-expert.com/production-expert-1/aes-update-loudness-recommendations-for-audio-only-streaming
- AES TD1008 summary: https://productionadvice.co.uk/td1008/
- AES77-2023: https://www.aes.org/standards/blog/2023/7/aes77-2023
- Spotify loudness normalization: https://support.spotify.com/us/artists/article/loudness-normalization/
- Podnews, LUFS for podcasters: https://podnews.net/article/lufs-lkfs-for-podcasters
- Fraunhofer IIS, mp3 licensing: https://www.iis.fraunhofer.de/en/ff/amm/consumer-electronics/mp3.html
- LAME license note: https://lame.sourceforge.io/license.txt
- LAME `COPYING` (mirror): https://github.com/lameproject/lame
- Shine: https://github.com/toots/shine
- libebur128: https://github.com/jiixyj/libebur128
- RNNoise: https://github.com/xiph/rnnoise
- DeepFilterNet: https://github.com/Rikorose/DeepFilterNet
- Hindenburg PRO features: https://hindenburg.com/academy/features/features-hindenburg-pro/
- Hindenburg Journalist 1.21 user guide: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- Hindenburg support, session files: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- Transom, audio producer's guide to loudness: https://transom.org/2021/the-audio-producers-guide-to-loudness/
- Buzzsprout, Hindenburg review: https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough
- Audacity forum, AUSoundIsolation on Ventura: https://forum.audacityteam.org/t/ausoundisolation-on-ventura/66441
