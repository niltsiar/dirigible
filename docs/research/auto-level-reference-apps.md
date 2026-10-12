# Automatic level in reference apps

Date: 2026-10-12

This file shows how reference podcast and audio apps do an automatic level command. For each app, it answers five questions: the scope with no selection, the effect of a muted track, the effect of the track fader, static gain or dynamic leveling, and destructive or not. It does not repeat the targets in `docs/research/export-and-dsp.md` section 5 and `docs/research/file-import.md` section 4.

Grades: **P** is a primary vendor page or manual. **S** is a secondary page. **U** is a user post on a forum; "U, staff" is a vendor reply on a forum. "Unconfirmed" means that no source answers. A sentence that starts with "Inference:" is our reading. No probe, build, or on-screen check ran. Adobe help pages refuse a direct fetch. Their quotes come from a dated Internet Archive copy.

## 1. Hindenburg PRO, Journalist, Lite, Narrator

- **What it changes.** Auto Level sets the gain of the region. The 1.21 guide edits the volume of a region with its top gain line, and says: "if you wish to set the level back to the Auto level then let it snap" [HJ p. 31] (P). "Auto-level simply raises or lowers the gain of the clip ... it's not applying compression or limiting, or changing the original soundfile in any way" [TR11] (S, 2011). Track volume is a separate control: "Adjust the overall volume for the track" [HJ p. 45] (P).
- **When it runs.** "When importing audio into Hindenburg Journalist, all levels are automatically set" [HJ p. 40] (P). It also runs at the stop of a record [TL21] [BZ] (S). Preference: "Perform automatic leveling after import and record" [TL21] (S). Menu command: "Select the regions you wish to analyze", then Tools > Auto Level, ⌘L [HJ p. 41] (P). The PRO 2 shortcut page has "Auto Levels" [HPS] (P).
- **Target.** Speech and music are detected per clip [HFH] (P). EU mode: Peak -9 QPPM, Narration -21 LUFS, Music -23 LUFS. UK and US modes have other values [HJ p. 42] (P). The current page says "Dialogue peaks at -9 dB on a QPPM scale" and "Music peaks at -15 dB" [HFH] (P).
- **Several clips.** Staff answer: "Simply select all the clips and use the auto-level function in the Tools menu" [UV] (U, staff, 2019). A user reports: "If I select a group of clips an press cmd+L each clip is levelled individually" [UV] (U). Inference: one gain per clip, measured on that clip only.
- **No selection.** Unconfirmed. No source says what ⌘L does with no selected region.
- **Muted track.** Unconfirmed.
- **Track fader moved.** Unconfirmed. Inference: the command measures the clip and writes the region gain, so the track volume does not change the result. Not checked.
- **Static or dynamic.** Static: one gain for the whole clip. "The level adjustments are applied to the entire clip as it appears in the timeline" [TR11] (S).
- **Destructive.** No. "It's completely non-destructive" [TR11] (S). [HJ p. 31] (P) agrees: the level can snap back.
- **Limit.** Long clips: "you may want to break it into smaller pieces after importing it" [TR11] (S). No gain limit is published (unconfirmed).
- **Magic Levels is a different command.** The shortcut page gives "Shift Ctrl L" and "Ctrl L" for Auto Levels; it shows Windows keys only [HPS] (P). It "Applies loudness-based gain riding" and "Automatically ducks music under speech" [HFH] (P). This is dynamic leveling. Release 2.02 build 2570 fixed "Magic Levels not detecting some speech" [HR2570] (P).
- **Voice Profiler is not a level command.** "Voice Profiles create a tonal reference. New recordings are aligned automatically" [HFH] (P). It changes the tone, not the level.
- **Loudness at publish is a separate step.** The export has "Loudness normalisation" to -23, -24, -16, -18, or -14 LUFS [HFH] [HPS] (P). Auto Level sets the clips; the export sets the mix.
- **Lite and Narrator.** A vendor video is titled "Why is Auto level one of the best tools in Hindenburg Lite" [HYL] (S, title only, not watched). Inference: Lite has the command. No text page for Lite or Narrator was found (unconfirmed). The PRO 2 release notes 2.0 to 2.05 have no Auto Level entry [HRN] (P, full text search).

## 2. Descript

- **What it changes.** "Auto-leveling nudges every clip's loudness to a consistent target (around –16 dB)" [DAL] (P). The project setting "Perform automatic leveling on clips" will "Automatically apply -16dB loudness normalization to all audio in your project" [DPS] (P). The vendor writes "dB", not "LUFS".
- **When it runs.** "It's on by default", for all projects (App settings) or one project (Project settings) [DAL] (P). A clip has its own "Auto-level" toggle in the Properties panel [DAL] (P).
- **No selection.** The setting levels all clips in the project [DPS] (P). It is a setting, not a command.
- **Muted track, track volume.** Unconfirmed. Volume and mute are separate controls per layer and per clip [DVP] (P).
- **Static or dynamic.** Inference: static per clip, because the page says "loudness normalization" and "every clip's loudness". The troubleshooting text says a spike can "throw off leveling for that section" [DAL] (P). Not checked.
- **Destructive.** Inference: no, because a toggle turns it off. Not checked.
- **Studio Sound** is not a level command. It reduces "background noise, echo, and other distractions" and "affects every instance of that file across your project" [DSS] (P).

## 3. Auphonic

- **What "leveler" means.** The Adaptive Leveler "corrects level differences between several speakers, or between music and speech and applies dynamic range compression". It "corrects loudness differences between segments within one file". The Global Loudness Normalization corrects "loudness differences between files" [AUS] (P).
- **Per speaker.** It amplifies "quiet speakers in speech segments to achieve equal levels between speakers". It excludes "noise, wind, breaths, silence" from amplification [AUS] (P).
- **Multitrack.** It analyses "which parts of each audio track should be leveled, how much they should be leveled". "Background segments ... won't be amplified". Ducking "reduces the level of a track if speakers in other tracks are active" [AUM] (P).
- **No selection.** Not applicable: the service processes the whole uploaded file or production.
- **Muted track, track fader.** Unconfirmed. The multitrack page does not name muted tracks [AUM] (P).
- **Static or dynamic.** The leveler is dynamic. The loudness normalization is static [AUS] (P).
- **Destructive.** Inference: no, the web service writes a new result file. The page does not say it.

## 4. Adobe Audition

- **Match Clip Volume (multitrack).** "Ctrl-click (Windows) or Command-click (Mac OS) to select multiple clips. Choose Clip > Match Clip Volume." Methods: Loudness, Perceived Loudness, Peak Volume, Total RMS Amplitude, and a Target Volume [ACV] (P).
  - No selection: the steps start with a selection [ACV] (P). Result with no selection: unconfirmed.
  - Muted track, track fader: unconfirmed.
  - Static: one target volume per clip [ACV] (P).
  - Destructive: no. "Because the Multitrack Editor is nondestructive, this adjustment is completely reversible" [ACV] (P).
- **Match Loudness panel (files).** "Drag one or more audio files and drop them in the panel", Scan, choose a standard in Match To, then Run, with "Maximum True Peak Limiting" [AML] (P).
  - Scope: the files in the panel, not a timeline selection [AML] (P).
  - Static gain plus a true-peak limiter [AML] (P).
  - Destructive: yes (P, through a link from [ACV]). [ACV] points to the file procedure "To instead permanently change the volume of source files". [AML] itself does not say it.

## 5. Adobe Premiere Pro

- **Auto-Match.** "Select an audio clip in the timeline and select Window > Essential Sound. Make sure you have automatically tagged the audio type." Then Loudness > Auto-Match. "The clip's loudness level, measured in Loudness Units relative to Full Scale (LUFS), appears below the Auto-Match button" [PAM] (P, page of 2025-08-22).
- **What it changes.** It sets the clip gain, not peaks or keyframes [PCM] (U). Default dialogue target -23 LUFS [PCM] (U). The help page gives no target (unconfirmed in P).
- **No selection.** The steps start with a selected clip [PAM] (P). Result with no selection: unconfirmed.
- **Muted track, track volume.** Unconfirmed. "Adjust track volume" is a separate help page [PAM] (P, page links).
- **Static or dynamic.** Static per clip [PCM] (U). Very short clips can fail to measure [PCM] (U).
- **Destructive.** Inference: no, because clip gain is a clip property. Not checked.

## 6. Logic Pro

- **Normalize Region Gain.** "In the Logic Pro Tracks area, select one or more audio regions." Functions > Normalize Region Gain, Control-Option-G. Process: "all regions are processed equally, regions are processed equally per track, or regions are processed individually". Method: Peak or Loudness. Target Level in dB or LUFS [LN] (P).
- **No selection.** The command works on "selected audio regions" [LN] (P). A click on the track header can select all regions of the track, when "Select regions on track selection" is on [LN] (P). Result with no selection: unconfirmed.
- **Muted track, track fader.** Unconfirmed. Region gain is a yellow line on the region, separate from the channel strip [LG] (P).
- **Static or dynamic.** Static: one gain per region, per track, or for all [LN] (P).
- **Destructive.** No. "The Normalize Region Gain menu command is nondestructive: the original file isn't altered, only the normalized region" [LN] (P).
- Logic Pro is installed on this Mac, so an on-screen check is possible.

## 7. Final Cut Pro

- **Loudness enhancement.** "Loudness: Improves the main audio signal and makes it more uniform." "The Amount slider adjusts the overall loudness (compression) of the clip, and the Uniformity slider adjusts the dynamic range affected" [FEA] (P).
- **No selection.** "Select an audio clip or a video clip with audio in the timeline", then Modify > Enhance Audio, Option-Command-A [FEA] (P). It "works on the component level, not the clip level" [FEA] (P). Result with no selection: unconfirmed.
- **Muted clip or role, track volume.** Unconfirmed. Final Cut Pro has no track fader; roles replace tracks (see `docs/research/final-cut-pro.md`).
- **Static or dynamic.** Dynamic: compression [FEA] (P).
- **Destructive.** Inference: no, because a checkbox turns the enhancement off [FEA] (P). Not checked.
- **Match Audio is not a level command.** It "uses equalization (EQ) to let you match a selected clip's sound to that of another clip" [FMA] (P).

## 8. Pro Tools

- **Clip gain normalize.** No vendor page for a built-in "Clip Gain Normalize" command was found (unconfirmed). A third-party AudioSuite plug-in writes clip gain to a target [QAD] (S).
- **Clip gain.** It adjusts "the volume of individual audio clips ... without affecting the track's overall volume". The Clip Gain Fader gives "static gain changes (where the entire clip has the same gain setting)" [PCG] (P).
- **AudioSuite Normalize.** It "optimizes the volume level of an audio selection" and "preserves dynamics by uniformly increasing (or decreasing) amplitude" [PTN] (P). The body of its section "Normalizing Multiple Clips" was not retrieved (unconfirmed).
- **No selection.** The plug-in works on "an audio selection" [PTN] (P). Result with no selection: unconfirmed.
- **Muted track, track fader.** Unconfirmed.
- **Static or dynamic.** Static [PTN] (P).
- **Destructive.** It depends on File Mode. "Overwrite Files ... will overwrite and permanently modify the original source audio files." "Create Individual Files ... will create new audio files" [PTA] (P).

## 9. Audacity

- **Loudness Normalization.** Effect > Volume and Compression > Loudness Normalization. "Perceived loudness" with a default of -23 LUFS, or RMS [ALN] (P).
- **No selection.** Preference "Select all audio, if selection required: If you select no audio before applying an effect, the effect will be automatically applied to all audio in all tracks. Default setting for this is "off"" [ATB] (P). Inference: with the default, the effect asks for a selection. The help page for that message returned 404. Not checked.
- **Muted track, track gain.** Unconfirmed.
- **Static or dynamic.** Static: one gain, and both channels of a stereo track change "by the same amount" by default [ALN] (P).
- **Destructive.** Inference: yes, the effect changes the clip samples, with undo. The manual says an effect on a time-stretched clip is "automatically rendered" [ALN] (P). Not checked further.

## Summary

| App and command | No selection | Muted track | Track fader | Static or dynamic | Destructive |
|---|---|---|---|---|---|
| Hindenburg Auto Level (⌘L) | Unconfirmed | Unconfirmed | Unconfirmed; separate control (P) | Static per clip | No (P, S) |
| Hindenburg Magic Levels | Unconfirmed | Unconfirmed | Unconfirmed | Dynamic (P) | Unconfirmed |
| Descript auto-leveling | Whole project, a setting (P) | Unconfirmed | Unconfirmed | Static per clip (Inference) | No (Inference) |
| Auphonic Adaptive Leveler | Whole file | Unconfirmed | Unconfirmed | Dynamic (P) | No (Inference) |
| Audition Match Clip Volume | Selection (P) | Unconfirmed | Unconfirmed | Static (P) | No (P) |
| Audition Match Loudness | Files in panel (P) | Not applicable | Not applicable | Static plus limiter (P) | Yes (P, through [ACV]) |
| Premiere Auto-Match | Selection (P) | Unconfirmed | Unconfirmed | Static (U) | No (Inference) |
| Logic Normalize Region Gain | Selection (P) | Unconfirmed | Unconfirmed; separate (P) | Static (P) | No (P) |
| Final Cut Pro Loudness | Selection (P) | Unconfirmed | No track fader | Dynamic (P) | No (Inference) |
| Pro Tools AudioSuite Normalize | Selection (P) | Unconfirmed | Unconfirmed; clip gain separate (P) | Static (P) | File Mode (P) |
| Audacity Loudness Normalization | Selection; all with a preference, off by default (P) | Unconfirmed | Unconfirmed | Static (P) | Yes (Inference) |

Findings:

- No source shows an app that compensates the track fader. Pro Tools [PCG] (P) and Logic [LG] (P) keep clip or region gain separate from the track volume.
- No source shows an app that skips muted tracks. Every sourced command picks its clips by selection, not by track state.
- No sourced menu command levels everything with no selection. Descript levels all clips through a setting. Hindenburg levels each clip at import and record. Audacity levels all audio only with a preference that is off by default.
- "Level" has two meanings. Hindenburg Auto Level and Descript auto-leveling set one static gain per clip. Auphonic Adaptive Leveler, Final Cut Pro Loudness, and Hindenburg Magic Levels ride the gain over time. A tester who expects a dynamic leveler expects the second group. Hindenburg Auto Level, the model of Dirigible, is in the first group.

## Open questions for the plan

- Hindenburg ⌘L with no selected region. This is the most common gesture of the command. Hindenburg is not installed on this Mac. Check: open a session with two clips, click empty space, press ⌘L, and read the gain tooltip of each clip.
- Hindenburg ⌘L on a clip of a muted track. Check: mute the track, select its clip, press ⌘L, and read the tooltip.
- Hindenburg ⌘L with the track volume at -6 dB. Check: set the volume, select the clip, press ⌘L, and compare the tooltip with the value at 0 dB.
- Logic Normalize Region Gain with no selection, on a muted track, and with the fader at -6 dB. Logic Pro is installed, so these three checks take minutes.

## Sources

- [HJ] Hindenburg Journalist PRO 1.21 user guide, vendor PDF on a third-party host, pages 31, 40 to 42, 45: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf (P)
- [HFH] Hindenburg PRO feature highlights: https://hindenburg.com/academy/lessons/feature-highlights/ (P)
- [HPS] Hindenburg PRO 2 shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ (P)
- [HR2570] Hindenburg PRO 2.02 build 2570 release notes: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2570/ (P)
- [HRN] Hindenburg PRO release notes index, versions 2.0 to 2.05: https://hindenburg.com/support/release-notes/hindenburg-series/ (P)
- [UV] Hindenburg UserVoice, "Group auto level functionality", 2019: https://hindenburg.uservoice.com/forums/224350-general/suggestions/38619355-group-auto-level-functionality (U, staff reply and user comments)
- [HYL] Hindenburg, YouTube video "Why is Auto level one of the best tools in Hindenburg Lite", title only: https://www.youtube.com/watch?v=6LD7F0n5Ojg (S)
- [TR11] Jeff Towne, Transom, "Hindenburg Journalist Update", 2011: https://transom.org/2011/hindenburg-journalist-update/ (S)
- [TL21] Transom, "The Audio Producer's Guide to Loudness", 2021: https://transom.org/2021/the-audio-producers-guide-to-loudness/ (S)
- [BZ] Buzzsprout, Hindenburg Journalist Pro review: https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough (S)
- [DAL] Descript Help, "Auto-leveling": https://help.descript.com/effects-animations-transitions/auto-leveling (P)
- [DPS] Descript Help, "Project settings": https://help.descript.com/working-in-projects/project-settings (P)
- [DVP] Descript Help, "Adjust volume and pan audio": https://help.descript.com/effects-animations-transitions/volume-pan (P)
- [DSS] Descript Help, "Studio Sound": https://help.descript.com/effects-animations-transitions/studio-sound (P)
- [AUS] Auphonic, "Singletrack Algorithms", Adaptive Leveler: https://auphonic.com/help/algorithms/singletrack.html#adaptive-leveler (P)
- [AUM] Auphonic, "Multitrack Algorithms": https://auphonic.com/help/algorithms/multitrack.html (P)
- [ACV] Adobe Audition, "Match, fade, and mix clip volume", page of 2024-04-16, archived copy: https://web.archive.org/web/20260609225604/https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/clip-volume-matching-fading-mixing.html (P)
- [AML] Adobe Audition, "Match loudness", archived copy: https://web.archive.org/web/20260116073859/https://helpx.adobe.com/audition/using/match-loudness.html (P)
- [PAM] Adobe Premiere, "Auto-match audio loudness", page of 2025-08-22, archived copy: https://web.archive.org/web/20260105190123/https://helpx.adobe.com/premiere/desktop/add-audio-effects/adjust-volume-and-levels/auto-match-audio-loudness.html (P)
- [PCM] Adobe Community, "Premiere Pro does not AutoMatch loudness correctly": https://community.adobe.com/questions-729/premiere-pro-does-not-automatch-loudness-correctly-1409301 (U, search summary only)
- [LN] Logic Pro, "Normalize audio regions in the Tracks area": https://support.apple.com/guide/logicpro/normalize-audio-regions-in-the-tracks-area-lgcp663fdd13/mac (P)
- [LG] Logic Pro, "Change the gain of audio regions in the Tracks area": https://support.apple.com/guide/logicpro/change-gain-audio-regions-tracks-area-lgcp8e4c781d/mac (P)
- [FEA] Final Cut Pro, "Enhance audio": https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac (P)
- [FMA] Final Cut Pro, "Match audio": https://support.apple.com/guide/final-cut-pro/ver1632db40/mac (P)
- [PCG] Avid, Pro Tools user guide, "Clip Gain": https://www.avid.com/pro-tools/user-guide/clip-gain (P)
- [PTN] Avid, Pro Tools 12.3 help, "Other AudioSuite Plug-In Utilities: Normalize": https://apps.avid.com/proToolsFirstHelp/version12.3/enu/Pro%20Tools%20First%20Help/OtherAS.52.06.html (P)
- [PTA] Avid, Pro Tools 12.3 help, "Using AudioSuite Plug-Ins": https://apps.avid.com/proToolsFirstHelp/version12.3/enu/Pro%20Tools%20First%20Help/Proc1.AudioSuite.36.27.html (P)
- [QAD] Barry Rudolph, "Quiet Art Defaulter Plug-In": https://barryrudolph.com/stellar/quiet_art_defaulter.html (S, search summary only)
- [ALN] Audacity Manual, "Loudness Normalization": https://manual.audacityteam.org/man/loudness_normalization.html (P)
- [ATB] Audacity Manual, "Tracks Behaviors Preferences": https://manual.audacityteam.org/man/tracks_behaviors_preferences.html (P)
