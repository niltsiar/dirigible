# Research: reference behavior of Reduce Rumble (F98), Repair Clipped Peaks (F99), and Soften Harsh S (F100)

Date: 2026-10-27

No build and no Swift probe ran. Evidence level: helpx.adobe.com returned HTTP 403 to WebFetch for every page. All Adobe text below comes from search-engine extracts of the helpx pages, and from third-party Audition guides where marked. No Adobe default value was confirmed. Treat each Adobe number as "reported", not "read on the page".

## Summary

- F98 control: a high-pass cutoff in Hz plus a slope choice. Recommended default: 80 Hz, 12 dB/oct. Choices: 6, 12, 18, 24 dB/oct. Sources: Audition Essential Sound (Reduce Rumble targets noise "below 80 Hz"); SoundCraft EQ 7-band (HPF Freq default 80 Hz, HPF Slope default 12 dB/oct, 6/12/18/24 choices).
- F98 range: Inference: 20 to 300 Hz fits speech. SoundCraft allows 10 to 2000 Hz. Audacity High-pass allows any frequency of at least 0.1 Hz, default 1000 Hz (a general default, not a speech default).
- F98 Audition UI: a checkbox and a 0 to 10 slider named "Reduce Rumble". Audition does not document the slider-to-Hz map. A Hz cutoff is easier to test.
- F99 control: a clip threshold in percent of the clip peak, plus a "reduce level" in dB. Recommended default: 95 percent, -9 dB. Range: 0 to 100 percent, -30 to 0 dB. Source: Audacity Clip Fix (`clipfix.ny`: 95, 0 to 100; -9, -30 to 0).
- F99 Audition names: Gain (attenuation before repair, or Auto), Tolerance (0 percent = flat peaks at maximum only; 1 percent catches most clipping), Min. Clip Size, Interpolation (Cubic or FFT). Presets: Default, Restore Heavily Clipped, Restore Light Clipped, Restore Normal. Numeric defaults: not confirmed.
- F99 algorithm: Audacity does a cubic spline over each run above the threshold, using the slope of 4 samples at each side. Audition Cubic is the same class. Both docs say it works only for light clipping.
- F100 control: Frequency, Threshold, Range (maximum reduction), and Listen. Recommended default: 6000 Hz, -30 dB, 10 dB, Listen off. Ranges: 2000 to 16000 Hz, -60 to 0 dB, 0 to 40 dB. Source: SoundCraft `de_esser` (`crates/dsp/src/plugins/dynamics.rs`).
- F100 band: Logic Pro documentation gives sibilance at 3 to 6 kHz (male) and 5 to 8 kHz (female). 6 kHz sits in both bands.
- F100 Audition UI: Essential Sound DeEss is a 0 to 10 slider. The DeEsser effect has Threshold, Center Frequency, Bandwidth, Output Sibilance Only, a Gain Reduction readout, and Mode (Broadband or Multiband).
- Hindenburg PRO: has an EQ with a high/low pass filter (staff reply, 2015). No first-party page lists a de-esser or a clip repair tool. Absence is not proven.
- Clip detection rule: no authoritative standard found. Audacity uses a percent of the peak. Inference: a run of at least 3 samples at or above the threshold is a clip.
- SoundCraft has no de-clip and no rumble effect. It has the EQ HPF and the De-Esser, both marked as AudioSuite (offline) processors.

## F98 Reduce rumble (high-pass)

| App | Control | Default | Range | What the user sees |
|---|---|---|---|---|
| Audition, Essential Sound (Dialogue, Repair) | Reduce Rumble checkbox and slider | Not documented | 0 to 10 | A checkbox per property, then a slider. Text: very low-frequency noise "below 80 Hz", for example a turntable motor or an action camera. Source: Adobe Essential Sound page (search extract). |
| Audition, Scientific Filter | Preset "Remove Subsonic Rumble" | Not documented | Not documented | A classic high-pass preset (Adobe Community expert, via search extract). Filter family: Bessel, Butterworth, Chebyshev, elliptical. |
| Audition, Parametric and Graphic EQ | High-pass and low-pass presets | Not documented | Not documented | Adobe says both EQs ship high/low pass presets (search extract). |
| Audition, FFT Filter | Broad high or low pass, notch | Not documented | Not documented | FFT size trades frequency accuracy for time accuracy. A blog lists the preset "Kill the Mic Rumble". Not confirmed by Adobe. |
| Hindenburg PRO | EQ, "High/low pass filter" | Not documented | Not documented | Staff reply, 13 Nov 2015: "there is also a High/low pass filter in the EQ". Shift-drag changes the Q point. A 2020 review (Buzzsprout, secondary) says: "Apply a high-pass filter to your track to get rid of any audio under 100 hertz." No separate "rumble" control. |
| SoundCraft, `eq_7band` (`crates/dsp/src/plugins/eq.rs`) | HPF on, HPF Freq, HPF Slope | Off, 80 Hz, 12 dB/oct | 10 to 2000 Hz (log); 6, 12, 18, 24 dB/oct | A toggle, a frequency, and a slope choice. The strip plugin (`strip.rs`) has the same HPF: off, 80 Hz, range 10 to 2000 Hz. |
| SoundCraft, algorithm | Cascaded biquads | n/a | n/a | 6 dB/oct is one first-order section. 12 dB/oct is one Butterworth biquad (Q 0.707). 18 dB/oct is first-order plus a biquad with Q 1.0. 24 dB/oct is two biquads with Butterworth Q values for order 4. File: `eq.rs`, function `pass_filter`; `biquad.rs`. |
| Audacity, High-pass filter (`share/nyquist-plug-ins/highpass.ny`) | Frequency (Hz); Roll-off (dB per octave) | 1000 Hz; 6 dB | At least 0.1 Hz, below Nyquist; 6, 12, 24, 36, 48 dB | A text field and a choice list. Manual: the cutoff is the -3 dB point. Higher roll-off gives a steeper slope. Preview is on. The manual states no default. The defaults come from the source. |
| Audacity, Filter Curve EQ | Curve points | Flat | +30 to -30 dB view | No built-in low-cut preset. The manual shows a user-built cut below 100 Hz as an example. |
| Logic Pro, Channel EQ | Band 1 is the high-pass filter | Not documented | Not documented | The slope changes with the Gain/Slope field or by a drag. Q has no effect at 6 dB/oct. The slope list (for example 6 to 48 dB/oct) was not confirmed. |
| Auphonic | Adaptive high-pass filter | On with the "hipfilter" method | Not user-set | It finds the lowest wanted signal in each segment and removes the low frequencies below it. It uses zero-phase filtering. The docs give no Hz value. |
| Descript Studio Sound | None | n/a | n/a | Docs describe noise and echo reduction with an intensity control. No rumble part is documented. |

Podcast numbers for F98:

- Cutoff: 80 Hz (Adobe, Reduce Rumble, "below 80 Hz"; SoundCraft HPF default). 100 Hz appears in one secondary source (Buzzsprout for Hindenburg).
- Slopes: 6, 12, 18, 24 dB/oct (SoundCraft). Audacity offers 6, 12, 24, 36, 48.
- Inference: a speech cutoff above 150 Hz removes voice body. The lead needs a test with a male voice. No source states a limit.

## F99 Repair clipped peaks (de-clip)

| App | Control | Default | Range | What the user sees |
|---|---|---|---|---|
| Audition, Diagnostics panel | Effect = DeClipper, Preset, Settings, Scan, Repair, Repair All | Preset "Default" | n/a | The user opens Window > Diagnostics (also Effects > Diagnostics > DeClipper). Scan marks every place with possible clipping and shows the count (one tutorial reports "258 problems"). The list lets the user select items and choose Repair, Delete, or Mark. Repair All fixes every item. Repaired items get a "Repaired" label. Mark creates markers (right-click, Create Markers). Click Scan again to check what remains. |
| Audition, DeClipper Gain | Gain | Not confirmed | Not confirmed | Attenuation applied before processing. "Auto" bases the gain on the average input amplitude. |
| Audition, DeClipper Tolerance | Tolerance | Not confirmed | Percent | "Amplitude variation" allowed in clipped areas. 0 percent finds only flat clipping at maximum. 1 percent finds most clipping. Tutorials use up to 10 percent ("under 10 percent gives good results", "9 percent if unsure"). |
| Audition, DeClipper Min. Clip Size | Min. Clip Size | Not confirmed | Not confirmed | Length of the shortest run of clipped samples to repair. A lower value repairs more samples. |
| Audition, DeClipper Interpolation | Cubic or FFT | Not confirmed | FFT Size menu (number of bands; more bands give more accuracy and more time; up to 128 bands per one tutorial) | Cubic: spline curves, faster, may add false frequencies. FFT: Fast Fourier transform, slower, "best for severe clipping". |
| Audition, presets | Default, Restore Heavily Clipped, Restore Light Clipped (one source: "Lightly"), Restore Normal | Default | n/a | Presets work alone or in a chain. Preset values: not confirmed. |
| Audition, limits | Clipping under 0 dBFS | n/a | n/a | One tutorial (Adventist Learning Community) says DeClipper cannot find clipped sections that sit below 0 dBFS. Not confirmed by Adobe. |
| Hindenburg PRO | None found | n/a | n/a | No first-party page lists clip repair, a clip warning, or a clip indicator. Auto Level targets: dialogue peaks at -9 dB (QPPM) and music peaks at -15 dB. Those are level targets, not a clip alarm. |
| SoundCraft | None | n/a | n/a | `rg` over README, ROADMAP, `docs/`, and `crates/` finds no de-clip code. |
| Audacity, Clip Fix (`share/nyquist-plug-ins/clipfix.ny`; manual `clip_fix.html`) | "Threshold of Clipping (%)"; "Reduce amplitude to allow for restored peaks (dB)" | 95 percent; -9 dB | 0 to 100 percent; -30 to 0 dB | Two fields and a preview. Manual: the threshold is how close to the maximum magnitude a sample must be. It assumes the same clip level at both peaks. It works only for light clipping. It is slow on long selections. The source header says GPL v2 (the task brief says GPLv3: both are copyleft, so do not copy code). |
| Audacity, algorithm idea | Cubic spline over each run | n/a | n/a | Find each run above the threshold. Take the slope from 4 samples before and after the run. Fill the run with a cubic curve. The threshold is a ratio of the selection peak. Then apply the -9 dB gain to the whole selection. It works in blocks of 100000 samples and skips 4 samples at each block edge. |
| iZotope RX De-clip (RX 6 docs) | Threshold (dB), Makeup Gain (dB), Quality (Low, Medium, High), Suggest, Post-Limiter | Not stated | Not stated | A histogram of sample levels with draggable threshold lines. "Set just below the actual level of clipping." Suggest computes thresholds from the selection. Threshold Link sets positive and negative thresholds apart. Low quality is fast. Preview Low first. |

Clip detection rule:

- Audition: samples within Tolerance of the maximum, in runs of at least Min. Clip Size.
- Audacity: any sample at or above Threshold times the selection peak starts a run. The run ends at the first sample below it.
- iZotope: any sample beyond the dB threshold.
- A run length rule: an Audio Expert System page (Frontline, a Bluetooth analyzer, search extract only) says a clipping event fires after a set number of consecutive samples at maximum. An Ardour feature request proposes 3 consecutive samples at 0 dBFS. Neither is an authority for audio editors. Inference: use 3 samples.

Does the repair lower the level first? Yes in Audition (Gain is an attenuation before processing; Auto available) and in Audacity (-9 dB default for the whole selection). iZotope instead adds Makeup Gain and a Post-Limiter. Reason (Audacity manual): the rebuilt peaks go above the old maximum and need headroom.

## F100 Soften harsh "s" (de-ess)

| App | Control | Default | Range | What the user sees |
|---|---|---|---|---|
| Audition, Essential Sound (Dialogue, Repair) | DeEss checkbox and slider | Not documented | 0 to 10 | "Reduces harsh, high-frequency ess-like sounds." |
| Audition, DeEsser effect (Effects > Amplitude and Compression) | Threshold | Not confirmed | dB | Amplitude above which compression starts. |
| Audition, DeEsser | Center Frequency | Not confirmed | Hz | "The point where sibilance is strongest". Adjust while playing. The graph handles drag Center Frequency and Bandwidth. A tutorial suggests 7000 to 8000 Hz; not from Adobe. |
| Audition, DeEsser | Bandwidth | Not confirmed | Hz | Frequency range that triggers the compressor. A tutorial suggests about 1 to 2 kHz; not from Adobe. |
| Audition, DeEsser | Output Sibilance Only | Off | on/off | Listen to the detected band. The label is "Output Sibilance Only" in most tutorials. The extract I saw did not describe it. |
| Audition, DeEsser | Gain Reduction readout; Mode | Not confirmed | Broadband or Multiband | Broadband compresses all frequencies. Multiband compresses only the sibilance range. Adobe: Multiband suits most audio and costs a little more processing time. |
| Audition, DeEsser presets | Presets for low/male and high/female voices | Not confirmed | n/a | Values not found. |
| Hindenburg PRO | None found | n/a | n/a | First-party feature pages list Noise Reduction, Voice Profiler, Compression, EQ, VST and AU. No de-esser is listed. One 2026 third-party review (creatorstackclub.com, not opened) was said to list one. It is unverified. |
| SoundCraft, `de_esser` (`crates/dsp/src/plugins/dynamics.rs`, `DEESS_PARAMS`) | Freq; Range; Threshold; Listen | 6000 Hz; 10 dB; -30 dB; off | 2000 to 16000 Hz (log); 0 to 40 dB; -60 to 0 dB; toggle | Four controls. Listen plays the detector band only. The effect is listed as an AudioSuite (offline) process. |
| SoundCraft, algorithm | Dynamic EQ, not split-band | n/a | n/a | A Butterworth high-pass (Q 0.707) at Freq feeds a peak detector: the loudest channel, absolute value, with attack 0.5 ms and release 60 ms (fixed). Every 16 samples: gain reduction = (detector dB - Threshold), clamped to 0 .. Range. A high shelf at 0.8 times Freq (Q 0.8, gain = minus the gain reduction) cuts the signal. With zero reduction the shelf is the identity, so the signal is untouched. Channels share one gain (stereo link). Inference: the threshold is absolute dBFS of the high-passed peak. It does not follow speech level. |
| Apple Logic Pro, DeEsser 2 | Frequency, Threshold, Max Reduction, Mode (Relative or Absolute), Range (Split or Wide), Filter (shelf or peak), Filter Solo | Not documented | Not documented | Relative mode "is highly responsive" and works at high and low levels. Absolute mode works like a classic de-esser. Filter Solo plays the detection band. |
| iZotope RX De-ess (RX 9 docs) | Mode (Classic, Spectral), Threshold, Cutoff, Spectral Flattening, Spectral Tilt, Spectral Shaping, Speed | Relative threshold is the default; others not stated | Flattening 0 to 100 percent; others not stated | Classic: broadband gain envelope. Spectral: cuts only the high bands where sibilance is active. Threshold in dB, relative to speech level or absolute in dBFS. Cutoff is the lower boundary for sibilance detection. Speed: Fast or Slow. |
| Audacity | No bundled de-esser | n/a | n/a | The source tree `share/nyquist-plug-ins` has no de-esser. Forum posts name add-on Nyquist plugins (De-Esser, "Desibilator"); they work per band and act as a multiband compressor (a forum user calls it that). The manual page for Filter Curve EQ does not mention sibilance. A user can cut with an EQ, but a forum user reports it makes the voice dull. |
| Auphonic | Voice AutoEQ | n/a | n/a | The API names a de-esser inside "autoeq". The algorithm page does not mention a de-esser. |
| Descript Studio Sound | None | n/a | n/a | No de-ess part is documented. |

Sibilance band (Apple Logic Pro support, "Reduce sibilance in Logic Pro"): female voices 5 to 8 kHz, male voices 3 to 6 kHz. Other sources (secondary, from search extracts) give 2 to 10 kHz overall and 4 to 10 kHz (Antares). Most guides say to find the exact value by listening to the detector band.

## Recommended defaults for the plan

| Effect | Control | Default | Range | Source |
|---|---|---|---|---|
| F98 | Cutoff | 80 Hz | 20 to 300 Hz (Inference) | Adobe Essential Sound; SoundCraft |
| F98 | Slope | 12 dB/oct | 6, 12, 18, 24 | SoundCraft |
| F99 | Clip threshold | 95 percent of the clip peak | 0 to 100 percent | Audacity |
| F99 | Reduce level | -9 dB | -30 to 0 dB | Audacity |
| F99 | Method | Cubic spline | Cubic only (FFT is out of scope) | Audacity, Audition |
| F100 | Frequency | 6000 Hz | 2000 to 16000 Hz | SoundCraft; Apple bands |
| F100 | Threshold | -30 dB | -60 to 0 dB | SoundCraft |
| F100 | Range (max reduction) | 10 dB | 0 to 40 dB | SoundCraft |
| F100 | Listen | Off | on/off | SoundCraft, Apple, Audition |

SoundCraft is MIT OR Apache-2.0 (see `LICENSE-MIT`, `LICENSE-APACHE`, `NOTICE`). A code copy needs the notices. Audacity is GPL: this file names ideas and identifiers only, with no code copy.

## Open questions

1. No Audition default or range was read on the Adobe pages (HTTP 403). Needed: Gain, Tolerance, Min. Clip Size, FFT Size, and the DeEsser Threshold, Center Frequency, and Bandwidth defaults, and the Essential Sound slider-to-Hz map. Resolve: open Audition, or fetch the pages by another route.
2. Inference: a Hz cutoff plus a slope is a better F98 control than a 0 to 10 slider. The Audition slider map is unknown. Case not checked: a user who wants only "less rumble" with no numbers.
3. Inference: a run of 3 samples is the minimum clip. Audition's Min. Clip Size default is unknown. Check with a clip that has isolated single-sample peaks.
4. Inference: 95 percent of the clip peak copies Audacity. Audition's Tolerance works on the maximum amplitude, and one tutorial says it misses clips below 0 dBFS. Audacity uses the selection peak, so it can catch a clip that was normalized down. Check with a normalized clipped file.
5. Does Dirigible write float WAV? If yes, the -9 dB "reduce level" is optional, because float samples can go over full scale. If it writes 16 or 24 bit PCM, the render must lower the level or limit the peaks (iZotope uses a post-limiter).
6. Inference: SoundCraft's absolute -30 dB threshold on the high-passed peak depends on the clip level. Apple and iZotope offer a relative mode. Check with a quiet clip and a loud clip of the same voice.
7. Not confirmed: Logic Channel EQ slope list; Hindenburg current EQ controls (the staff reply is from 2015); whether Hindenburg has a de-esser (one unopened review says yes); the Frontline "Clipping Event" page (redirect, search extract only).
8. Hindenburg manual pages for EQ and effects did not load. The `Hindenburg_Journalist.pdf` handout (willyurman.com) is an image-based PDF and gave no text.

## Sources

Adobe (all HTTP 403 to WebFetch; text from search extracts):

- https://helpx.adobe.com/audition/using/diagnostics-effects-waveform-editor-only.html (DeClipper, Diagnostics panel)
- https://helpx.adobe.com/audition/using/amplitude-compression-effects.html (DeEsser)
- https://helpx.adobe.com/audition/using/essential-sound-panel.html and https://helpx.adobe.com/audition/desktop/editing-audio-files/essential-sound-panel.html (Reduce Rumble, DeEss)
- https://helpx.adobe.com/audition/using/filter-equalizer-effects.html (FFT Filter, Parametric EQ, Scientific Filter)
- Third-party Audition guides: https://borisfx.com/blog/how-to-fix-clipped-audio-in-adobe-audition/ , https://www.adventistlearningcommunity.net/alcwiki/how-to-fix-clipped-audio-in-audition/ , https://larryjordan.com/articles/adobe-audition-fix-clipped-audio-i-e-skype/ , https://producer.musicradiocreative.com/how-to-use-adobe-audition-deesser/

Hindenburg:

- https://hindenburg.com/academy/features/features-hindenburg-pro/
- https://hindenburg.com/products/radio-podcast/features/
- https://hindenburg.com/academy/lessons/feature-highlights/
- https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- https://hindenburg.com/support/release-notes/hindenburg-series/
- https://hindenburg.uservoice.com/forums/224350-general/suggestions/10529784-more-powerful-eq-compressor-tools (staff reply, 2015)
- https://hindenburg.uservoice.com/knowledgebase/articles/820623-help-how-do-i-make-my-voice-track-sound-good
- https://hindenburg.uservoice.com/knowledgebase/articles/629317-does-hindenburg-a-noise-reduction-tool
- https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough (secondary)

SoundCraft (repo `storytold/soundcraft`, tarball read on 2026-10-27):

- `crates/dsp/src/plugins/dynamics.rs` (`DEESS_PARAMS`, `DeEsser`)
- `crates/dsp/src/plugins/eq.rs` (`EQ7_PARAMS`, `SLOPES`, `pass_filter`), `strip.rs`, `crates/dsp/src/biquad.rs`
- `crates/engine/src/cmd/audiosuite.rs` (offline process by clip)
- `docs/plugin-parity.md`, `docs/parity-checklist.md`, `README.md`, `ROADMAP.md`

Audacity (ideas only):

- https://manual.audacityteam.org/man/clip_fix.html
- https://manual.audacityteam.org/man/high_pass_filter.html
- https://manual.audacityteam.org/man/filter_curve_eq.html
- https://github.com/audacity/audacity : `share/nyquist-plug-ins/clipfix.ny`, `share/nyquist-plug-ins/highpass.ny`, `au3/libraries/au3-math/Biquad.cpp`
- https://forum.audacityteam.org/t/updated-de-clicker-and-new-de-esser-for-speech/34283 and related threads (search extracts)

Other:

- https://downloads.izotope.com/docs/rx6/22-de-clip/index.html
- https://s3.amazonaws.com/izotopedownloads/docs/rx9/en/de-ess/index.html
- https://support.apple.com/guide/final-cut-pro-logic-effects/deesser-2-controls-lgex1eda7296/mac
- https://support.apple.com/en-in/102006 (Reduce sibilance in Logic Pro)
- https://support.apple.com/guide/logicpro/channel-eq-parameters-lgcef1edc1d7/mac (search extract only)
- https://auphonic.com/help/algorithms/singletrack.html
- https://help.descript.com/hc/en-us/articles/10327603613837 (search extract only)
- https://fte.com/WebHelpII/AES/Content/Documentation/AudioExpertSystemReferenceGuide/ClippingEventRM.htm (search extract only)
- https://tracker.ardour.org/view.php?id=2782 (search extract only)
