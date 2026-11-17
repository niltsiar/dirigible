# Voice match: EQ of a voice to a reference voice (F37)

Date: 2026-11-16

Scope: how other apps match the tone of one voice to a reference voice, and the DSP and Apple framework facts for a match filter. Two research passes, of 2026-10-14 and 2026-11-16, are merged here. No build or probe ran for this file. "Inference:" marks a claim with no owner source. Numbers in brackets point to `## Sources`. Decision 0074 holds the design that this research supports.

How the quotes were read: the fetch tool returns short quotes from each page, so a quote can differ from its page by a few words. Apple Support pages for the current Logic Pro return only menu text. The Logic facts come from older Apple pages with the same text [16] [17], and from search snippets [18]. Adobe Help pages return HTTP 403, so the Adobe facts come from search snippets. Each such case is marked.

## 1. Hindenburg PRO Voice Profiler

- **Name.** The PRO 2 pages use "Voice Profile" and "Voice Profiler", not "Auto EQ": "Voice Profiler automatically adds equalisation based on samples of great radio voices." [1]
- **What.** "By taking a 'Snap shot' of an optimal sounding narration, the voice profiler will set an unique EQ" [38] p. 48. The Journalist 1.21 guide lists "Auto EQ" and "Compression" [38]. Transom says the profile can "automatically make EQ and compression settings" [5]. The vendor page says equalisation only [1]. Inference: EQ is the profile, and compression is a separate effect of the track.
- **Manual.** No PRO 2 manual page covers the feature. The support page lists no manual [2]. The guide page has three video entries with no text: "Tracks - Voice Profile - Learn Profile" ("Create a Profile from the current Tracks audio"), "Apply Generic Profile", and "Apply Personal Profile" [3].
- **Product.** "Voice Profile Individual: Apply Voice Profile. Learn Voice Profile." is "Yes" for PRO, Narrator, and Narrator Studio [4].
- **Learn source.** "The Voice Profiler will analyze the entire track, so only have the voice sample on the track" [38] p. 49. Transom: "Make sure to only have one voice on the track." [5] No source names a selection or a clip as the learn source, a minimum length, or a silence gate.
- **Storage.** "Save your Voice profile in Hindenburg / Profiles" [38] p. 49. Inference: a file library, not a track property.
- **Apply and scope.** Per track, from the small triangle beside the effects button: Apply Profile, select, OK [38] p. 50 [5] [39]. Effects "are applied to the entire track" [38] p. 45. Every Voice Profile shortcut is under "Tracks" [7]. Release note 2550: "Split by Speaker" can "be used to apply Voice Profile, Compression, Noise Reduction and Auto Levels to individual tracks." [8] Inference: the user splits a clip to a new track to get a clip scope.
- **Live and off.** Transom (2017): "you can just turn it off!" [5]. "Edit freely. Revisit decisions." [6] Inference: a live, non-destructive effect of the track.
- **Controls.** No amount, strength, or intensity control in any source [1] [3] [4] [7] [38]. The user can drag "the blue line [that] indicates what frequencies are being boosted or cut" [5].
- **Generic profile.** "based on a number of radio talent voices" [38] p. 51 [3]. Do not use a personal profile on other audio [38] p. 51.
- **Version.** PRO V2_05 Build 2726, 2 February 2026 (search snippet of [8]).

## 2. iZotope: Dialogue Match, RX EQ Match, Ozone Match EQ

- **Dialogue Match** (documentation 1.2.0). "automatically matches the EQ, reverb, and ambience" [9], with the modules EQ (Amount), Reverb (Wet, Dry), and Ambience (Trim) [10]. It is a Pro Tools AudioSuite plug-in: the user previews and changes settings "in real-time while previewing", then clicks Render [10]. Learn: "Select a dialogue clip of any length and learn the Reference clip", at best "at least 3 seconds long" [10]. No latency is documented. It is a separate product: release note 8.6.3 (24 September 2025) "Removes Dialogue Match 1.3.0 from the PPS installer." [11]
- **RX EQ Match** (RX Advanced). Select, Learn, select another range, Process [13]. "Instantly capture a spectral profile with the offline Learn feature, then apply it to your target audio by selecting Render." (search snippet of [12]). A learned spectrum saves as a preset. One control, Amount: "100% match could sound unnatural ... 10-40% do enough" [13].
- **Ozone Match EQ.** "a digital linear-phase EQ with the ability to use over 8,000 bands" [14] [44]. Reference and Apply To snapshots are captured during playback [14]. Controls: Amount ("the amount of processing (intensity)"), Smoothing, and lower and upper range bounds, flat outside [14]. "We suggest working with the Matched Curve amount under 50%" [45]. Ozone 11 lists the controls of Ozone 9 and no phase mode for Match EQ. The Phase control of the Ozone 11 Equalizer (0 % linear, 100 % minimum) does not cover Match EQ [15]. Not documented: FFT size, gate, largest boost or cut, output gain, latency. Inference: Match EQ runs live in the host.

## 3. Logic Pro Match EQ and GarageBand

- **Method.** "The average frequency spectrum of the source file (the template) and of the current material ... is analyzed. These two spectra are then matched, creating a filter curve" [19]. It does not match dynamics [19].
- **Learn source.** Playback, a file, or a channel strip, not a region. "You can drag an audio file to the Current or Reference Learn buttons ... A progress bar appears while Match EQ is analyzing the file." (search snippet of [18]). Logic 9.1.6: "Choose the channel strip that you want to match from the Sidechain menu" [17].
- **Apply.** "By default, the Apply slider is set to 100% when you learn the frequency curve" [17]. Over 100 % strengthens the curve, under 100 % weakens it, and negative values invert it [16].
- **Other controls** [19]: Smoothing ("using a constant bandwidth set in semitone steps"; it does not change manual edits [16]), Gain offset, Ease-In and Ease-Out (0 dB outside two handles), Limit Boost and Limit Cut (no published default), Channel Link, Analyzer, and manual curve edits.
- **Phase modes.** Linear: "Prevents processing from altering the signal phase, but latency is higher." Minimal: "Alters the signal phase (slightly), but latency is reduced." Minimal, Zero Latency: "Adds no latency, but has a higher CPU overhead than the other options." [16] No page gives the latency or the FIR size.
- **Live.** A plug-in in an Audio FX slot: "Click an Audio Effect slot, then choose a plug-in from the pop-up menu." [20] Inference: it runs live.
- **GarageBand for Mac.** The guide describes only the Smart Controls EQ [21]. A search of the guide found no Match EQ. Inference: GarageBand has no match EQ.

## 4. Adobe: Audition, Premiere Pro, Podcast

- **Audition.** No spectral EQ match: the Filter and EQ effects (FFT Filter, Graphic, Notch, Parametric, Scientific) have none [42]. Users route to iZotope Ozone [43]. Match Loudness matches BS.1770 loudness only [41]. Essential Sound "Auto-Match" adds a non-destructive gain to each dialogue clip, with a badge [40].
- **Premiere Pro, Enhance Speech.** The slider "allows you to mix your raw audio with the enhanced audio", and it runs "locally on your machine" [23]. The scale of 1 to 10, default 7, comes only from user posts.
- **Adobe Podcast, Enhance Speech.** "you can adjust the intensity to your desired level"; "Keeping Enhance Speech at 100% can make the recording sound unnaturally perfect." [22] No reference voice.
- Inference: no Adobe app matches the EQ of a voice to a reference voice.

## 5. Descript

- **Studio Sound.** One Intensity slider. It "is applied at the file level" and "requires an internet connection" [24]; "it's applied directly to the original media file" [25]. Inference: a cloud render of the file.
- **Effects.** 14 audio effects, among them a 5-band parametric EQ, on media layers or sequence tracks [25] [26] [27]. No help page names a match, auto EQ, or voice match feature [24] [25] [26].

## 6. Auphonic

- **Voice AutoEQ.** "spectral EQ profiles are created for each speaker separately and permanently changing over time" [28]; "every voice has its unique frequency spectrum and needs its own equalization" [29]. It de-esses and reduces plosives [30].
- No reference or target curve and no amount control. The method is chosen "for the whole production or track" [29] [31]. Inference: an offline production step with no live preview.

## 7. Final Cut Pro: Match Audio

- **What.** "The Match Audio function uses equalization (EQ) to let you match a selected clip's sound to that of another clip." (Final Cut Pro 12.4) [32]. "This feature does not match LEVELS, it matches sound QUALITY." (secondary) [33]
- **Where.** Modify > Match Audio (Shift-Command-M), the Equalization pop-up menu of Audio Enhancements in the Audio inspector, or the Enhancements pop-up menu below the viewer. Select the clip, start the match, select the clip to match, "Click Apply Match" [32].
- **Adjust or remove.** Adjust in Audio Enhancements; remove with "the Flat setting" [32] [33]. No Amount slider for Match Audio. Loudness, Noise Removal, and Voice Isolation have Amount sliders and a checkbox that turns each off [34].
- **Match EQ** (the Logic effect in Final Cut Pro) is a second tool: Reference Learn from a file, Current Learn, EQ Curve Match, then "lower the Apply slider from its default 100%" [35].

## 8. Where apps put a track or clip effect

- **Logic Pro.** Plug-in slots of the channel strip [20]. The Region inspector has Gain (-30 to +30 dB) and Delay, and no Match EQ (search snippet of [36]).
- **GarageBand for Mac.** Up to four plug-in slots for each patch, each with a Power button [37]; the Smart Controls EQ on a track or the master track [21].
- **Final Cut Pro.** The Audio Enhancements section of the Audio inspector, for each clip, with a checkbox and a pop-up menu or a slider for each enhancement [34].
- **Hindenburg PRO.** The triangle beside the effects button of the track header, and the menu path "Tracks - Voice Profile" [5] [7].

## 9. soundcraft and Audacity

- soundcraft is "MIT OR Apache-2.0" and has no EQ match [46]. `crates/dsp/src/spectrum.rs` takes one Hann FFT frame with no average; `crates/dsp/src/biquad.rs` has RBJ biquads; `crates/dsp/src/plugins/eq.rs` has 7-band and 1-band EQ [46].
- Audacity (GPL, read for the approach only) has no native match; forum users import a spectrum difference as a curve [48]. Filter Curve EQ samples the curve on a 16,384-point grid, runs an inverse FFT, applies a Blackman window to `FilterLength` taps (default 8,191), and filters by FFT overlap-add [47].

## 10. The DSP approach

- **Long-term spectrum.** Welch's method averages windowed periodograms [49], with about 50 % overlap for Hann [50]. Byrne measured the long-term speech spectrum of 12 languages in one-third-octave bands [51]. No vendor documents a gate. BS.1770 has one: 400 ms blocks, 75 % overlap, -70 LUFS absolute, -10 LU relative [59]. Inference: an FFT of 8,192 points at 48 kHz gives bins of 5.9 Hz, and the 63 Hz one-third-octave band is about 14.6 Hz wide.
- **Smoothing.** Fractional-octave smoothing [52]. Inference: power sums in 25 one-third-octave bands at the nominal centers (63 Hz to 16 kHz) [51] do the same job.
- **Curve.** No vendor publishes a default clamp [19]. Ozone [14] and Logic [19] make the curve flat outside a range. Logic has a gain offset [19]; Ozone and RX document no output gain.
- **Filter forms.**

| Form | Accuracy | Cost | Used by |
|---|---|---|---|
| `AVAudioUnitEQ` bands | Bands interact; under 1 dB of error needs an interaction fit [58] | Low; runs live | Inference: Hindenburg [5] |
| Linear-phase FIR by frequency sampling and a window | It "deviates ... between the samples" [53] | FFT convolution wins from length 128 [55]; pad N to L + M - 1 or more [57]; delay (M - 1) / 2; audible pre-ring on clicks [56] | Ozone [14], Logic Linear [16], Audacity [47] |
| Minimum-phase FIR | The same magnitude; fold the cepstrum [54] | As the linear-phase FIR, with no delay | Logic Minimal [16] |

## 11. Apple frameworks

- `vDSP.FFT`, `vDSP.DFT`, `vDSP.Biquad` [60] [61] [64]; `vDSP_DFT_zrop_CreateSetup` [62]; `vDSP.DCT` and a DCT EQ sample [65]; `vDSP_conv` [63] (Inference: a direct sum, O(N x M)).
- `AVAudioUnitEQ(numberOfBands:)`: `bandwidth` 0.05 to 5.0 octaves, `gain` and `globalGain` -96 to +24 dB [66] [67]. `kAUNBandEQProperty_MaxNumberOfBands` (2201) is a run-time query [67].
- `kAudioUnitSubType_GraphicEQ`: "A 10 or 31 band Graphic EQ". `AUComponent.h` has no FIR or convolution unit [67].
- The repo has the BS.1770 gates in `LoudnessMeter` and the true-peak meter in `TruePeak` [68].

## Best option

| App | Live | Amount | Learn source | Latency | Matches |
|---|---|---|---|---|---|
| Logic Pro Match EQ | Plug-in in a slot (Inference) | Apply, default 100 %, under and over | Playback, file, or channel strip | Three phase modes, one with zero latency | EQ only |
| Ozone Match EQ | Plug-in (Inference) | Amount, Smoothing, two bounds | Playback snapshots | Not documented | EQ only |
| Hindenburg PRO Voice Profiler | Yes, can be turned off | None documented | Whole track | Not documented | EQ (maybe compression) |
| Final Cut Pro Match Audio | Inspector setting (Inference) | None documented | Another clip | Not documented | EQ only |
| RX EQ Match | Offline | Amount | Selection | Not applicable | EQ only |
| Dialogue Match | Preview, then render | Amount for each module | Clip, 3 s or more | Not documented | EQ, reverb, ambience |
| Auphonic Voice AutoEQ | Offline | None | None (automatic for each speaker) | Not applicable | EQ, de-ess, plosives |
| Adobe, Descript | No match feature | Intensity of denoise only | Not applicable | Not applicable | Not applicable |

- **Best controls: Logic Pro Match EQ.** A live plug-in with Apply, Smoothing, Ease and Limit controls, a zero-latency phase mode, and three learn paths. Ozone Match EQ has equal controls, but no documented latency and no zero-latency mode.
- **Best podcast flow: Hindenburg PRO Voice Profiler.** One learn step on a track, one apply step on another track, and an off switch. It has no amount control, learns from a whole track only, and applies to a whole track only.
- **To match or beat the best option** (Inference): a live stage that the user can turn off; an amount control (iZotope advises under 50 % [13] [45], Logic starts at 100 % [17]); a learn source that can be a clip or a selection; and a stated latency.
- **Dialogue Match** also matches reverb and ambience, but it is an offline render in Pro Tools only.

## Not checked

- Hindenburg PRO 2: no manual text, and the three video pages have no text. The compression part, the amount control, and the clip scope are unconfirmed. The date of build 2726 is from a search snippet.
- iZotope RX 11 docs return HTTP 403, and several izotope.com pages return HTTP 429. The RX 11 EQ Match text is from a search snippet.
- Logic Pro: the current guide pages return only menu text. The latency of each phase mode is not published.
- GarageBand for Mac: no full plug-in list was read. "No Match EQ" is an absence of results.
- Adobe Help returns HTTP 403. The Premiere Enhance Speech slider scale is from user posts. Adobe Podcast cloud processing is not stated.
- Descript "cloud render" is an inference from "requires an internet connection". Auphonic "offline" is an inference.
- Final Cut Pro Match Audio: live or rendered, and a fixed or adjustable curve, are not stated. The Match EQ text for Final Cut Pro is a tool paraphrase.
- IEC 61260 and the body of the Byrne paper.

## Sources

1. Hindenburg features, Voice Profile: https://hindenburg.com/hindenburg-pro-features/sharing/
2. Hindenburg support page: https://hindenburg.com/support/
3. Hindenburg PRO guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
4. Hindenburg comparison: https://hindenburg.com/products/radio-podcast/comparison/
5. Transom, Basic EQ in Hindenburg (2017): https://transom.org/2017/basic-eq-hindenburg/
6. Hindenburg PRO features: https://hindenburg.com/products/radio-podcast/features/
7. Hindenburg PRO shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
8. Hindenburg PRO V2 Build 2550: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_build-2550/ ; index: https://hindenburg.com/support/release-notes/hindenburg-series/
9. Dialogue Match documentation index: https://docs.izotope.com/dialogue-match/en/index.html
10. Dialogue Match documentation (print): https://s3.amazonaws.com/izotopedownloads/docs/dialogue-match/en/print/index.html
11. RX Post Production Suite release notes: https://www.izotope.com/pages/release-notes/rx-post-production-suite
12. RX EQ Match pages (search snippets; HTTP 429 on fetch): https://izotope.com/en/products/repair-and-edit/rx/features-and-comparison/eq-match.html and https://www.izotope.com/en/products/rx/features/eq-match.html
13. RX 9 EQ Match: https://s3.amazonaws.com/izotopedownloads/docs/rx9/en/eq-match/index.html
14. Ozone 11 Match EQ: https://docs.izotope.com/ozone11/en/match-eq/index.html
15. Ozone 11 Equalizer: https://docs.izotope.com/ozone11/en/equalizer/index.html
16. Match EQ controls in Final Cut Pro (Logic effects, 10.4.7): https://support.apple.com/en-ie/guide/final-cut-pro-logic-effects/lgexea5c83f0/10.4.7/mac/10.14
17. Logic Pro 9.1.6 Match EQ: https://help.apple.com/logicpro/mac/9.1.6/help/English.lproj/en/logicpro/effects/chapter_5_section_5.html
18. Use Match EQ in Logic Pro: https://support.apple.com/guide/logicpro/use-match-eq-lgcef1edc5c5/mac
19. Match EQ overview and parameters: https://support.apple.com/guide/logicpro/match-eq-overview-lgcef1edbfbe/mac and https://support.apple.com/guide/logicpro/match-eq-parameters-lgcef1edbd51/mac
20. Add, remove, move, and copy plug-ins in Logic Pro: https://support.apple.com/guide/logicpro/add-remove-move-and-copy-plug-ins-lgcpbc218a22/mac
21. GarageBand EQ: https://support.apple.com/en-au/guide/garageband/gbnd56ab9fca/10.4/mac/11.0
22. Adobe Podcast guide: https://podcast.adobe.com/guides/how-enhance-speech-can-improve-your-recording-sound-quality
23. Adobe community, Enhance Speech in Premiere Pro: https://community.adobe.com/announcements-732/now-released-enhance-speech-in-premiere-pro-313485
24. Descript Studio Sound: https://help.descript.com/effects-animations-transitions/studio-sound.md
25. Descript effects overview: https://help.descript.com/effects-animations-transitions/overview.md
26. Descript EQ: https://help.descript.com/effects-animations-transitions/eq.md
27. Descript blog, Studio Sound and effects: https://www.descript.com/blog/article/new-in-descript-studio-sound-overdub-model-pro-audio-effects-and-more
28. Auphonic AutoEQ beta: https://auphonic.com/blog/2023/01/24/autoeq-beta/
29. Auphonic single-track algorithms: https://auphonic.com/help/algorithms/singletrack.html
30. Auphonic filtering: https://auphonic.com/features/filtering
31. Auphonic multitrack: https://auphonic.com/help/web/multitrack.html
32. Match audio in Final Cut Pro: https://support.apple.com/guide/final-cut-pro/ver1632db40/mac
33. Larry Jordan, FCP X Match Audio (secondary): https://larryjordan.com/articles/fcpx-match-audio/
34. Enhance audio in Final Cut Pro: https://support.apple.com/guide/final-cut-pro/verc1fab873/mac
35. Use Match EQ in Final Cut Pro (10.4.7): https://support.apple.com/en-ie/guide/final-cut-pro-logic-effects/lgexc92bbe42/10.4.7/mac/10.14
36. Logic Pro audio region parameters: https://support.apple.com/guide/logicpro/audio-region-parameters-lgcpf7c0af60/mac
37. GarageBand plug-ins: https://support.apple.com/guide/garageband/add-and-edit-effect-plug-ins-gbndac55f7f8/10.4/mac/11.0
38. Hindenburg Journalist 1.21 guide: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
39. Buzzsprout, Hindenburg Journalist review (2020): https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough
40. Adobe Essential Sound: https://helpx.adobe.com/audition/kb/editing-using-essential-sound-panel-audition.html
41. Adobe Match Loudness: https://helpx.adobe.com/audition/using/match-loudness.html
42. Adobe Filter and EQ effects: https://helpx.adobe.com/ca/audition/desktop/effects-reference/filter-equalizer-effects.html
43. Adobe community, Ozone in Audition: https://community.adobe.com/t5/audition-discussions/how-do-i-get-the-right-signal-into-a-plug-in-izotope-ozone/m-p/10069859
44. Ozone 9 Match EQ: https://s3.amazonaws.com/izotopedownloads/docs/ozone9/en/match-eq/index.html
45. Ozone 8 Equalizer: https://downloads.izotope.com/docs/ozone8/equalizer/index.html
46. soundcraft: https://github.com/storytold/soundcraft
47. Audacity built-in effects: https://github.com/audacity/audacity/tree/master/au3/libraries/au3-builtin-effects
48. Audacity forum, spectral matching: https://forum.audacityteam.org/t/is-spectral-matching-for-automatic-eq-adjustment-possible-in-audacity/106331
49. Welch 1967: https://doi.org/10.1109/TAU.1967.1161901
50. Smith, Welch's method with windows: https://ccrma.stanford.edu/~jos/sasp/Welch_s_Method_Windows.html
51. Byrne et al. 1994: https://doi.org/10.1121/1.410152
52. Hatziantoniou and Mourjopoulos 2000: https://aes2.org/publications/elibrary-page/?id=12070
53. Smith, frequency sampling: https://ccrma.stanford.edu/~jos/sasp/Frequency_Sampling_Method_FIR.html
54. Smith, minimum-phase cepstra: https://ccrma.stanford.edu/~jos/sasp/Minimum_Phase_Causal_Cepstra.html
55. Smith, FFT against direct convolution: https://ccrma.stanford.edu/~jos/ReviewFourier/FFT_Convolution_vs_Direct.html
56. Smith, linear phase: https://ccrma.stanford.edu/~jos/filters/Linear_Phase_Really_Ideal.html
57. Smith, acyclic FFT convolution: https://ccrma.stanford.edu/~jos/sasp/Acyclic_FFT_Convolution.html
58. Liski and Valimaki, DAFx 2017: https://dafx.de/paper-archive/details/Ycir51R86FWcfPNqrjV2kQ
59. ITU-R BS.1770: https://www.itu.int/rec/R-REC-BS.1770
60. vDSP.FFT: https://developer.apple.com/documentation/accelerate/vdsp/fft
61. vDSP.DFT: https://developer.apple.com/documentation/accelerate/vdsp/dft
62. vDSP_DFT_zrop_CreateSetup: https://developer.apple.com/documentation/accelerate/vdsp_dft_zrop_createsetup
63. vDSP_conv: https://developer.apple.com/documentation/accelerate/vdsp_conv
64. vDSP.Biquad: https://developer.apple.com/documentation/accelerate/vdsp/biquad
65. DCT EQ sample: https://developer.apple.com/documentation/accelerate/equalizing-audio-with-discrete-cosine-transforms-dcts
66. AVAudioUnitEQ: https://developer.apple.com/documentation/avfaudio/avaudiouniteq
67. macOS SDK headers: AUComponent.h, AudioUnitProperties.h, AVAudioUnitEQ.h
68. Repo: `Sources/DirigibleAudio/DSP/LoudnessMeter.swift`, `Sources/DirigibleAudio/DSP/TruePeak.swift`
