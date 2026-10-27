# How editors let the user change processed clips later

Date: 2026-10-14

Question: how do other editors let the user change the settings of a processed or rendered clip later, with no Undo?

Key: (a) live effect or new file. (b) what stays of the original. (c) how the user changes the amount. (d) how the user goes back. (e) what a split or a trim does.

## Summary

- Most tools keep the processing live on the clip or the track. The source file does not change.
- Two tools make a new file and keep the original next to it: Logic Bounce in Place (Leave or Mute) and REAPER "Apply track/take FX to items as new take".
- REAPER is the closest model for a rendered clip that the user can revert. The render is one more take in the same item. The original take stays, and the T key switches back.
- Destructive paths (Audition Waveform Editor, Logic Audio File Editor, Audacity Effect menu) depend on Undo or on a copy of the file.

## Hindenburg PRO

Version note: the effect and Auto Level guides are the archived 1.x online guides (2016). The 2.x evidence is release notes only. No 2.x manual page was found.

- (a) Live. Effects are in a track "effect bin". "The effects will be applied to the entire track" [H1]. Voice Profiler is one of these effects [H3]. In 2.x, Noise Reduction and Voice Profiler have effect windows that "reopen with the session" [H5]. Auto Level adjusts "the levels for the individual regions/clips" [H2].
- (b) The source audio stays. The 2.x product page says "Your original audio is safe" [H7].
- (c) The user opens the effect bin and changes the effect [H1]. The user runs manual Auto Level again (Ctrl+L) after an edit [H2].
- (d) Right-click the effect and choose "none" [H1]. The same steps remove the Voice Profiler [H4].
- (e) Track effects apply to the whole track, so a split does not change them [H1]. Inference: Auto Level stores a region gain value, not a new file. The 2.x shortcut list has "Regions - Gain: Drag gain handle" [H6]. No source says this directly.
- Magic Levels: no primary source describes how it works or how to remove it.
- Clip effects: no source shows effects per clip in Hindenburg. Only track and master effects are documented [H1][H6].

## Adobe Audition

- (a) Two editors. In the Multitrack Editor, "effects are nondestructive, so you can change them at any time", with up to 16 effects on each clip, track, and bus [A1]. In the Waveform Editor, the Process menu and the Apply button "permanently applies effects" [A2]. Noise Reduction (process) is "Waveform Editor only" [A3].
- (b) Multitrack: the source file stays. "Clip edits are impermanent; you can return to the original, unedited clip at any time" [A4]. Match Clip Volume is "completely reversible" [A5]. "Bounce To New Track" makes a new track and clip from the selected clips [A5]. The source does not say what happens to the original clips. A "unique copy" has "a separate audio file on disk", so destructive effects change one copy only [A4].
- (c) Select the clip, click Clip Effects in the Effects Rack, and change the effect [A1].
- (d) Multitrack: remove or bypass the clip effect [A1]. Waveform Editor: only Undo or a unique copy made before the change [A4].
- (e) Not stated in the sources. Inference: each part of a split clip keeps the clip effects.
- Pre-render track effects is only for CPU load. The user can still edit the track settings [A1].
- Automatic Speech Alignment: not checked. The CS6 reference PDF [A6] returned HTTP 403. Open question: is the original clip kept or muted?

## Logic Pro

- (a) Both. Plug-ins are live on the channel strip. Bounce in Place makes "audio files that are placed at the same position as the original regions", with "all active plug-ins and automation data" [L1]. Edits in the Audio File Editor are "destructive, permanently altering the original audio file" [L2].
- (b) Bounce in Place, Source buttons: "Leave" (unaltered), "Mute", or "Delete" the source region. These apply only with the New Track destination. With Selected Track, the bounce replaces the regions [L1].
- (c) Change the plug-in on the channel strip. For a bounced region, bounce again from the kept source. Options: "Bypass Effect Plug-ins", "Include Volume/Pan Automation", and Normalize [L1].
- (d) With Leave or Mute, unmute the source region and delete the bounce. With Delete, only Undo [L1]. Audio File Editor: Undo, or work on copies [L2].
- (e) Not stated. Inference: a split region keeps the track plug-ins, because they are on the track, not on the region.
- Stem Splitter makes new stem tracks in a summing stack. "The original region is muted" [L3]. Mastering Assistant is a live plug-in on the stereo output. The user can reanalyze it and bypass it [L4].
- Inference: Logic has no per-region plug-ins. ChromaGlow and Flex were not checked.

## Final Cut Pro

- (a) Live. Audio effects process audio "in real time". The user adjusts them in the Audio inspector [F1]. Voice Isolation, Loudness, Noise Removal, and Hum Removal are checkboxes with Amount sliders [F2].
- (b) The original media stays. "Original media files are not deleted, so you can always regenerate render files from the original media" [F3].
- (c) Drag the Amount slider (Voice Isolation, Noise Removal) or the Amount and Uniformity sliders (Loudness) [F2].
- (d) "To turn off an enhancement, deselect its checkbox" [F2]. The Delete Generated Files commands remove only render, optimized, and proxy files [F3].
- (e) Not stated. Inference: each blade part keeps the effect settings.
- Analysis results: a green checkmark shows that a clip "was analyzed" [F2]. Enhancements work on the audio component, not the clip [F2]. Inference: the library stores the result.

## REAPER

- (a) Both. Take FX are live on one item take [R1]. "Apply track/take FX to items as new take" renders a new take into the same item [R4].
- (b) The original take stays in the item. Only the active take plays. "Glue" also "creates a new media item: the original items are not damaged" [R3].
- (c) Change the take FX, then apply again as a new take [R1][R4]. After the apply, "the original FX chain can now be set to bypass" [R4].
- (d) "Next take (T)" and "Previous take (Shift T)" switch the active take. "Crop to active take" removes the other takes [R4].
- (e) After a split, "Item FX will be applied to both items unless" the preference "Duplicate take FX when splitting items" is off [R2].

## Audacity

- Version note: [U1] and [U2] are the Audacity 4 manual. [U3] is the 3.x support site. The 3.2 specifics were not checked.
- Realtime effects work during playback: "The audio in the track is never altered" [U1]. They apply to a whole track [U2][U3]. The user removes one with "No Effect" [U1]. Tracks > Mix > Mix and Render makes them permanent [U3].
- Effect menu effects rewrite the audio. "Undo will step back out of it while the project is open". After the project closes, the change stays [U2].
- In Audacity 4, only Compressor, Limiter, and Reverb of the built-in effects work in realtime [U1].

## Not checked

- iZotope RX Connect.

## Sources

- [H1] Hindenburg guide 1.x, Effects and Effects - None: https://web.archive.org/web/2016id_/http://hindenburg.com:80/support/guides/effects and https://web.archive.org/web/2016id_/http://hindenburg.com:80/support/guides/effects-none
- [H2] Hindenburg guide 1.x, Auto level and Auto level - manual: https://web.archive.org/web/2016id_/http://hindenburg.com:80/support/guides/auto-level and https://web.archive.org/web/2016id_/http://hindenburg.com:80/support/guides/auto-level-manual
- [H3] Hindenburg guide 1.x, Voice Profiler: https://web.archive.org/web/2016id_/http://hindenburg.com:80/support/guides/voice-profiler
- [H4] Hindenburg guide 1.x, Voice Profiler - remove: https://web.archive.org/web/2016id_/http://hindenburg.com:80/support/guides/voice-profiler-remove
- [H5] Hindenburg PRO 2.05 build 2730 release notes: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2730/ and 2.0 build 2550: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_build-2550/
- [H6] Hindenburg 2 PRO shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [H7] Hindenburg PRO story editing: https://hindenburg.com/hindenburg-pro-features/story-editing
- [A1] Audition, Applying effects in the Multitrack Editor: https://web.archive.org/web/2024/https://helpx.adobe.com/audition/using/applying-effects-multitrack-editor.html
- [A2] Audition, Effects controls: https://web.archive.org/web/2024/https://helpx.adobe.com/audition/using/effects-controls.html
- [A3] Audition, Noise reduction and restoration effects: https://web.archive.org/web/2024/https://helpx.adobe.com/audition/using/noise-reduction-restoration-effects.html
- [A4] Audition, Arranging and editing multitrack clips: https://web.archive.org/web/2024/https://helpx.adobe.com/audition/using/arranging-editing-multitrack-clips.html
- [A5] Audition, Clip volume matching, fading, mixing: https://web.archive.org/web/2025/https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/clip-volume-matching-fading-mixing.html
- [A6] Audition CS6 reference PDF (not read, HTTP 403): https://helpx.adobe.com/pdf/cs6/audition_reference.pdf
- [L1] Logic Pro, Bounce regions in place: https://support.apple.com/guide/logicpro/bounce-regions-in-place-lgcp8ae5826e/mac
- [L2] Logic Pro, Audio File Editor overview: https://support.apple.com/guide/logicpro/audio-file-editor-overview-lgcp21587d1c/mac
- [L3] Logic Pro, Stem Splitter: https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac
- [L4] Logic Pro, Mastering Assistant overview: https://support.apple.com/guide/logicpro/mastering-assistant-overview-lgcp7f94da0b/mac
- [F1] Final Cut Pro, Add audio effects: https://support.apple.com/guide/final-cut-pro/add-audio-effects-verb71ca88f/mac
- [F2] Final Cut Pro, Enhance audio: https://support.apple.com/guide/final-cut-pro/verc1fab873/mac
- [F3] Final Cut Pro, Manage render files: https://support.apple.com/guide/final-cut-pro/manage-render-files-ver68a8c250/mac
- [R1] REAPER User Guide 7.81, 6.4 Item Take FX, PDF page 113: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [R2] Same guide, split items, PDF page 124.
- [R3] Same guide, 7.33 Glue Selected Items, PDF page 148.
- [R4] Same guide, 8.7 Take Menu Command Summary and 8.9 More Take Commands, PDF pages 164-166.
- [U1] Audacity 4 manual, Realtime effects: https://www.audacityteam.org/manual/effects/realtime-effects
- [U2] Audacity 4 manual, Apply your first effect: https://www.audacityteam.org/manual/getting-started/apply-your-first-effect
- [U3] Audacity support, Using realtime effects: https://support.audacityteam.org/audio-editing/using-realtime-effects
