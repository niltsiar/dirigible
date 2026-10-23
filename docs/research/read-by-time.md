# Research: read-by-time (silence list, nearest pause, level and loudness of a range)

Date: 2026-10-23

Scope: reference behavior of other tools and standards. "Unconfirmed" means that no primary source was read. Probes P1 and P2: local runs of ffmpeg 9.0.1 on generated tones only.

## A. ffmpeg (primary: filter docs, libavfilter source, local probe)

1. `silencedetect` options (doc, source, `ffmpeg -h filter=silencedetect`): `noise`/`n` default 0.001 (linear amplitude, "-60dB"); a "dB" suffix is accepted. `duration`/`d` default 2 s. `mono`/`m` default off. [S1, S2, P1]
2. Per-sample test, no window and no RMS: a sample is silent when `-noise < x < noise` (strict). A sample at exactly the threshold is not silent. [S2: `update(..., *p < noise && *p > -noise, ...)`]
3. Default mode: one counter over all channels. Silence needs every channel quiet. `mono=1`: one counter per channel. [S2] Probe: stereo file, L silent, R tone, `n=-50dB:d=0.5`. Default mode prints nothing. `mono=1` prints `channel: 0 | silence_start: 0` and `channel: 0 | silence_end: 2 | silence_duration: 2`. The log channel is 0-based. The metadata key is 1-based (`lavfi.silence_start.1`). [P2]
4. Start time is back-dated to the first quiet sample of the run. Probe: tone 0-3 s, silence 3-4 s, `n=-60dB:d=0.5`: `silence_start: 3`, `silence_end: 4.000021 | silence_duration: 1.000021`. A silence at end of file is closed at the end of the stream and logged (`silence_end: 9.5`). The source (`uninit()`) closes the open silence with the stream end and sets no metadata for it. [P1, S2]
5. Probe: a 1 kHz sine at -18 dBFS peak, `n=-30dB`, `d=0.0001`, gives no false silence. Inference: a sine with peak above the threshold is quiet near each zero crossing for less than 0.1 ms, so any `d` of a few ms or more is safe for tonal signals. Real speech was not probed.
6. `silencedetect` has no pad, no hysteresis, and no range option (option table, S4). A range needs a trim before the filter.
7. `ebur128` summary (source `uninit()`, probe): printed lines are `I` (LUFS), `Threshold` (LUFS, relative gate of I), `LRA` (LU), `Threshold` (LUFS, gate of LRA), `LRA low`, `LRA high` (LUFS). `Sample peak` and `True peak` (dBFS) appear only with `peak=sample|true`. One decimal. [S3, S4, P1] Summary has no max momentary and no max short-term.
8. Per-frame log (every 100 ms): `t:  TARGET:-23 LUFS  M:  S:  I:  LRA:`. `M` = momentary, 400 ms window. `S` = short-term, 3 s window. Both are ungated. [S3, S4] Probe: M is -120.7 for the first 300 ms and S is -120.7 until 3 s. -120.7 is the floor value for "no window yet" or digital silence.
9. LRA in the source: absolute gate `ABS_THRES -70`, relative gate `LRA_GATE_THRES -20`, percentiles 10 and 95. Integrated: 400 ms blocks, 75% overlap, relative gate `I_GATE_THRES -10`. [S3]
10. Probe: a 2 s tone gives `I -27.1`, `LRA 0.0`, and gate/low/high all `0.0`. That is the "no valid short-term value" output. Probe: 1 kHz stereo sine, -18 dBFS peak, 5 s: `I -18.1 LUFS`, `True peak -18.1 dBFS`, `LRA 0.0`. A mono file reads 3.01 LU lower than the same stereo (-21.1) unless `dualmono=1`. [P1, P2, S3]
11. `ebur128` converts to double and has `target` default -23, `panlaw` default -3.01 dB. The docs give -16 LUFS as a podcast example target. [S2b]

## B. EBU documents (primary: PDFs read locally)

12. Tech 3342 (v4, Nov 2023): input is a vector of 3 s sliding-window loudness values from BS.1770 without the -10 LU gate. The rate is at least 10 Hz (overlap at least 2.9 s). Gates: absolute -70 LUFS, then relative = power mean of the abs-gated values minus 20 LU. LRA = percentile 95 minus percentile 10 of the values above both gates. The MATLAB code uses `round((n-1)*p/100 + 1)` on the sorted vector. [S5]
13. Tech 3342 sets no minimum signal length. It warns that very short programmes, leading or trailing silence, and isolated utterances can give "misleadingly high" LRA. The MATLAB comment says a file-based measurement should end with at least 1.5 s of silence (analysis latency). [S5]
14. Tech 3341 (2023): Momentary = 0.4 s rectangular window, not gated. Short-term = 3 s window. Integrated = BS.1770 gating (-70 absolute, -10 LU relative, 400 ms blocks, 75% overlap; the incomplete last block is dropped). During the first 60 s of an LRA measurement the meter should show that the value is not stable. LRA resets with Integrated. [S6]
15. Tech 3341 test cases: Max M of a 400 ms tone and Max S of a 3 s tone must read within ±0.1 LU. True peak tolerance is +0.2/-0.4 dB. [S6] Inference: a readout of "max momentary" or "max short-term" over a range is valid only if the range holds at least one full window (0.4 s or 3 s).
16. R 128 s1 (2020, short-form content up to about 2 minutes): report Programme Loudness (integrated), Maximum Short-term Loudness, and Maximum True Peak. LRA is "not applicable" because too few short-term points exist. The target is -23 LUFS ±0.2 LU. Max short-term is at most -18 LUFS (+5 LU). Max true peak is -1 dBTP ±0.3 dB. [S7]
17. AES TD1008 (podcast and streaming): not read at the source (aes.org returned HTTP 403). A vendor page quotes -16 LUFS for music, -18 for speech, and a +2 LU upper tolerance for speech. True peak and required measurements: unconfirmed. [S8]

## C. Editors (primary: vendor help, source code)

18. Audacity Label Sounds (source `label-sounds.ny` and manual): threshold default -30 dB (range -100 to 0). Measurement default Peak (also Average, RMS). Minimum silence 1 s (0.01 to 3600). Minimum label interval 1 s. Leading and trailing silence 0 s. The signal is reduced to about 100 Hz (10 ms blocks) with max/mean/RMS per block. A block below the threshold is silence. Label error up to 10 ms. Stereo peak = max of both channels. [S9, S10]
19. Audacity Truncate Silence (source `TruncSilenceBase.h`): Threshold -20 dB (range -80 to -20). Minimum (detect) 0.5 s (min 0.001). Truncate to 0.5 s. Compress 50%. Independent off. Test is per sample, `fabs(x) < linear threshold`, on all channels together unless Independent. [S11] The manual page lists ranges but no defaults. [S12]
20. Audacity Silence Finder: superseded by Label Sounds. The manual gives ~0.01 s measurement resolution and no defaults. The script is not in the 3.7.0 tag. Defaults: unconfirmed. [S13]
21. Audacity "At Zero Crossings" (Z): window 1/100 s (10 ms), centered on the time. It scores each sample as |x| plus a penalty (+0.4 same sign as the previous sample, +0.1 downward crossing) plus up to 0.1 for distance from the center. It takes the minimum. It returns the original time if the best score is above 0.2 (one track) or 0.6 times the track count. [S14] This is the only "lowest point near a time" search with a stated window found in this research.
22. REAPER (release notes, ReaScript help; current v7.82): the render dry run gives render statistics with LUFS-I, LUFS-M max, LUFS-S max, LRA, true peak, peak, and RMS options. It runs on selected items, selected tracks, or the project (`CalcMediaSrcLoudness`, `RENDER_STATS`, action 42437 = dry run of selected items). A time-selection scope: unconfirmed (only a third-party script was found). A user setting makes LUFS or RMS apply for each of the three periods. LRA shows when "LRA/LUFS-S" statistics are on, otherwise an RMS-based range (RMS-RA). The true peak shows only when enabled or when normalizing to true peak. The Loudness Meter JSFX shows LUFS-I, LUFS-S, LUFS-M, LRA, RMS-I, peak, and true peak. [S15, S16] The exact dialog labels and the time-selection scope of each action: unconfirmed.
23. REAPER Dynamic split items: release notes confirm a threshold, a gate algorithm ("overhaul" in v6.0), presets, leading and trailing pad, an option to remove silence with ripple, and a "reduce splits" slider. The names and the defaults of hysteresis, minimum slice length, and minimum silence length: unconfirmed (the user guide PDF could not be text-extracted). [S15]
24. Adobe Audition: help pages returned HTTP 403 for every fetch. Second-hand only (search summaries of the Adobe pages). Diagnostics has Delete Silence and Mark Audio, with "Define Silence As" and "Define Audio As" (each an amplitude in dB and a duration in ms), "Find Levels" to fill them from the file, and for Delete Silence a choice to shorten or delete silence with a kept gap. Defaults: unconfirmed. A user report quotes Find Levels output of silence -49 dB for 1000 ms and audio -35 dB for 50 ms. That is one case, not a default. [S17]
25. Audition Amplitude Statistics (second-hand): Scan (whole file) and Scan Selection (range). Min/Max RMS are averages over RMS windows with a width set in the RMS settings tab (default width: unconfirmed). Peak, true peak, integrated loudness, and LRA fields: unconfirmed in the source. Match Loudness (second-hand): Scan, then Match To a standard (EBU R128: -23 LUFS, ±0.5 LU, -1 dB true peak), then Run. [S17]
26. Hindenburg PRO (current 2.05 build 2754 per the release-notes page): the guide list has "Meter - EBU R128: Shows the level as EBU R128" and "Insert silence". Release notes show no silence detection, no pause shortening, and no loudness-range hit. A vendor Q&A says it was "the first DAW with a built-in Loudness meter". Which values the meter shows (M, S, I, LRA, true peak, PLR) and whether it measures a selection: unconfirmed. A third-party column says the meter shows momentary values over time. Silence-detect features: none found (absence not proven). Clipboard is an organizer for clips (not audio analysis). Voice Profile is a tonal reference (EQ), not level analysis. [S18, S19]
27. Logic Pro (Apple guide): "Remove Silence" window has Threshold, Minimum Time to accept as Silence, Pre Attack-Time, Post Release-Time. Units and defaults are not in the guide: unconfirmed. Loudness Meter: M, S, I fields, LU Range, Integrated, target line -30 to 0 LUFS, EBU R 128. Range and Integrated fill only while Start/Pause is on. No true peak in this meter (true peak is in the Level meter). [S20, S21]
28. Final Cut Pro (Apple guide): MultiMeter Loudness shows momentary level plus LU-I and LU-S (3 s), AES 128. No LRA. True peak is in the Level meter modes. No silence detection found; audio analysis can remove silent channels only. [S22, S23]
29. Descript Shorten word gaps (help): a search over transcript gaps, "more than" or "between" a duration, and a target length (example 200 ms). Defaults are not stated: unconfirmed. Gaps come from the transcript word times, not from a level threshold. [S24]

## D. Pause or cut-point search near a time

30. Confirmed precedent: Audacity zero-crossing search (item 21), window 10 ms, lowest |sample| score with a distance penalty. It targets clicks, not pauses.
31. No primary source found for "nearest pause" in a speech editor with a search window. Descript works on word gaps. Audacity Label Sounds and Truncate Silence list regions but have no "nearest to a time" mode. REAPER, Audition, Hindenburg: unconfirmed.
32. Inference: a nearest-pause command can reuse the silence-list rule (item 2 or 18) on the window, then return the silence whose edge or middle is closest to the time. A fallback for no silence is the lowest-level block. No source confirms either rule, and the most common gesture (a speech edit at a spoken pause) was not checked against a tool.

## E. Values for the plan (derived)

33. Defaults in tools: threshold -60 dB (ffmpeg, per sample), -30 dB (Audacity Label Sounds, peak per 10 ms), -20 dB (Audacity Truncate Silence, per sample). Minimum length 2 s (ffmpeg), 1 s (Label Sounds), 0.5 s (Truncate Silence).
34. Per-sample peak detection is fragile for speech with noise. A block peak or block RMS (10 ms in Audacity) is the documented alternative.
35. For a readout of a range, the standard-backed set is: integrated (I), LRA with the gate values, max momentary, max short-term, max true peak. Validity: I needs at least one 400 ms block, short-term values need 3 s, and LRA is not applicable to short ranges (R 128 s1 up to about 2 minutes).

## Sources

- S1 https://ffmpeg.org/ffmpeg-filters.html (silencedetect section; same text in https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/filters.texi)
- S2 https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/af_silencedetect.c
- S2b https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/doc/filters.texi (ebur128 section)
- S3 https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavfilter/f_ebur128.c
- S4 `ffmpeg -h filter=ebur128` and `-h filter=silencedetect`, ffmpeg 9.0.1
- P1, P2 local ffmpeg 9.0.1 probes on generated tones (run 2026-10-23-read-by-time)
- S5 https://tech.ebu.ch/docs/tech/tech3342.pdf
- S6 https://tech.ebu.ch/docs/tech/tech3341.pdf
- S7 https://tech.ebu.ch/docs/r/r128s1.pdf
- S8 https://docs.telosalliance.com/docs/understanding-loudness-for-streaming-audio (secondary; AES PDFs at aes.org blocked)
- S9 https://raw.githubusercontent.com/audacity/audacity/master/share/nyquist-plug-ins/label-sounds.ny
- S10 https://manual.audacityteam.org/man/label_sounds.html
- S11 https://github.com/audacity/audacity/blob/master/au3/libraries/au3-builtin-effects/TruncSilenceBase.h and TruncSilenceBase.cpp
- S12 https://manual.audacityteam.org/man/truncate_silence.html
- S13 https://manual.audacityteam.org/man/silence_finder.html
- S14 https://github.com/audacity/audacity/blob/master/au3/src/menus/SelectMenus.cpp
- S15 https://www.reaper.fm/whatsnew.txt (v7.82, 2026-10-04)
- S16 https://www.reaper.fm/sdk/reascript/reascripthelp.html (CalcMediaSrcLoudness, RENDER_STATS)
- S17 https://helpx.adobe.com/audition/using/diagnostics-effects-waveform-editor-only.html, https://helpx.adobe.com/audition/using/match-loudness.html, https://helpx.adobe.com/audition/using/analyzing-phase-frequency-amplitude.html (HTTP 403; read only as search summaries)
- S18 https://hindenburg.com/support/guides/?search=meter&product=2127 and https://hindenburg.com/support/release-notes/hindenburg-series/
- S19 https://hindenburg.uservoice.com/knowledgebase/articles/290763-what-are-the-benefits-of-using-loudness-instead-of
- S20 https://support.apple.com/guide/logicpro/remove-silent-passages-lgcp86ee7672/mac
- S21 https://support.apple.com/guide/logicpro/loudness-meter-lgce12d9d256/mac
- S22 https://support.apple.com/guide/final-cut-pro-logic-effects/level-and-loudness-controls-lgex1d0722a3/mac
- S23 https://support.apple.com/guide/final-cut-pro/audio-analysis-options-verb6acaf60/mac (search summary)
- S24 https://help.descript.com/script-editing/shorten-word-gaps
