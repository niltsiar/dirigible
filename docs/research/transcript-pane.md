# Research: transcript pane reference behavior

Date: 2026-10-28

Each claim has a source number [n]. "Inference:" marks a claim without an owner source. Adobe help pages gave HTTP 403. Adobe facts come from search excerpts: lower confidence. Accessibility: no source for any app (12.3 FCP notes only call subtitles "accessible" [23]).

## Hindenburg PRO 2

1. Place. View, Manuscript [1]. The user drags the divider between the two panes to resize and place it [1][2]. No source gives a hide key or the side.
2. Layout. The tool separates speakers in the manuscript [1]. To change a block speaker: select text, right-click, Speaker [3]. No source gives paragraph rules or in-text time stamps. Time stamps exist in the export only (build 2552) [5]. Split by Speaker exists [5]. No source shows overlap.
3. Playback. Text is highlighted while audio plays. The highlighted word is editable at once [1]. Auto-scroll, click-to-seek and double-click: no source.
4. Selection. Click highlights a word in blue. Drag selects words. The selection covers whole words. Shift+Right extends, Shift+Left shrinks, Shift+Down extends to the sentence [1]. Cmd+F searches [6]. Text selection to timeline range: no source. Inference: the cut result implies a linked range.
5. Edit. "Select the text as you would in a word document and see your edits being done in the audio." Cut is Cmd+X [1][2]. The shortcut table lists Delete as "Edit Audio with Text" [4]. Return starts text correction. Return or Esc ends it [3]. Undo of a word edit restores the time [6]. Ripple and the look of cut words: no source. The Narrator guide [7] covers another product. Ignore it.
6. Empty state, import. Text appears after Tools, Transcribe [3]. Import of a transcript: no source. Export: .txt, .srt, .vtt, .json (single words), .html [1].

## Descript

1. Place. A View menu item shows or hides the script panel. Shift+Cmd+S toggles the timeline [8].
2. Layout. A speaker label is a name in the transcript. @ assigns a speaker to a selection. The user drags a label and drops it before a word [9]. "Speaker Name: text" in an import makes labels [10]. Export has paragraph, interval time code and speaker options [11]. In-script time stamps and overlap: no source.
3. Playback. The playhead highlights the current word. During play, the text cursor moves apart from the playhead. After stop, they move together [12]. Esc toggles Autoscroll [13]. The View menu option is "Playhead autoscroll" for the timeline [8]. What stops script scroll, click-to-seek, double-click: no source.
4. Selection. Double-click selects a word [14]. A selection opens a toolbar [15]. Shift+arrow keys and range link: no source.
5. Edit. Delete removes text and media from view. Cmd+Delete ignores. Ignored text stays visible with a strikethrough and does not play [16]. Shift+Delete makes a gap clip. Shift+Cmd+Delete restores. Cmd+Z undoes [13]. Ripple: no source.
6. Import. Paste plain text, then Sync. English only. The text must match the audio [10]. Export: .html, .md, .docx, .txt, .rtf [11].

## Final Cut Pro 11 and 12

FCP has no transcript text pane in the sources.
1. Place. Captions are clips in a closed-caption lane at the top of the timeline. They show in the Captions pane of the timeline index. The viewer shows the caption at the playhead. Hide: clear the Captions box. No key [17][19].
2. Layout. Caption clips always connect to clips. No speaker labels. Overlap in one language subrole is an error. Resolve Overlaps trims them [20].
3. Playback. Transcript Search results show a few seconds before and after the phrase. Word highlight: no source [21].
4. Selection. Word selection: no source.
5. Edit. Double-click a caption, or Control+Shift+C, opens the caption editor. Command+Left and Right Arrow move between captions. Single-key shortcuts need Control [18]. Edit, Generate Captions, Closed Captions (Shift+Command+C) transcribes selected clips. Output is iTT [17]. 11.0 named it Transcribe to Captions. 12.3 says Generate Captions [23]. Inference: caption edits do not cut media. No source says so.
6. Import. File, Import, Closed Captions: CEA-608, iTT, SRT [24]. Transcript Search (12.0, English, Apple silicon): Search, Transcript, Includes or Is Related To. "Transcribe in English" is on at import [21][23].

## Logic Pro 12.4

No transcript feature found. Release notes 12.0 to 12.4 have no transcript, speech-to-text or caption line [25]. A guide search finds only Score lyrics and Speech Enhancer [26].

## Adobe Audition 26.x

No vendor page found. A forum reply (Legend, not staff) says speech to text "is not available in Adobe Audition" (2019) [27]. Unconfirmed.

## Adobe Premiere Pro Text panel

1. Place. Window, Text. The Transcript tab holds the sequence transcript [28][29].
2. Layout. Speakers with time stamps, and text with timecodes [28][31]. Speaker separation is a transcribe option [31]. Filter menu: Text, Filler words, Pauses, Speakers [29]. Paragraph rule: no source.
3. Playback. User forum reports (not vendor): Space plays, the tab highlights the current word. "Follow active monitor" controls following [32].
4. Selection. "Automatically Set In/Out Points": selecting words sets in and out [32]. Insert (comma) and Extract (apostrophe) keys act on it [33]. Search highlights matches [34].
5. Edit. Cut or delete in the sequence transcript removes clips. Premiere applies a ripple edit [28][29]. Speaker delete needs a sequence [29]. Strikethrough: no source. Undo: Cmd+Z [35].
6. Import. Export text, fix spelling, Import corrected transcript (txt). It fails if sections were deleted. Native and CSV formats exist [36]. SRT is a caption file [37].

## Defaults this suggests

| Item | Best reference behavior | Source |
|---|---|---|
| Show/hide | One View menu item with a key. Resizable divider. | [1][8] |
| Paragraphs | Break at speaker change. Speaker name at block start. | [3][9] |
| Time stamps | Not in the pane. Optional in export. | [5][11] |
| Playback | Highlight current word. Text cursor stays free. | [1][12] |
| Selection | Whole words. Shift+Left/Right word. Shift+Down sentence. | [1] |
| Cut | Cmd+X and Delete cut audio. Cmd+Z undoes. | [1][4][13] |
| Cut words | Visible with strikethrough (Ignore model). Ripple: council choice. | [16][28] |
| Overlap | No reference shows it. Decide in the council. | none |
| Empty state | Offer Transcribe. Allow paste with "Speaker: text". | [3][10] |

## Not found

- Hindenburg: hide key, side, paragraph rule, in-text time stamps, overlap, auto-scroll, click-to-seek, ripple, cut-word look, import.
- Descript: in-script time stamps, overlap, script auto-scroll stop rule, click-to-seek, Shift+arrow, ripple.
- FCP: transcript pane, word highlight, text-driven cut.
- Logic: any transcript feature. Audition: any vendor page.
- Premiere: strikethrough, paragraph rule, double-click, hide key.

## Sources

H=https://hindenburg.com/, D=https://help.descript.com/hc/en-us/articles/, A=https://support.apple.com/guide/final-cut-pro/, X=https://helpx.adobe.com/premiere/desktop/, C=https://community.adobe.com/

[1] H hindenburg-pro-2-features/edit-with-words/
[2] H products/radio-podcast/features/manuscript/
[3] H hindenburg-pro-2-features/transcription/
[4] H academy/shortcuts/shortcuts-hindenburg-2-pro/
[5] H support/release-notes/hindenburg-series/
[6] H release-notes-hindenburg-pro_version-2/pro-v2_02-build-2572/
[7] H academy/guides/guides-narrator/
[8] D 10164575118989-Auto-scrolling
[9] https://help.descript.com/script-editing/speaker-labels
[10] D 10249406128781-Importing-an-existing-transcript
[11] D 10255753048589-Export-your-transcript-as-a-text-file
[12] D 10164534109837-Playback-and-navigation
[13] D 10255582172173-Keyboard-shortcuts
[14] D 360051353571-Keyboard-shortcuts-for-quick-transcript-correction
[15] D 10164874052237-Selection-toolbar
[16] D 10164872017933-Deleting-vs-ignoring-script-text
[17] A create-closed-captions-vere399dab5e/mac
[18] A edit-closed-caption-text-ver59c2001e3/mac
[19] A show-or-hide-closed-captions-ver4a54140fd/mac
[20] A adjust-and-arrange-closed-captions-verf8d5b6e49/mac
[21] https://support.apple.com/en-lb/guide/final-cut-pro/ver65764b45/mac
[23] https://support.apple.com/en-uz/102825
[24] A import-closed-captions-ver4185ef95a/mac
[25] https://support.apple.com/en-us/109503
[26] https://support.apple.com/guide/logicpro/welcome/mac
[27] C questions-544/convert-speech-to-text-in-audition-158194
[28] X edit-projects/edit-video-using-text-based-editing/edit-sequences-using-text-based-editing.html (excerpt)
[29] X edit-projects/edit-video-using-text-based-editing/detect-and-delete-pauses-in-transcripts.html (excerpt)
[31] X get-started/preferences-and-settings/transcription-preferences.html (excerpt)
[32] C questions-729/text-based-editing-not-working-1400858 (user forum)
[33] C announcements-732/text-panel-enhancements-part-2-assemble-rough-cuts-from-transcripts-313227/index2.html (Adobe post)
[34] X add-text-images/insert-captions/find-and-replace-text-in-transcription.html (excerpt)
[35] X get-started/keyboard-shortcuts/default-keyboard-shortcuts.html (excerpt)
[36] X edit-projects/edit-video-using-text-based-editing/edit-transcripts-using-text-based-editing.html (excerpt)
[37] X add-text-images/insert-captions/import-caption-file-from-third-party-service.html (excerpt)
