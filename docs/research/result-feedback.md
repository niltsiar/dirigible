# Result feedback in reference apps

Date: 2026-11-24

Question: How do pro macOS media apps tell the user the result of a task?
Cases: (a) export or share finished, (b) background process finished, (c) non-fatal problem in the result, (d) disk-space or device warning before or during recording.
Apps: Hindenburg PRO (base reference), Final Cut Pro (FCP), Logic Pro, GarageBand.
Sources are primary only: Apple user guides and Hindenburg pages. No forum posts.

Method notes:
- The author read the Apple guide pages as raw HTML. Each Apple quote below was matched in the page text.
- Hindenburg PRO has no written manual on hindenburg.com. Its "guides" are short entries with a video each. The entries load by script, so the author read them through a page reader, not raw HTML. Those quotes have one read only.
- A guide sentence that is silent on feedback means the guide does not document any. The app may still show something. Only a test in the real app can confirm that. This run ran no probe.
- Typographic quotes in one source quote (R19) are written as straight quotes.

## Findings

| ID | App | Case | UI element | Quote | Source URL | Verdict |
|----|-----|------|------------|-------|------------|---------|
| R1 | FCP | a, export or share finished | Background Tasks window for progress, then a "notification" | "When you share a project, you can monitor the progress of the transcode in the Background Tasks window, and you can continue to work in Final Cut Pro while the file is transcoded. When transcoding is complete, a notification appears." | https://support.apple.com/guide/final-cut-pro/view-the-status-of-shared-items-ver1632ec4a/mac | FOUND |
| R2 | FCP | a, export or share finished | Share inspector (in-window history) | "You can view the share history of a project and locate shared projects using the Share inspector." | https://support.apple.com/guide/final-cut-pro/view-the-status-of-shared-items-ver1632ec4a/mac | FOUND |
| R3 | FCP | a, export or share finished | Setting in the Share window: the user picks the follow-up action | "Click the Action pop-up menu in the Settings pane, then choose what happens when the export is complete." | https://support.apple.com/guide/final-cut-pro/share-to-apple-devices-ver3675a4f8c/mac | FOUND |
| R4 | FCP | b, background process (render, transcode, share) | Background Tasks window with percent | "If you want to see the progress of any of the background processes, you can open the Background Tasks window, which shows the tasks being performed and the percentage of completion." | https://support.apple.com/guide/final-cut-pro/view-background-tasks-ver64e71609/mac | FOUND |
| R5 | FCP | b, analysis finished | Background Tasks window for progress. No completion message in the guide. | "The files will be analyzed in the background after the import is complete." and "You can see the status of transcoding and other background processes in the Background Tasks window." | https://support.apple.com/guide/final-cut-pro/analyze-your-media-vera60734a4/mac | NOT FOUND for a completion message. Progress window FOUND. |
| R6 | FCP | b and c, audio analysis and enhancement result | Yellow marker in the Audio inspector (in-window, no dialog) | "If the clip contains moderate problems, these appear in yellow next to Audio Analysis in the Audio Enhancements section of the Audio inspector after the clip is imported." | https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac | FOUND |
| R7 | FCP | c, non-fatal problem (missing media) | Red frames and a yellow alert triangle on the clip, in the timeline or event | "When you see red frames and a yellow alert triangle in the timeline or an event, it means that part of your project or event is missing." | https://support.apple.com/guide/final-cut-pro/alert-icons-verd1f977a7/mac | FOUND |
| R8 | FCP | d, disk-space or device warning when recording | Not documented | The voiceover page has no sentence about disk space or a warning. | https://support.apple.com/guide/final-cut-pro/record-voiceovers-verc1faa9c5/mac | NOT FOUND |
| R9 | Logic Pro | a, export finished (bounce) | Bounce dialog, then nothing documented. The guide gives no completion message. | "Depending on the length and complexity of the project, the bounce process may take a few moments to complete." | https://support.apple.com/guide/logicpro/bounce-a-project-to-an-audio-file-lgcp785a41c3/mac | NOT FOUND |
| R10 | Logic Pro | b, background process (Stem Splitter) | Nothing. The visible change in the Tracks area is the feedback. | "A summing stack is created below the track with the selected audio region. The subtracks of the summing stack contain the extracted stems. The original region is muted so that you can listen to the extracted stems immediately." | https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac | FOUND |
| R11 | Logic Pro | b, background process (Freeze) | State of the Freeze button (blue), plus a dialog when the user edits a frozen track | "When selected, the Freeze button appears blue." and "If you try to make changes to a frozen track, a dialog informs you that the track is frozen." | https://support.apple.com/guide/logicpro/freeze-tracks-lgcpf1cbfd51/mac | FOUND |
| R12 | Logic Pro | c, clipped output (bounce normalize) | A setting that prevents clipping. The guide names no message. | "Overload Protection Only: Downward normalization takes place only for overloads (levels above 0 dB, which would lead to clipping), but no normalization takes place for lower levels." | https://support.apple.com/guide/logicpro/bounce-a-project-to-an-audio-file-lgcp785a41c3/mac | NOT FOUND for a message |
| R13 | Logic Pro | c, missing files | Icon in the Icon column of the Project Audio Browser. A "missing files alert" is named for the iPad app only. | "Icon column: Displays icons to indicate missing or timestamped files, files that follow the project tempo, or files that contain tempo information." and "If you try to open a Logic Pro for Mac project in Logic Pro for iPad and you get a missing files alert, consolidate your project on your Mac, then share your project again." | https://support.apple.com/guide/logicpro/lgcpc788cc57/mac and https://support.apple.com/en-us/101624 | FOUND for the icon. NOT FOUND for the Mac alert text. |
| R14 | Logic Pro | d, disk-space check before recording | Nothing automatic. The guide tells the user to check. | "You should also check hardware settings such as the system memory requirement and disk space." | https://support.apple.com/guide/logicpro/before-recording-audio-lgcpb19de615/mac | NOT FOUND for a warning |
| R15 | Logic Pro | d, device or load problem during recording | Alert (system overload) that interrupts recording. Disk speed can cause it. It is not a free-space warning. | "If your Logic Pro project has a lot of audio tracks, software instruments, or plug-ins, you might get a system overload alert that interrupts playback or recording." | https://support.apple.com/en-us/108295 | FOUND |
| R16 | GarageBand | a, export finished | Export dialog, then nothing documented. | "The entire project or the selected part of the project is exported as an audio file." | https://support.apple.com/guide/garageband/export-songs-to-disk-gbnd7cbf5ed9/mac | NOT FOUND for a completion message |
| R17 | Hindenburg PRO | a, export finished | Not documented. The guide entry describes the command only. | "Export your session as a mixed down file. You can export in a number of different file formats." | https://hindenburg.com/academy/guides/guides-hindenburg-pro/ | NOT FOUND |
| R18 | Hindenburg PRO | b, background process (loudness normalize, noise reduction, strip silence) | Not documented. Loudness normalization is an export option. The noise reduction page is a video with no text. | "Audio export options: File Format, File Encoding, Loudness Normalization, Username , and Password" | https://hindenburg.com/academy/guides/guides-hindenburg-pro/ (noise reduction video page: https://hindenburg.com/data/youtube/videos/hindenburg-pro-how-to-remove-audio-noise-one-dial-plugin-noise-reduction/) | NOT FOUND |
| R19 | Hindenburg PRO | c, non-fatal problem (missing audio) | Red outline on the region, and a prompt on session open to locate the files | "Point to audio for Region -Missing Audio red outline" and "This will cause a error when you later try and open a session and are asked to "locate missing audio files"" | https://hindenburg.com/academy/guides/guides-hindenburg-pro/ and https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound | FOUND |
| R20 | Hindenburg PRO | c, clipped output | Not documented | The guide index has no entry about clipping or an export warning. | https://hindenburg.com/academy/guides/guides-hindenburg-pro/ | NOT FOUND |
| R21 | Hindenburg PRO | d, disk-space warning | A System Monitor the user can show. No warning documented. | "Shows / Hides the System Monitor. Monitor the CPU & Disk Usage." | https://hindenburg.com/academy/guides/guides-hindenburg-pro/ | FOUND for the meter. NOT FOUND for a warning. |
| R22 | GarageBand | d, disk-space or device warning | Not checked in a guide page. The author read only a search summary of the troubleshooting page. | No quote. | https://support.apple.com/en-us/102247 | NOT FOUND |

## Summary

Common pattern in the documented behavior:
- A finished task has no modal message in any guide. The guides show the change itself (R10, R11) or an inspector or browser marker (R6, R13, R19).
- FCP is the only app with a documented completion signal. It shows progress in the Background Tasks window, then one "notification" (R1, R4). The guide does not say if this is a macOS notification or an in-app banner. That detail is an inference, not a finding.
- A non-fatal problem in the result shows as a persistent marker on the affected item: red frames and a yellow triangle (R7), a yellow line in the inspector (R6), a red outline (R19), an icon in a browser column (R13). It does not show as an alert after the task.
- An alert appears only when work stops or the user must act: the system overload alert in Logic (R15) and the locate-files prompt in Hindenburg (R19).
- No guide documents a disk-space warning before or during recording (R8, R14, R21). Logic tells the user to check disk space by hand (R14). Hindenburg gives a System Monitor (R21).
- The Hindenburg PRO guides are silent on a result message for export, normalize, noise reduction, and clipping (R17, R18, R20). No test in the real app was made. So no observation of Hindenburg PRO backs the banner rule or its exceptions. The rule is a HIG and Hallmark choice.

Limits:
- A guide that is silent is not proof that the app shows nothing. A test in the real app can confirm each NOT FOUND.
- The GarageBand disk-space case (R22) and the Hindenburg guide entries (R17 to R21) have weaker evidence, as the method notes say.

## Sources

- Final Cut Pro, view the status of shared items: https://support.apple.com/guide/final-cut-pro/view-the-status-of-shared-items-ver1632ec4a/mac
- Final Cut Pro, view background tasks: https://support.apple.com/guide/final-cut-pro/view-background-tasks-ver64e71609/mac
- Final Cut Pro, share to Apple devices: https://support.apple.com/guide/final-cut-pro/share-to-apple-devices-ver3675a4f8c/mac
- Final Cut Pro, analyze your media: https://support.apple.com/guide/final-cut-pro/analyze-your-media-vera60734a4/mac
- Final Cut Pro, enhance audio: https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac
- Final Cut Pro, alert icons: https://support.apple.com/guide/final-cut-pro/alert-icons-verd1f977a7/mac
- Final Cut Pro, record voiceovers: https://support.apple.com/guide/final-cut-pro/record-voiceovers-verc1faa9c5/mac
- Logic Pro, bounce a project to an audio file: https://support.apple.com/guide/logicpro/bounce-a-project-to-an-audio-file-lgcp785a41c3/mac
- Logic Pro, Stem Splitter: https://support.apple.com/guide/logicpro/extract-vocal-instrumental-stems-stem-lgcp61bae908/mac
- Logic Pro, freeze tracks: https://support.apple.com/guide/logicpro/freeze-tracks-lgcpf1cbfd51/mac
- Logic Pro, Project Audio Browser: https://support.apple.com/guide/logicpro/lgcpc788cc57/mac
- Logic Pro, work on a project on iPad and Mac (missing files alert): https://support.apple.com/en-us/101624
- Logic Pro, before recording audio: https://support.apple.com/guide/logicpro/before-recording-audio-lgcpb19de615/mac
- Logic Pro, avoid system overloads: https://support.apple.com/en-us/108295
- GarageBand, export songs to disk: https://support.apple.com/guide/garageband/export-songs-to-disk-gbnd7cbf5ed9/mac
- GarageBand, if GarageBand is not working on your Mac (not read in full): https://support.apple.com/en-us/102247
- Hindenburg PRO guides index: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- Hindenburg noise reduction video page (no text): https://hindenburg.com/data/youtube/videos/hindenburg-pro-how-to-remove-audio-noise-one-dial-plugin-noise-reduction/
- Hindenburg support article, missing audio files: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- Hindenburg release notes (no entries found in page text): https://hindenburg.com/support/release-notes/
