# Export loudness with a true-peak limit: research findings

Date: 2026-10-15

## Answer first

No primary source describes a post-limiter re-measure in Hindenburg PRO, Auphonic, or Adobe Audition. The ffmpeg source (af_loudnorm.c) shows a single gain and a limiter, with no re-measure. Apple's primary page sets the delivery rule that matters: true peak not above -1 dBFS, loudness -16 LKFS +/- 1 dB, and processing before encoding.

Access note: Adobe help pages returned HTTP 403. The AES and EBU PDFs were not readable by the fetch tool. Hindenburg's support site was not indexed. Those claims rest on search snippets or secondary sources, and each is marked.

## 1. Hindenburg PRO

- Export targets: "Whether -23, -24 or -16, Hindenburg PRO lets you easily export to any LUFS standard or even multiple standards at once." (Hindenburg features page, undated.)
- Older presets: a 2018 ProVideo Coalition article (secondary) reports -24, -23, and -16 LUFS in PRO, plus -14 and -18 LUFS for BBC work. The same article reports a -16 "Podcast Standard" in the standard edition.
- True-peak setting, limiter type, pass count, per-format headroom: unconfirmed. No source found.

## 2. Auphonic

- Singletrack algorithms page (primary): the normalization applies "a constant gain to reach a defined target level in LUFS". It also says: "multi-pass loudness normalization strategy based on statistics from processed files on our servers", "to more precisely match the target loudness and to avoid additional processing steps". The page does not say whether it re-measures after limiting.
- Leveler page (primary): "A True Peak Limiter, with 4x oversampling to avoid intersample peaks, is used to limit the final output signal" and "ensures compliance with the selected loudness standard".
- Max true peak default, look-ahead or release values, lossy-format or low-bit-rate rule, and output tolerance: not stated on either page (unconfirmed).

## 3. Adobe Audition

- Match Loudness help page: HTTP 403. Search snippet of the same page (unverified text): presets "EBU R128" at -23 LUFS and -1 dB TP, and "ATSC A/85" at -24 LUFS and -2 dB TP. Snippet also says True Peak Limiting "ensures that the signal never exceeds the limit."
- Use Limiting look-ahead and release values, and whether the panel iterates after limiting: unconfirmed.
- Media Encoder "automatic loudness correction" page (HTTP 403, snippet only): a true-peak limiter with adjustable look-ahead and release. Default values: unconfirmed.

## 4. ffmpeg loudnorm

Primary source: libavfilter/af_loudnorm.c (ffmpeg trunk, doxygen source page). I read lines 1 to about 100 k characters of the page. The source is a trunk snapshot, not a pinned release.

- Mode choice (init, lines 815-822): `offset = target_i - measured_i`, `offset_tp = measured_tp + offset`. Linear mode runs only when `measured_tp != 99`, `measured_thresh != -70`, `measured_lra != 0`, `measured_i != 0`, `offset_tp <= target_tp`, and `measured_lra <= target_lra`. Otherwise the filter runs dynamic mode.
- Defaults (lines 107-111): I = -24, LRA = 7, TP = -2.
- Linear mode (line 622): `dst[c] = src[c] * s->offset;`. No limiter call. A true peak above the target therefore sends the filter to dynamic mode.
- Dynamic mode: the offset multiplies the limiter buffer before the limiter runs (lines 496 and 506, and the same pattern later). First-frame offset (line 463): `offset_tp < target_tp ? offset : target_tp / true_peak`.
- 192 kHz: line 740 defines `input_srate[] = {192000, -1}`, and line 751 applies it when not in linear mode. The ffmpeg filter documentation (search snippet, not read in full) says dynamic mode upsamples to 192 kHz for true-peak detection.
- Re-measure after limiting: none in the code I read. Inference: the filter does not iterate.

## 5. Lossy codec headroom

- Apple Podcasts audio requirements (primary, podcasters.apple.com/support/audio-requirements): "the true-peak value doesn't exceed -1 dB FS". "The preconditioning steps need to occur before the encoding process." Measurement: ITU-R BS.1770-5. For RSS, Apple "strongly recommend[s] using AAC instead of MP3". RSS stereo at 44.1/48 kHz: 128-256 kbps recommended.
- AES TD1008 (v1.21-9, 2021, docID 731): document not read. Secondary quotes (Fora Soft article, 2026-06-06; baken docs) say: -1 dBTP at the codec input for lossy streams; lower for low bit rates; about -0.5 dBTP acceptable for a 256 kbps coder; "peak overshoot increases as the bit rate decreases." Secondary only.
- AES TD1004.1.15-10 (2015): secondary summary gives a -16 to -20 LUFS window and -1 dBTP maximum (Production Expert). Unconfirmed against primary.
- EBU Tech 3344: PDF not readable. Secondary sources conflict: one says -3 dBTP for lossy delivery, another says -2 dBTP (both unconfirmed).
- Apple Digital Masters, "Mastered for iTunes", afclip: not checked (unconfirmed).
- AAC and MP3 overshoot at 128 kbps: no primary measured value found (unconfirmed). The only data point is Dirigible's own +1.5 dB overshoot on the AAC file (a Dirigible probe, not verified by this research).

## 6. Tolerance norms

- Apple Podcasts (primary): "around -16 dB LKFS, with a +/- 1 dB tolerance"; true peak not above -1 dB FS. Secondary (Podnews) reads -15 and -17 as acceptable.
- Apple mono rule (primary): MP3 accepts mono or stereo. WAV and FLAC reject single-channel audio. The "-19 LUFS mono" figure comes from secondary sources only (unconfirmed).
- EBU R 128 (tech.ebu.ch/publications/r128, primary page): target "average programme loudness of -23 LUFS". Version history: "Target level (-23 LUFS) tolerances restricted to +/- 0.5 LU" (v3.0, 2014). Version 4.0 (2020) lists "Tolerances updates" without values. Current tolerance: unconfirmed. One secondary page says "+/- 0.2 LU (+/- 1 LU for live programmes)". Unconfirmed.
- EBU R 128 s2 (tech.ebu.ch/publications/r128s2, search snippet): streaming services should play programmes "unchanged at -23.0 LUFS", with correct loudness metadata.
- Spotify podcasts: primary not checked. Secondary (Descript blog): -14 LUFS. Spotify ads spec: a search summary reports -16 LUFS +/- 1.5 LU and -2.0 dBTP for ads. The Spotify page could not be reached (unconfirmed).
- Amazon: not checked.

## What this means for Dirigible

Context from the bug report: a Podcast export read -16.8 LUFS as WAV and AAC, and -17.2 LUFS as MP3. The AAC file had a true peak of +0.5 dBFS.

Inference from the sources above:
- WAV at -16.8 passes Apple's +/- 1 dB window. MP3 at -17.2 fails it, by 0.2 dB.
- The AAC file fails Apple's -1 dBFS rule, by 1.5 dB. A master ceiling of -1 dBTP cannot protect the encoded file.

Options, with cost and source:

A. Lower the ceiling before a lossy encode, for example -2.5 dBTP for AAC and MP3. Cost: one constant per codec. Loudness may drop if the limiter works harder. Source: Apple's -1 dBFS rule (primary); the lower-ceiling advice (AES TD1008, secondary). The margin rests on one overshoot sample, so a probe must check it.

B. Decode, measure, and correct the encoded file, then re-encode if needed. Cost: one or two extra decode and encode passes per export. This is the only option that checks the delivered file. Source: ffmpeg does not do this (af_loudnorm.c); Auphonic's multi-pass method is server-side and not described (Inference).

C. Compensate the MP3 encoder gain. Cost: a fixed offset, tied to LAME version and bit rate. Source: the -0.45 dB figure is a Dirigible measurement (decision 0034, probe U4; unconfirmed in a primary source).

D. Aim the integrated target at -16.0 LUFS and keep the -1 dBFS true-peak rule. Cost: zero code, but it needs the true-peak fix in A or B. Source: Apple (primary).

E. Keep the current -1 dBTP master and accept the overshoot. Not viable: Apple's rule applies to the delivered file.

Falsifiable criteria for the plan (Inference): for each format, the decoded file has true peak at or below -1.0 dBFS, and integrated loudness between -17.0 and -15.0 LUFS.

## Open questions (answered by Dirigible probes)

1. AAC (AudioToolbox) and MP3 (LAME) overshoot at 128 kbps, over several masters: decoded true peak minus master true peak.
2. Whether LAME's -0.45 dB gain holds from 64 to 160 kbps, and for the LAME version in use.
3. Whether the AAC file's LUFS value matches the WAV value (not in the bug report).
4. Whether one measure-and-correct pass on the decoded file converges within the window.
5. Hindenburg PRO's export behavior: needs a hands-on export and measurement. Not checked here.
6. Adobe Audition's limiter settings and iteration: needs the app or a readable help page.

## Sources

Primary:
- https://podcasters.apple.com/support/audio-requirements (Apple Podcasts audio requirements, fetched 2026-10-15)
- https://tech.ebu.ch/publications/r128 (EBU R 128 page, fetched 2026-10-15)
- https://tech.ebu.ch/publications/r128s2 (EBU R 128 s2, search snippet)
- https://ffmpeg.org/doxygen/trunk/af__loudnorm_8c_source.html (ffmpeg af_loudnorm.c, trunk, fetched 2026-10-15)
- https://ffmpeg.org/ffmpeg-filters.html (ffmpeg filter documentation, read only partly; loudnorm section not reached)
- https://auphonic.com/help/algorithms/singletrack.html (Auphonic singletrack algorithms, fetched 2026-10-15)
- https://auphonic.com/help/desktop/leveler.html (Auphonic Leveler, fetched 2026-10-15)
- https://hindenburg.com/hindenburg-pro-features/sharing/ (Hindenburg PRO features, fetched 2026-10-15)
- https://helpx.adobe.com/audition/using/match-loudness.html (HTTP 403; search snippet only)
- https://helpx.adobe.com/media-encoder/using/automatic-loudness-correction.html (HTTP 403; search snippet only)
- https://tech.ebu.ch/docs/tech/tech3344.pdf (not readable)
- AES TD1004.1.15-10 and TD1008 (https://www.aes.org/technical/documentDownloads.cfm?docID=731 for TD1008): not fetched; secondary only

Secondary (search snippets or articles):
- https://www.provideocoalition.com/lufs-audio-standards-update-for-may-2018/ (2018)
- https://www.forasoft.com/learn/audio-for-video/articles-audio/true-peak-dbtp-inter-sample (2026-06-06)
- https://docs.rs/crate/baken/3.0.2/source/docs/true-peak-ceiling.md
- https://www.production-expert.com/home-page/2015/11/17/aes-release-recommendations-for-loudness-of-audio-streaming-and-network-file-playback
- https://podnews.net/article/lufs-lkfs-for-podcasters
- https://www.descript.com/blog/article/podcast-loudness-standard-getting-the-right-volume
- https://ads.spotify.com/en-GB/ad-specs/podcast-ad-specs/ (connection refused; summary only)

## Result in Dirigible

Decision 0032 holds the result. The export searches the gain on the limited signal (Auphonic: a constant gain, more passes when needed). It reads back each AAC and MP3 file as macOS decodes it, and checks the delivered file against the -1 dBTP rule of Apple. Options A, B, and C above all became parts of it: a start ceiling per codec, a read-back with a retry, and the MP3 offset as a start value that the read-back replaces. The Hindenburg PRO and Audition questions stay open.
