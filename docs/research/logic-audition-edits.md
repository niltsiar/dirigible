# Logic Pro and Audition: Replace, room tone fill, Duplicate, Split stereo

Date: 2026-10-13

No probe ran. The Logic guide pages are version 12.3 [L*]. Some claims come only from the Logic 9 manual [L9*]. helpx.adobe.com refused WebFetch and curl (HTTP 403), so the Audition text comes from the Wayback Machine 2025 copies of the helpx pages [A*].

## Summary

| Edit | Logic Pro | Audition |
|---|---|---|
| Replace | Tracks area: Edit > Paste Replace in Logic 9 only. It replaces the regions in the pasted span. Key unconfirmed. Audio File Editor: Paste over a selection deletes the selection and inserts the clipboard, so later audio moves. | Waveform: select the audio, Edit > Paste. Mix Paste > Overwrite replaces audio after the cursor for the clipboard length, with no length change. Keys unconfirmed. |
| Room tone fill | Loop a region: drag its upper-right edge, or the Loop checkbox, or L. It repeats the region until the next region. Functions > Silence (Control-Delete) sets a selection to zero. | Clip Loop: Control-click > Loop, then drag the edge. Full or partial repeats. Insert > Silence pushes later audio. Generate > Noise makes synthetic noise. |
| Duplicate | Edit > Repeat (Command-R in Logic 9). Copies go to the right, same track. Repeat Multiple sets a count. Length > Double. | No Duplicate command found. Command-C copies a reference clip; Option-drag copies. Multitrack > Track > Duplicate Selected Track. Mix Paste > Loop Paste N times. |
| Split stereo | No split command. The channel strip input format Left or Right plays one channel, with no new file. | Waveform: Edit > Extract Channels To Mono Files writes Name_L and Name_R. Multitrack: Option-drag channels to separate tracks. |

## 1. Replace

- Logic Tracks area: Paste (Command-V) puts the region at the playhead on the selected track [LP]. The 12.3 guide has no Paste Replace.
- Logic 9: with Paste Replace, "all existing regions or events in a given location are replaced" [L9C]. Inference: no ripple.
- Logic Audio File Editor Paste: "All audio data that follows ... is moved back". "Anything selected ... is deleted—replaced by the Clipboard contents" [LAE]. This is a destructive file edit.
- Audition Paste: "select existing audio you want to replace. Then choose Edit > Paste" [AC]. Inference: later audio moves by the length difference.
- Audition Mix Paste > Overwrite "replaces the existing material thereafter for the duration of audio" [AC]. Mix Paste has a crossfade in milliseconds.
- Track scope: only Audition Ripple Delete documents one. Its scopes are Selected Clips, Time Selection in Selected Clips, in All Tracks, and in Selected Track [AM].
- Mix Paste Shift-Command-V: third-party only (unconfirmed).

## 2. Room tone fill

Both apps repeat a short clip to fill a span. Neither has a room-tone command.

- Logic: drag the region edge; "notches" show "each complete repetition" [LL]. The Loop checkbox or L loops "until the start of the next region in the track" [LL].
- Logic Functions > Silence (Control-Delete) sets the selection to zero and keeps the length [LS].
- Audition clip Loop: "you can make the loop repeat fully or partially" [ALP]. It is nondestructive [AM].
- Audition Edit > Insert > Silence: "Any audio to the right is pushed out ... Multitrack clips are split if necessary." Effects > Silence keeps the duration [AS].
- Audition Generate > Noise replaces a selection with white, pink, or brown noise [AG]. This is not recorded room tone.
- Audition Capture Noise Print is Shift-P [AK]. For a short noise range, "copy and paste the currently selected range" [AN].

## 3. Duplicate

- Logic Repeat puts copies "following (to the right of) the regions in the same track" [LR]. Command-R is the Logic 9 default [L9R]; the 12.3 guide gives no key.
- Inference: no ripple. "The copies may overlap any existing loop repetitions" [LR].
- Logic Length > Double repeats the contents "in the right half" [LP].
- Audition: the sources show no clip Duplicate and no Waveform Duplicate (unconfirmed). A right-drag gives Copy Here or Copy Unique Here [AM].
- Audition Duplicate Selected Track copies "all clips, effects, equalization, and envelopes" [AB].

## 4. Split stereo to mono

- Logic input format Left: "Only the left channel of a stereo audio file is played back" [LI]. Inference: duplicate the track and set Left and Right.
- Logic Copy/Convert File has a "stereo conversion" setting [LC]. Logic 9 shows "Split to Interleaved" and links a .L/.R pair as one stereo file [L9S].
- Audition: "Jazz.aif produces mono files named Jazz_L and Jazz_R". Audition opens each new file [AX].
- Audition Source Channel Routing swaps a channel, but "You cannot modify the number of channels in a clip" [AMC].
- Audition Convert Sample Type (Shift-T [AK]) > Mono mixes the channels by Left Mix and Right Mix percentages [ACV].

## Open questions

1. Does Logic 12 keep Paste Replace? What is its key? Does it ripple?
2. Where does an Audition Multitrack paste go, and does it overlap?
3. Audition Waveform Paste over a selection: does later audio move by the length difference?
4. Does Audition have a Duplicate command?
5. Which stereo conversion values does Logic 12 Copy/Convert File show?
6. Is Command-R still the Logic 12 default for Repeat?

## Sources

- [LP] https://support.apple.com/guide/logicpro/cut-copy-and-paste-regions-lgcpf7c0d424/mac
- [LR] https://support.apple.com/guide/logicpro/repeat-regions-lgcpe51317b6/mac
- [LL] https://support.apple.com/guide/logicpro/loop-regions-lgcpf7c0e0db/mac
- [LAE] https://support.apple.com/guide/logicpro/audio-file-editor-edit-commands-lgcp2158f180/mac
- [LS] https://support.apple.com/guide/logicpro/trim-or-silence-audio-files-lgcp21583be6/mac
- [LI] https://support.apple.com/guide/logicpro/set-channel-strip-input-format-lgcp45c6e19a/mac
- [LC] https://support.apple.com/guide/logicpro/move-copy-and-convert-audio-files-lgcp757ec334/mac
- [L9C] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_8_section_9.html
- [L9R] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_13_section_20.html
- [L9S] https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_42_section_2.html
- [AC] https://helpx.adobe.com/audition/using/copying-cutting-pasting-deleting-audio.html
- [AM] https://helpx.adobe.com/audition/using/arranging-editing-multitrack-clips.html
- [ALP] https://helpx.adobe.com/audition/using/looping-clips.html
- [AS] https://helpx.adobe.com/audition/using/inverting-reversing-silencing-audio.html
- [AG] https://helpx.adobe.com/audition/using/generate-tones-effect.html
- [AN] https://helpx.adobe.com/audition/using/noise-reduction-restoration-effects.html
- [AK] https://helpx.adobe.com/audition/using/default-keyboard-shortcuts.html
- [AB] https://helpx.adobe.com/audition/using/basic-multitrack-controls.html
- [AX] https://helpx.adobe.com/audition/using/saving-exporting-files.html
- [AMC] https://helpx.adobe.com/audition/using/multichannel-audio-workflow.html
- [ACV] https://helpx.adobe.com/audition/using/converting-sample-types.html
