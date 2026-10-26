# Hindenburg edit tools: Replace, room tone fill, Duplicate, Split stereo

Date: 2026-10-13

No probe ran. Only the Hindenburg 1.21 manual [HM] describes behavior. The current Hindenburg pages [HG] [HK2] [HN] give one-line descriptions. Hindenburg PRO 2 can be different.

## Summary

1. **Replace** (Edit > Replace, Shift-Command-V). Copy a take, select the range to remove, choose Replace. The clipboard takes the place of the selection. The two lengths can be different: "the difference ... will automatically be edited" [HM]. Inference: later audio moves by the difference (ripple). No source says which tracks change.
2. **Room tone fill.** No room-tone command, region, or automatic gap fill exists. Copy a long piece of room tone, select the small area, choose Edit > Paste in Selection. Only the selection length goes in [HM]. Cut closes the gap with no fill [HM].
3. **Duplicate** (Edit > Duplicate, Command-D). It works on a region or a selection, "for making music loops or duplicating ambience" [HG]. No source gives the copy position or a ripple. Inference: right after the source, same track.
4. **Split stereo** (Tools > Split Stereo; the 1.21 text also says "Tools / Split region"). It makes a left and a right region. Then you delete the empty region [HM]. Narrator: "two tracks L&R" [HN]. The PRO 2 shortcut list does not show it.

## 1. Replace

Hindenburg [HM, Basic editing]:

- Steps: Copy (Command-C), select the area to remove, Replace (Shift-Command-V).
- "If you have two versions of a take then you can copy one and replace the other." Also a short breath for a longer one.
- "When using Replace, the difference between the copied are[a] and the selection will automatically be edited." Inference: Replace removes the selection, inserts the full clipboard, and moves later audio. The clipboard is not cut or looped to the selection length.
- [HK2]: "Edit - Replace", "Shift + Ctrl V".
- Which tracks: unconfirmed.

Related [HM] [HK2]: Paste (Command-V) "Places Selection ON TOP of existing audio" at the playhead. Insert (Command-I) "Moves following regions forward". Cut (Command-X) "Closes gap". Delete "Maintains gap".

Contrast:

- Logic Pro: the guide documents Paste, Paste at Original Position, Repeat, and Length > Double [LP]. It documents no Paste Replace in the Tracks area (unconfirmed).
- Audition: Edit > Mix Paste has Insert, Overlap, and Overwrite. Overwrite replaces audio after the cursor for the clipboard length [AU].

## 2. Room tone fill

Hindenburg [HM, Paste in Selection]:

- "Paste in Selections is a variation of ordinary paste where you can determain how much of the copied material you would like to use."
- "This is very useful if you are covering small mistakes in the audio with 'room-tone'. Copy a larger amount of 'room-tone'. Make a small selection where you would like to mask. Paste in, and fill the selection."
- [HK2] [HG]: "Edit - Paste in selection", for "adding ambience or music to a specific area".
- Clipboard shorter than the selection: unconfirmed (loop, partial fill, or refusal).
- Inference: no ripple, because the selection sets the length.
- Key: unconfirmed. [HM] shows a Command-V glyph and maybe a lost modifier. [HK2] shows "Ctrl V", the same as Paste.
- Insert Silence and Delete Silence add or remove blank time, not room tone [HK2] [HN].
- No source documents a crossfade at the edges, a loop, or an automatic fill after a cut.

Note: repo row F21 says Hindenburg "fills small gaps with room tone". [HM] does not support this. It describes a manual Paste in Selection only.

Contrast: the Logic Pro, GarageBand, Final Cut Pro, Audition, and REAPER sources read here show no room-tone fill command (unconfirmed).

## 3. Duplicate

Hindenburg:

- [HM] Edit menu: Duplicate, Command-D. The Basic editing figure shows Copy, then Duplicate.
- [HG] [HK2]: "Duplicate is used to duplicate a region or selection."
- Copy position, track, and ripple: unconfirmed.

Contrast:

- Logic Pro: Edit > Repeat "pastes one or more copies (or aliases) of the regions following (to the right of) the regions in the same track". Repeat Multiple sets a count [LR].
- GarageBand: Command-C or Option-drag, then Paste (Command-V) at the playhead on the selected track [GP]. No Duplicate command is documented.

## 4. Split stereo to mono

Hindenburg [HM, Split stereo]:

- Use case: "a mono interview with a stereo recorder". The voice plays in one channel only.
- "By splitting the region it is possible to separate the stereo file into two mono files. Leaving you with a Left & Right region. Then simply delete the empty region."
- Steps: select the region, then Tools / Split region. The Tools menu table says "Tools / Split Stereo", with no key.
- [HN]: "Tools - Split Stereo: Devides a Region into two tracks L&R".
- Unconfirmed: "two mono files" means new files or channel references.
- PRO 2: [HK2] lists "Tools | Split by Speaker" (build 2550 [HR]), not Split Stereo. Unconfirmed: Split Stereo exists in PRO 2.

Contrast:

- Logic Pro: the input format button can be Left or Right: "Only the left channel of a stereo audio file is played back" [LI]. This is a channel pick, not a split. Copy/Convert File has a "stereo conversion" setting with no listed values [LC]. Renamed .L/.R files import as dual mono [LS]. No "Convert to mono" region command is documented (unconfirmed).
- Final Cut Pro: Audio inspector > Audio Configuration > Channels. "If you change the clip's channel configuration from Stereo to Dual Mono, the channels appear as two separate audio components" [FA]. To drop a side, "Deselect the checkbox next to the component waveform" [FC]. A configuration change "resets all adjustments and edits made to audio components" [FC]. Inference: the source file does not change.
- REAPER (secondary): "Explode multichannel items" makes one-channel items on child tracks. A take channel mode picks a channel with no new file [RB] (unconfirmed).

## Open questions

1. Does PRO 2 Replace ripple all tracks or only the selected track?
2. Paste in Selection with a short clipboard: loop, partial fill, or error? What is its Mac key?
3. Does Duplicate put the copy after the source? Does it push later audio?
4. Does PRO 2 keep Split Stereo? Does it write new files?
5. Which "stereo conversion" values does Logic 12 Copy/Convert File show?

## Sources

- [HM] Hindenburg Journalist 1.21 OS X user guide: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HG] https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HK2] https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HN] https://hindenburg.com/academy/guides/guides-narrator/
- [HR] https://hindenburg.com/support/release-notes/hindenburg-series/
- [LP] https://support.apple.com/guide/logicpro/cut-copy-and-paste-regions-lgcpf7c0d424/mac
- [LR] https://support.apple.com/guide/logicpro/repeat-regions-lgcpe51317b6/mac
- [LI] https://support.apple.com/guide/logicpro/set-channel-strip-input-format-lgcp45c6e19a/mac
- [LC] https://support.apple.com/guide/logicpro/move-copy-and-convert-audio-files-lgcp757ec334/mac
- [LS] https://support.apple.com/en-us/101881
- [FA] https://support.apple.com/guide/final-cut-pro/audio-channels-and-components-verdcd140a/mac
- [FC] https://support.apple.com/guide/final-cut-pro/configure-audio-channels-verc1fab5f6/mac
- [GP] https://support.apple.com/en-ph/guide/garageband/gbnd1150b44a/mac
- [AU] https://helpx.adobe.com/audition/using/copying-cutting-pasting-deleting-audio.html
- [RB] https://reaper.blog/2012/11/how-to-separate-stereo-files-to-dual-mono
