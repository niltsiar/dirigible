# Research: cut edges of a text cut (F111)

Date: 2026-10-28 (research); 2026-11-01 (measurement)

Each claim has a source number [n]. "Inference:" marks a claim with no owner source. Time spent: about 30 min for the research on 2026-10-28. The measurement on 2026-11-01 is in its own section. Adobe help pages (helpx) gave HTTP 403 on every URL tried. web.archive.org is blocked for this tool. Riverside help pages gave HTTP 403 too. Search excerpts replace them, and each one is marked.

## Short answer

No reference app documents where a text cut puts its start edge and end edge. This holds for Hindenburg, Descript, Premiere, and Riverside. The vendor pages cover other things: whole-word selection, strikethrough, restore, pause tools. The only source with the edge rule is open code: SpliceKit for Final Cut Pro cuts at the word start and the word end, with no pad [14]. Descript is the only vendor that documents any join treatment: a micro fade of about 5 samples [3].

## Summary table

| app | start edge | end edge | pause rule | fade | source |
|---|---|---|---|---|---|
| Hindenburg PRO 2 | not documented | not documented | not documented | not documented | [1][2] |
| Descript | not documented | not documented | Delete removes audio. "Delete and replace with gap" keeps the time. "Shorten word gaps" sets a target (example 200 ms) | micro fade about 5 samples, automatic, not in exports. Longer crossfade is manual | [3][4][5][6] |
| Premiere Pro | not documented | not documented | pause filter minimum is 0.1 s. Extract closes the gap, Lift leaves it | not documented | [7][8] |
| Riverside | not documented | not documented | word removal in the transcript. No pause rule found | "seamless transitions" (search excerpt, no length) | [9][10] |
| Adobe Podcast | not documented | not documented | not documented | not documented | [11] |
| REAPER + ReaSpeech | no text cut found | no text cut found | none | none | [12] |
| Audacity | no text cut found | no text cut found | none | none | [13] |
| Final Cut Pro (Apple) | no text cut found | no text cut found | none | none | [14] |
| SpliceKit for FCP (third party, open source) | word start | word end | a pause is the gap from previous word end to next word start. Flag threshold 0.3 s. Delete is a ripple | none found | [14] |
| Alitu, Podcastle, Squadcast | not documented | not documented | not documented | not documented | [15] |

## Per app facts

### Hindenburg PRO 2

1. A selection covers whole words. Cmd+X cuts the audio [1].
2. Build 2706 (May 2025) fixed word timestamps that were "misaligned in longer transcriptions" [16]. This is the only vendor admission of a timing error. It gives no size.
3. Build 2724 (Jan 2026) lets the user set a range with I and O markers in the Manuscript and "select audio directly from the Manuscript" [17]. Inference: this is a way to cut at a point that is not a word edge. The note does not say so.
4. No setting, no fade, no re-alignment, no snap found. A Podnews review (third party) says only that Delete "edits" the audio and that zoom aligns words with the waveform [18].

### Descript

1. "Avoid harsh cuts" is a toggle of Remove filler words. It runs "a quick audio analysis" and "automatically skips any filler words that can't be removed without clipping into nearby words" [4]. So Descript skips a risky cut. It does not move the edge. The page says nothing on crossfades [4].
2. "Shorten word gaps": the user picks "more than" or "between", two durations, and a target length (example 200 ms). Defaults and ranges are not documented. The kept part of the gap (both sides or one side) is not documented [5].
3. Gap clips have "room tone" on by default (AI noise profile). The user can switch it off per clip or in settings [6].
4. Micro fade: "about five samples in length", between clips, "to ensure that there is no popping". It is hidden and "not included in timeline exports" [3]. Five samples is about 0.1 ms at 48 kHz.
5. Crossfade: manual (drag the handle at an edit boundary). It needs extra media beyond the visible edge of each clip. A clip trimmed to the start or end of its source cannot get one [19].
6. Word timing fix: hover on a word boundary in the wordbar, hold Cmd (macOS) or Ctrl, drag to the true audio edge. It works one word at a time [20][21]. No forced alignment or VAD is documented for the cut.
7. Secondary source (Descript feedback forum, user comment, Apr 2026): the end of "once" runs into what Descript marks as a gap, and this happens "often" [22]. No staff reply on the page.

### Premiere Pro

1. A Community Manager wrote: "The shortest pause Premiere can allow is .1 seconds" and it is "the smallest amount Premiere can filter by without accidentally chopping off pieces of your audio" [7]. The role is a forum reply, not a help page.
2. Search excerpt of a tutorial (third party): Extract closes the gap, Lift leaves it [8]. A search excerpt of the Adobe help page says that a cut in the transcript ripples [23].
3. Secondary source (forum, user, Mar 2026): silence regions look offset from the waveform and pause removal cuts dialogue. No staff reply, no ms value [24].
4. Edge placement, fade length: not found. The helpx page is not readable.

### Riverside

1. A search excerpt of the Help Center says the user selects words and presses Delete or Backspace. The removed text shows gray with a strikethrough and the user can restore it [9]. There is no bulk delete of words [9].
2. A Spotify for Creators page (secondary, a partner) says word removal gives "seamless transitions" [10]. It gives no number.
3. "Set Pace" removes pauses with an "aggressiveness" choice [25]. Numbers: not found.

### Others

- SpliceKit guide: a word delete does "Blade at the word's start time", "Blade at the word's end time", select, ripple delete. A silence marker starts at the end of the previous word and ends at the start of the next word. The default flag threshold is 0.3 s. The code has a 0.3 constant [14]. Its source snaps to frame boundaries (a comment in the code) [14].
- ReaSpeech Lite: moves its timestamps when the user splits, crops, or moves items. It has no delete-by-text in the README [12].
- Adobe Podcast, Alitu: third-party pages say that a deleted sentence is removed from the audio. They give no edge or fade fact [11][15].
- DaVinci Resolve Studio has text-based editing. The padding settings that search found (Pre Head, Post Tail) belong to Ripple Delete Silence, not to the transcript [26]. Do not count them.

## Whisper word timing

| fact | value | source |
|---|---|---|
| Token step | 20 ms (`TOKENS_PER_SECOND` = 16000 / 320 = 50) | [27] |
| Word times | DTW on cross attention, median filter width 7, rounded to 2 decimals (0.01 s) | [28] |
| Sentence-end rule | a word at a sentence boundary is cut to 2 x median word length (median capped at 0.7 s) | [28] |
| Maintainer statement | Whisper "is not explicitly trained for word-level timestamps". The method is not accurate, "especially around pauses" (paraphrase of jongwook, accepted answer) | [29] |
| WhisperX paper | collar 200 ms. AMI precision/recall: Whisper 78.9/52.1, WhisperX 84.1/60.3. Switchboard: Whisper 85.4/62.8, WhisperX 93.2/65.4 | [30] |
| WhisperX README | utterance times "can be inaccurate by several seconds"; word times use wav2vec2 forced alignment | [31] |
| CrisperWhisper paper | the space-prefixed DTW token "integrates pauses at the beginning of tokens" into the word time. DTW overestimates pauses. The authors split a pause between neighbor words, capped at 160 ms. F1 at 0.2 s collar on synthetic data: WhisperT 74.7, WhisperX 76.7, CrisperWhisper 84.7 | [32] |
| whisper-timestamped README | refine step is a multiple of 0.02 s. "Disfluencies that are not transcribed will affect the timestamp of the following word" | [33] |
| whisper.cpp | `token_timestamps` and `-dtw` are marked `[EXPERIMENTAL]`. A non-DTW step moves token edges to where signal energy crosses 0.5 x the mean energy of a window of 125 ms (1/8 s) on each side, and clamps to the neighbor token | [34][35] |

Inference: the 200 ms collar means a word within 200 ms of the reference counts as right. So no source here gives a typical error in ms. The recall of 52 to 63 percent at that collar suggests that many words miss by more than 200 ms or are missing. The cause is not split in the paper.

## Measurement on real speech (E13)

Measured on 2026-11-01. Question: can a rule bounded by the Whisper word gap move a cut edge to a quieter point? The rule under test moved each edge into its pause by min(160 ms, half the pause). Test input: a 5 min excerpt of a published two-speaker interview in Spanish, one track for each speaker, with the default model of the app (`base`) and the language on auto. Transcription of both tracks took 771 s. Room tone of the mix: -51.4 dBFS.

Bar, fixed before the data: at least 36 of 40 moved edges within room tone + 6 dB.

| item | value |
|---|---|
| Words | 805 |
| Drawn edges | 372 |
| Edges with no pause between the Whisper words | 332 (89 %) |
| Edges sampled with a pause | 40 |
| Median pause of the sampled edges | 80 ms (3 840 frames at 48 kHz) |
| Moved edges within room tone + 6 dB | 13 of 40 |
| Word edges within room tone + 6 dB | 11 of 40 |
| Moved edge quieter than the word edge by more than 3 dB | 18 of 40 |
| Moved edge louder than the word edge by more than 3 dB | 7 of 40 |
| Mean level of the moved edge minus the word edge | -3.7 dB |

Result: the bar failed (13 of 40 against 36).

What the numbers say:

1. At 89 % of the edges, the Whisper words touch. A rule bounded by the word gap has no room to move these edges.
2. Where a pause exists, it is short (median 80 ms). The rule can move an edge by at most half of it.
3. The bar measured whether the edge lands in silence. The word edges miss this too (11 of 40), so the bar cannot tell a better edge from the word edge.
4. The move helps a little (18 edges quieter, 7 louder, mean -3.7 dB), but it does not reach silence.

Conclusion, for this sample and the `base` model only: a rule bounded by the Whisper word gap could not move most edges. A quiet-point rule then needs an audio read with its own reach. Its bar must compare the moved edge with the word edge, and the bar must be fixed before its data run.

Not measured: a larger model, a second language, and a forced aligner. Any of them can give more pauses between words. A later run on the aligner must measure them before it takes this conclusion as settled.

## Defaults this suggests

All rows are Inference unless a source is named.

Rules of the table:

- Rule 1: the cut edges are the word start and the word end, as now.
- Rule 2: the cut ends at the next word start (the common belief about Descript; no source).
- Rule 3: the cut edge moves to the quietest point near the word edge (the common belief about Hindenburg; no source).

| item | suggested default | basis |
|---|---|---|
| Base edge | word start and word end as now (rule 1) | the only open code, SpliceKit, does this [14]. No vendor documents another rule |
| Join pop guard | micro fade of a few samples (Descript: about 5 samples) [3] | the only documented vendor value |
| Audible crossfade | off by default. A per-edit user action | Descript treats it as manual [19] |
| Pad limit | at most 160 ms per word edge, if a pad is added | CrisperWhisper cap for pause split [32] |
| Quiet-point search window | up to 125 ms around the word edge | whisper.cpp window [35]. Test before use. The E13 measurement shows that the reach must not be bounded by the Whisper word gap |
| Pause threshold | 0.1 s minimum, 0.3 s flag | Premiere [7], SpliceKit [14] |
| Rule 2 (next word start) | no source for any app | see Not found |
| Rule 3 (quietest point) | no source for Hindenburg | see Not found |

## Not found

- Start and end edge of a text cut: Hindenburg, Descript, Premiere, Riverside, Adobe Podcast, Podcastle, Alitu, Squadcast. The belief "Descript cuts to the next word start" has no source. The belief "Hindenburg snaps to the quietest point" has no source.
- A zero crossing snap in any app.
- Hindenburg: fade at the join, pause rule, a user setting for the cut.
- Premiere: edge rule, fade, pad. The helpx pages gave 403.
- Riverside: edge rule, fade length, pause numbers (help pages gave 403).
- Descript: the default and range of "Shorten word gaps"; which side of the gap is kept; any forced alignment.
- Audacity, REAPER with ReaSpeech, Apple Final Cut Pro: no cut by text.
- A typical Whisper word error in ms from a primary source. Both PDF papers returned no text to the fetch tool, so the exact figure lists in the CrisperWhisper and the industrial ASR papers (arXiv 2404.09841, a Whisper large-v3 timestamp figure) are not read.
- Open question for the plan (probe source, not run): align a 5 min speech file with Whisper JSON and with a forced aligner (for example WhisperX), then report the median and 90th percentile of the start and end difference per word. Run it only when no monitored loop runs.

## Sources

1. https://hindenburg.com/hindenburg-pro-2-features/edit-with-words/
2. https://hindenburg.com/products/radio-podcast/features/manuscript/
3. https://help.descript.com/timeline/automatic-microfades.md
4. https://help.descript.com/script-editing/filler-words.md
5. https://help.descript.com/script-editing/shorten-word-gaps.md
6. https://help.descript.com/timeline/using-gap-clips.md
7. https://community.adobe.com/t5/premiere-pro-discussions/text-based-editing-always-leaves-pauses-behind/m-p/15137397/highlight/true (forum reply by a Community Manager)
8. https://www.redsharknews.com/how-to-delete-pauses-and-filler-words-with-text-based-editing (third party, search excerpt)
9. https://support.riverside.com/hc/en-us/articles/14488573075741-Remove-a-word-or-phrase-from-the-recording (403; search excerpt)
10. https://creators.spotify.com/resources/create/create-with-riverside (search excerpt, partner page)
11. https://helpx.adobe.com/il_en/podcast/adobe-podcast-faq.html (covers Enhance Speech only)
12. https://github.com/TeamAudio/reaspeech-lite
13. https://casstls.weblogs.anu.edu.au/audacity-edit-track/ (third party, waveform editing only)
14. https://github.com/elliotttate/SpliceKit (docs/TRANSCRIPT_EDITING_GUIDE.md, Sources/SpliceKitTranscriptPanel.m, read through `gh api`); https://splicekit.fcp.cafe/features/transcript-editor/
15. https://www.thepodcasthost.com/?p=50958 (third party on Alitu)
16. https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2706/
17. https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2724/
18. https://podnews.net/article/hindenburg-pro-v2-review (third party)
19. https://help.descript.com/hc/en-us/articles/14192664009357
20. https://help.descript.com/script-editing/the-wordbar
21. https://help.descript.com/script-editing/trim-and-adjust-spaces-between-words.md
22. https://feedback.descript.com/feature-requests/p/smoother-transitions-when-removing-filler-words-from-script (secondary, user forum)
23. https://helpx.adobe.com/premiere/desktop/edit-projects/edit-video-using-text-based-editing/detect-and-delete-pauses-in-transcripts.html (search excerpt; the page gave HTTP 403)
24. https://community.adobe.com/bug-reports-733/premiere-pro-incorrectly-detects-silences-in-transcript-and-text-based-editing-1554235 (secondary, user forum)
25. https://riverside.com/university-videos/remove-silences (search excerpt)
26. https://dvresolve.com/tutorial/edit-with-audio-transcription-in-davinci-resolve/ (third party, search excerpt)
27. https://raw.githubusercontent.com/openai/whisper/main/whisper/audio.py
28. https://raw.githubusercontent.com/openai/whisper/main/whisper/timing.py
29. https://github.com/openai/whisper/discussions/1855
30. https://arxiv.org/abs/2303.00747 (Table 2 read from https://arxiv.org/html/2303.00747)
31. https://github.com/m-bain/whisperX
32. https://arxiv.org/html/2408.16589v1 (CrisperWhisper)
33. https://github.com/linto-ai/whisper-timestamped
34. https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/include/whisper.h
35. https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/src/whisper.cpp (function `whisper_exp_compute_token_level_timestamps`, block "VAD")
