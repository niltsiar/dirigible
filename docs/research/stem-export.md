# Stem export in reference apps

Date: 2026-10-28

This file is reference material for the run `2026-10-28-stem-export` (F73: one file for each track or each role, all from the same start). It records how reference apps export one file for each track or role. It adds to `docs/research/envelope-ducking.md` (section 2.4, FCP roles), `docs/research/mute-solo.md` (mute in a bounce), and `docs/research/export.md`. It does not repeat them.

Tags: (P) primary source, read on 2026-10-28. (S) secondary source. "Unconfirmed": no source found. "Inference:" a conclusion that no source states.

## 1. Hindenburg PRO (the base)

- Hindenburg PRO 2.04 (build 2632, 15 October 2024) added export of tracks as separate files: "It's now possible to export tracks as individual files." [H204] (P).
- The command is in the Export menu: "In the export menu choose: Export Tracks." [H204] (P).
- Unit: one file for each track. "If nothing else is selected, then all tracks will be exported." [H204] (P).
- Track choice: "Selected tracks in the track control will force that only the selected tracks are exported." [H204] (P).
- Range: "Selections made to the workspace will restrict the exported tracks the the selected area on the selected tracks." [H204] (P).
- Unconfirmed: the file names, the folder, the formats, the loudness option, the mute rule, and if each file starts at the range start or at the first clip. The release note does not say, and no manual page with these values was found.
- Hindenburg has no track roles. Auto Level uses region types (narration, music) [see envelope-ducking.md section 1].

## 2. Logic Pro

Sources: the Logic Pro 10.1 help page [L101] (P, old version) and the Logic Pro 9.1.6 manual [L916] (P, old version). The current page (Logic Pro for Mac 12.3 in the version menu) did not give its body text to the fetch tool.

- Command: File > Export > All Tracks as Audio Files. It exports "all tracks (all audio, software instrument, and Drummer tracks) in a project" [L101] (P). "You can export all audio or MIDI regions on multiple tracks as new audio files, one for each track." [L916] (P).
- Unit: one file for each track. For a multi-output instrument: "One File per Track" or "One File per Channel Strip" [L916] (P).
- Formats: "SDII, AIFF, or WAVE"; bit depth "8 Bit, 16 Bit, 24 Bit, or 32 Bit (float)" [L916] (P).
- Bypass Effect Plug-ins: "Select to disable all plug-ins on the source track." [L101] (P).
- Include Volume/Pan Automation: "Select to have volume and pan automation performed on export, with their result influencing the created file. Otherwise, the volume and pan automation is simply copied, but not performed." [L101] (P).
- Normalize: "Off: The exported file is not normalized." "Overload Protection Only" lowers the level only for an overload. "On" normalizes for overloads and for low levels [L101] (P). The option applies to each file. Inference: with On, each stem gets its own gain, so the sum of the stems is no longer the mix.
- Include Audio Tail: "extend the length of the created file to include any instrument release and potential effect tail" [L101] (P).
- Naming: the user enters one name; the pages do not say how each track file is named [L101] [L916] (P). A forum answer describes a pattern field with name elements [ACD] (S).
- Unconfirmed: if muted tracks export, and if each file starts at the project start. A mixing guide of 2026 tells users to export from the project start so that the files align [MET] (S), which suggests that the alignment is a user task. Inference only.

## 3. Final Cut Pro

Source: "Share roles as files", Final Cut Pro for Mac 12.4 [FR] (P). The roles model is in envelope-ducking.md section 2.4.

- Command: the Share window, the Roles pane, the "Roles as" menu [FR] (P).
- "Roles as" options: "QuickTime Movie" ("all of the roles in the project as a single QuickTime movie"), "Multitrack QuickTime Movie" ("the roles you specify as a single QuickTime movie"), "Separate Files" ("each of the video and audio roles you specify as a separate file"), "Video Only as Separate Files", and "Audio Only as Separate Files" [FR] (P).
- Unit: one file for each role, or for each subrole that the user adds as a track [FR] (P).
- Channels: "For any audio track or file in the list, click the Channels pop-up menu" and choose Mono, Stereo, or Surround [FR] (P). So the layout is per file.
- Range: "To share just a portion of a project, you must make a range selection" [FR] (P). With no range, the share is the whole project.
- Unconfirmed on the page: the file names and the loudness. Inference: each role file of one share covers the same project range, because the share has one range.
- Default role of audio with no metadata: Dialogue [RA] (P, cited in envelope-ducking.md).

## 4. Descript

- No stem command. The help page tells the user to solo one track and export it, then to "Repeat this process for all other tracks in your sequence" [DST] (P).
- "Descript will export only the currently soloed track as a mono audio file." [DST] (P).
- Users ask for stems "with each file the exact same length as the others so they align" in a feature request [DFR] (S). Inference: same start and same length is the property that users want from a stem export.

## 5. Audacity (open source, read for the idea only)

Source: the Audacity manual, Export Multiple [AEM] (P).

- Unit: "Export each audio track in your project to a separate file", or one file for each label range [AEM] (P).
- Mute and solo: "Audacity will only export tracks that are not grayed-out." So a muted track, and a track that is not soloed while another is, give no file [AEM] (P).
- Naming: the track name; or a two-digit number and a hyphen before the name ("00-" or "01-"); or a prefix and a number [AEM] (P).
- Existing files: "Overwrite existing files" is off by default. Off: a name that exists gets a number suffix such as "-2". On: the export replaces the file "without prompt" [AEM] (P).
- Unconfirmed on the page: if each track file starts at time 0.

## Summary for the plan

| App | Unit | Same start and length | Muted tracks | What a stem holds | Naming | Normalize |
|---|---|---|---|---|---|---|
| Hindenburg PRO 2.04 | Track (selected tracks, or all) | Unconfirmed; range limits it | Unconfirmed | Unconfirmed | Unconfirmed | Unconfirmed |
| Logic Pro | Track | Unconfirmed; users align by hand | Unconfirmed | Fader and automation (option), plug-ins (option to bypass) | One user name; pattern field (S) | Per file: Off, Overload Protection, On |
| Final Cut Pro 12.4 | Role or subrole | Inference: yes, one range | Not covered | Role mix; channels per file | Unconfirmed | Not covered |
| Descript | None (solo and export by hand) | Users ask for it (S) | Solo by hand | Mono file of the soloed track | Not covered | Not covered |
| Audacity | Track or label | Unconfirmed | Not exported | Track mix | Track name, optional "01-" number | Not covered |

Findings for the defaults of F73:

1. Hindenburg exports one file for each track, of the selected tracks or all tracks, inside the selection range.
2. FCP is the only app with role stems. Its default role for untagged audio is Dialogue.
3. Audacity leaves out muted and unsoloed tracks. This is the same rule as decision 0039.
4. Logic normalizes each file, which breaks the sum of the stems. No reference app documents one gain for all stems.
5. No source confirms that each file starts at the range start. Users ask for it (Descript request). So "all from the same start" is a Dirigible guarantee to test, not a copy of a documented behavior.

## Sources

- [H204] Hindenburg, "PRO Version 2.04 Build 2632" release notes, 2024-10-15: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_04-build-2632/
- [L101] Apple, Logic Pro 10.1 help, "Export tracks as audio files": https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpb27f70f9.html
- [L916] Apple, Logic Pro 9.1.6 user manual, "Exporting Individual or Multiple Tracks as Audio Files": https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_32_section_11.html
- [ACD] Apple Community, "Exporting Session Drums to separate AIFF files for mixing": https://discussions.apple.com/thread/255954408
- [MET] Metropolis, "How To Prepare Your Mix for Mixing" guide, 2026: https://online.thisismetropolis.com/wp-content/uploads/2026/05/METROPOLIS-How-To-Prepare-Your-Mix-for-Mixing-Guide-1.pdf
- [FR] Apple, Final Cut Pro for Mac 12.4, "Share roles as files": https://support.apple.com/en-za/guide/final-cut-pro/verc9c84cdbc/mac
- [RA] Apple, Final Cut Pro, "Assign audio roles during import": https://support.apple.com/guide/final-cut-pro/assign-audio-roles-during-import-verb21791812/mac
- [DST] Descript Help, "Export individual sequence tracks as mono files": https://help.descript.com/export-and-share/sequence-tracks.md
- [DFR] Descript feedback, "Export Speakers as Individual Multitracks for Separate Audio Processing": https://feedback.descript.com/feature-requests/p/export-individual-mp3-audio-tracks-for-a-podcast
- [AEM] Audacity manual, "Export Multiple": https://manual.audacityteam.org/man/export_multiple.html
