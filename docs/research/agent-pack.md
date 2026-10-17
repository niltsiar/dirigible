# Research: reference behavior for the agent pack (heal, seamless crossfade, text chapters, unused media)

Date: 2026-10-17

This file answers four questions of run `2026-10-17-agent-pack` for the planner. It does not repeat the repo research. It cites it with the tags [R-REC], [R-FI], [R-CH], [R-P2], [R-PF], [R-EC], [D35], and [D36] (see Sources). "Inference:" marks our reading of a source. "(unconfirmed)" marks a claim that no source confirmed. "(S)" marks a secondary source (a forum or a search summary). A vendor page that a fetch refused is named as not read.

Method note. The Pro Tools Reference Guide 2025.10 and the REAPER User Guide 7.81 are PDF files. A local script read their text. The page numbers below are the printed page numbers. The REAPER change log (`whatsnew.txt`) and the Audacity 3.7.8 source file are first-party text.

## 1. Heal or join of touching clips from one source

### Pro Tools: Heal Separation

- The command "returns separated clips to their original state" if the clips are "still next to each other" and "their relative start and end points have not changed since the separation" [PT p. 892].
- It does not work after a trim, or after the clips move apart. "It is not possible to heal two clips created from different audio files." [PT p. 892]
- Gesture: a Selector selection across part of the first clip, the whole separation, and part of the second clip. Then Edit > Heal Separation, or Command+H [PT p. 892].
- If heal fails, the guide says to delete one clip and trim the other back to full length. Or delete both and drag the original clip from the Clip List [PT p. 892].
- The text names two clips. It says nothing on more than two pieces, on clip gain, on fades or crossfades at the join, or on a new file (unconfirmed for each).
- Inference: heal writes no file. The text describes a return to the original clip, and Consolidate is the command that writes a file: "a new audio file is written" [PT p. 900].
- Clip gain belongs to each clip: "Clip gain is applied on a clip-by-clip basis" [PT p. 1227]. The guide does not say what heal does with two different clip gains (unconfirmed).

### REAPER: Heal splits in items, and Glue

- Quick reference: "To join split items together (heal): Select items. Choose Heal splits in items from the context menu." "To join selection of items (glue): Choose Glue from the context menu (renders to new file)." [RG p. 124]
- Glue "creates a new media item: the original items are not damaged". Glue can incorporate "item gain and item take FX into the new media item" [RG p. 148].
- The guide gives no condition for heal (contiguous in source, same track) and no rule for different item volumes (unconfirmed).
- Change log, v1.888 (2007-08-20): "new action: heal splits in selected items (can heal fades and overlaps and gaps too)" [RW]. Inference: heal in REAPER does not need exactly touching items.
- Change log, v5.95 (2018-09-10): "Heal splits: preserve item fade-out shape/curve". v5.34 (2017-02-24): a crash fix "when healing take automation". v7.0 (2023-10-16): heal works "even if one or both contains empty takes" and "even if items do not have the same active take lane". v7.0 also refuses to heal "an unlooped item with a copy of itself" [RW].
- Glue is the command that writes a new file. Heal is not described as rendering (unconfirmed that it never renders).

### Logic Pro: Join Regions

- Conditions: "untransposed audio regions"; the regions "must be adjacent to each other on the same track". Regions from audio Apple Loops, and transposed regions, "can't be joined". Compressed files become AIFF [LJ].
- Default: "Logic Pro creates a new file for the joined audio (called a mixdown) that replaces the original regions." The file goes to the disk and to the Project Audio Browser [LJ].
- Exception: "If several (mono or stereo) regions on the same track are from the same original region, and in the same relative positions, no mixdown occurs. In this case, a single region is created." [LJ] This is the touching-pieces case. The answer to "new file?" is no.
- Several regions: the text says "several regions". Gestures: Edit > Join > Regions, or the Glue tool. "Join regions per track" makes one joined region on each track that has selected regions [LJ].
- Overlapping regions on a track: no mixdown rule applies. Logic "asks to create a new audio file". The regions are "mixed together, with no changes to volume" [LJ].
- Mixdown from two or more tracks uses "the current pan and volume values for the individual tracks" [LJ].
- A mixdown can crossfade the regions. Two preferences set it: Crossfade Time (ms) and Crossfade Curve. "To obtain a linear crossfade, set this value to 0." The preset is Time = 0 ms, Curve = 0 (linear) [LJ]. The text says nothing on region gain in the no-mixdown case (unconfirmed).

### Audacity: Join

- Manual: "If you select an area that overlaps one or more clips, they are all joined into one large clip." "Regions in-between clips become silence." The page says nothing on clip gain or envelopes [AM].
- Source, Audacity 3.7.8, `libraries/lib-wave-track/WaveTrack.cpp`, `WaveTrack::Join` (line 2323) [AS]:
  - It joins every clip that intersects the selection. It returns if fewer than two clips intersect.
  - If the pitch or speed differs, it applies them first.
  - It makes a new clip and pastes each source clip into it in start order (`newClip->Paste`). It fills a gap longer than one sample with silence.
  - `RebuildJoinedEnvelope` (before line 2323) builds one envelope for the new clip. At a seam where the two values differ, the code keeps both points: "Non-coincident seam, or coincident with different values: keep both points."
  - Inference: a gain difference at a touching seam stays as a step in Audacity. The code does not make a ramp.
- The code shows no check that the clips are contiguous in one source file. It joins any clips in the selection [AS].
- A forum report from version 2.2.1 says a join damaged the envelope of the right clip. The reply called it a bug (S, not rechecked on 3.7) [AF].

### Hindenburg PRO: Merge

- The PRO guide list has no Join, Heal, or Glue entry [HP] (and [R-REC] section 5). It has "Edit - Merge: Creates a Smart Region with sub regions", "Regions - Merge: Merge regions into a Smart Region", and "Regions - Unmerge" [HP].
- The shortcut is Shift+Ctrl M for Merge and for Unmerge [HK]. The macOS region menu shows Merge as Shift-Cmd-M [R-EC].
- The vendor says: "treat multiple clips as a single editable region ... since Hindenburg is non-destructive, you can always un-merge" [HS].
- Inference: Merge groups sub regions. It does not render a new file, and it keeps the gain of each sub region. No page states the conditions, the gain rule, the fade rule, or the file rule (unconfirmed). `docs/research/podcast-features.md` F24 also marks this unconfirmed [R-PF].
- Hindenburg has no documented heal that returns two pieces of one file to one plain region.

### Adobe Audition: Merge Clips

- No Adobe help page was reached. The Audition multitrack help page that was read has no "merge" entry [AUA].
- (S) Adobe Community: a merged clip is "a new clip with no way back". A second user says the command "warns you", that "the original clips are all still there" in the files list, and that to go back you "re-open the session". A third says: "the only time a new permanent file is created is when you Mixdown or Export" [AC1].
- (S) A search summary of a feature request (not read): Merge Clips needs the clips on one track [AC2].
- Whether Merge Clips writes a file, and how it treats gain, is unconfirmed.

### Cross-check with the Dirigible model

- A seamless join cannot hold a crossfade: the model refuses it (`.crossfadeAtSeamlessJoin`) [D36 "Seamless join"]. An edge at a butt join gets no fade from Command-F, and the fade handle skips it [D35]. So fades and crossfades at a heal join do not exist in the model. No vendor case is needed for that part.
- A clip has one gain value. Inference: a heal of two pieces with different gains cannot keep both gains in one clip.

Default for Dirigible: Heal two clips only when they are on one track, touch on the timeline, and the second plays on from the next frame of the same file. Write no new file (Pro Tools [PT p. 892], Logic no-mixdown case [LJ], REAPER Heal [RG p. 124]). Take any number of pieces in one command (Logic [LJ], Audacity [AM], REAPER [RG]). No vendor text covers different gains in heal. Inference: refuse the heal, or heal only when the gains are equal. Open question: the gesture "heal after the user lowered one piece" is not checked against any app. Audacity keeps a gain step [AS].

## 2. A crossfade at a join of two contiguous pieces, with different gains

### Pro Tools

- Fade slope has two settings. "Equal Power: Recommended for material that is not phase coherent." "Equal Gain: Recommended for material that is phase-coherent or nearly phase-coherent, as in the case of a crossfade between identical clips/instruments (for example, a repeated drum loop). Use this option to avoid clipping that can occur when using an Equal Power crossfade." [PT p. 909 to 910]
- The Link setting ties the fade-out and fade-in curves. "This ensures that the resulting crossfade is an equal power or equal gain crossfade, depending on which one you select." The Equal Power link text says to "avoid the volume drop that can occur with an Equal Gain crossfade" [PT p. 909 to 910].
- The user chooses the slope. The guide has no rule that picks it by itself (unconfirmed that no auto choice exists in the app; the guide shows none).
- Slope and shape are in the Edit-window right-click menu: Standard or S-Curve, and Equal Power or Equal Gain [PT p. 920].
- Clip gain across a crossfade: "the Clip Gain Line for the first clip carries through the fade out segment of the crossfade and the Clip Gain Line for the second clip carries through the fade in segment". The crossfade "can display two Clip Gain Lines" [PT p. 1227]. Pro Tools does not turn the gain change into one ramp line. Each clip keeps its own gain under its own half of the fade.
- Coalescing clip gain to volume automation: "clip gain within crossfades is crossfaded as part of the volume automation" [PT p. 1233].

### Logic Pro

- The Fade Out type menu has four entries: Out; X (Crossfade); EqP (Equal Power Crossfade), which "minimizes volume dips between audio regions, resulting in a more even crossfade between regions that may be slightly different in level"; and X S (S-Curved Crossfade). The last three need two consecutive regions [LE].
- A marquee over one junction applies an Equal Power crossfade "with the crossfade pivot on the region junction" [LF].
- The Fade Out type changes between Out and a crossfade type depending on whether a region or a gap follows [LF].
- The page does not define the curve of "X" (unconfirmed). The Join mixdown crossfade is linear at Curve 0 and symmetrical "to avoid deviations in level" [LJ].
- No Logic text picks a curve by itself for correlated audio (unconfirmed that none exists).

### REAPER

- Change log v4.30 (2012-11-14): "Crossfade editor: crossfades can be constrained to be equal gain or equal power". "default crossfade shape is equal power (existing projects are unchanged)". "new S-curve fade shape" [RW].
- The crossfade editor "activates for selected items that are adjacent or overlapping" (v4.30) [RW]. The guide lists "seven shapes" and says the default shapes are set in Preferences > Item Fade Defaults [RG section 3.18 and p. 145].
- Change log v7.48 (2025-10-06): the crossfade menu order is restored, with "equal power fade listed 2nd" [RW].
- No REAPER text picks the shape by source correlation (unconfirmed that none exists).

### Hindenburg PRO and Audition

- Hindenburg guide list: "Cross Fade" is "a transition from one sound to another on the same track". "Cross Fade point ... can be moved to fit the fade point better." "Fade slope is used to make a more gradual fade." [HP] The guide does not name the curve (unconfirmed). Repo decision 0036 records Command-F at a join and a pivot move with Command-drag in Hindenburg [D36].
- Audition: the crossfade page was not read (the fetch returned a stub). Curve names are unconfirmed.

### Gain change between contiguous pieces as a ramp

- No checked editor treats a clip gain change between two touching pieces as a gain ramp. Pro Tools shows two gain lines under the crossfade [PT p. 1227]. Audacity keeps a step at a join [AS].
- Inference (math, no owner source): the output of a crossfade of two pieces of one signal x is (gA * a(t) + gB * b(t)) * x. With an equal-gain pair (a + b = 1) this is a linear ramp from gA to gB. With an equal-power pair, a + b reaches 1.414 at the middle, so a gain of 1 on both sides is 3 dB too loud there. Decision 0036 states the 3 dB case [D36].

Default for Dirigible: Keep the refusal at a seamless join [D36]. If a later run adds a crossfade there, let the user pick the curve. Offer Equal Gain for pieces of one file, as Pro Tools documents it for "identical clips" [PT p. 910]. No editor picks the curve by itself for correlated audio. A gain ramp across the join is an Inference with no owner source. Open question: the most common gesture (Command-F over a heal join with the gain of one piece changed) was checked in no app.

## 3. A plain-text chapter list for a podcast description

### YouTube

- "In the Description, add a list of timestamps and titles." "Make sure that the first timestamp you list starts with 00:00." "Your video should have at least three timestamps listed in ascending order." "The minimum length for video chapters is 10 seconds." [YT]
- The page gives `00:00` as its only example. It does not state `M:SS` or `H:MM:SS` (unconfirmed on the vendor page). Third-party pages say `M:SS` under one hour and `H:MM:SS` above work (S, not checked).

### Spotify (chapters from the description)

- "Your first chapter should start at 00:00 or 00:00:00." "You need at least 3 chapters." "Chapters should be in chronological order." "Write each chapter on its own line." [SPF]
- "(MM:SS); MM:SS; (HH:MM:SS); and HH:MM:SS are all accepted timestamp formats." The line shape is "timestamp title", for example "(00:00) Intro". Titles are "plain text without any emojis or HTML". The tip is a title under 40 characters [SPF].
- A search summary also lists "00:00-Introduction" as an example (S, not on the fetched text).

### Apple Podcasts

- It reads chapters from the episode description: "Add chapter titles and timestamps directly to your episode description. Start the first chapter at 00:00:00 and include at least three chapters." [APC] This confirms [R-P2] section 5.
- Guidance: chapters for episodes over 10 minutes; "no shorter than two minutes"; "no more than six chapters per hour"; titles "no more than 45 characters and less than five words" [APC].
- Apple Podcasts Connect lets you download "a TXT file with a list of chapter titles and timestamps". The line shape of that file is not documented (unconfirmed) [APC].
- The only time example on the page is `00:00:00`. Whether `00:00` parses is unconfirmed.

### Tools and hosts

- Auphonic reads a plain text chapter file with "one time marker (`hh:mm:ss[.mmm]`), a chapter title and an optional URL per line". Its example: `00:00:00.000 Intro <http://url1.com>`, `00:00:10.000 Baby prepares to rock`. It can "append possible Chapter Marks with time codes and URLs to your Summary". The shape of the appended lines is not documented (unconfirmed) [AUP].
- Descript: the marker menu has "Copy chapters for YouTube". The help page shows no line shape. It says YouTube ignores chapter metadata in exported files [DS].
- Riverside: the editor has "Copy chapters list". The page was not read (HTTP 403). A search summary quotes the line `04:25 Color-Coded Waveform` (S, unconfirmed) [RS].
- Buzzsprout: the Express Chapter Editor takes "your timestamps, in plain text or as a JSON file". The page does not show the line shape or say that it reads the description [BZ]. Same page in [R-CH] section 4.
- Transistor: "Add timestamps as text in your Show Notes." Spotify, Pocket Casts, Metacast, and Overcast make them clickable. Apple Podcasts and Fountain show them, not clickable. The format is not documented [TF] [TS].
- Libsyn: no primary page found (unconfirmed).
- Hindenburg PRO: it writes chapters to the audio file, JSON (build 2590), and PSC (build 2716). No text list is documented [R-CH] section 2.

### Line shape that the sources support

- Spotify and Auphonic agree on "time, one space, title" [SPF] [AUP]. Spotify, YouTube, and Apple all want the first chapter at zero, ascending order, and at least three chapters [SPF] [YT] [APC].
- Leading zeros: two digits for minutes and seconds, as in `00:00` [YT] [SPF]. Hours: `HH:MM:SS` is the Apple example (`00:00:00`) and an accepted Spotify form [APC] [SPF].
- No single shape appears in all three primary pages: YouTube shows `00:00`, Apple shows `00:00:00`, and Spotify accepts both.

Default for Dirigible: One chapter per line as `MM:SS Title` for an episode under one hour, and `HH:MM:SS Title` from one hour, with one space and the first line at zero [SPF] [YT] [APC]. Use one form in the whole list. Open question: does Apple Podcasts parse `00:00` (its page shows only `00:00:00`)? Use `HH:MM:SS` in all lines if the planner wants the Apple example to hold. Do not add a hard rule for the minimum length: YouTube says 10 s and Apple suggests 2 min [YT] [APC].

## 4. Unused media files in a project

### Logic Pro and GarageBand

- Logic: File > Project Management > Clean Up. The options are Delete Unused Audio Files, Delete Unreferenced Audio Files, and Delete Backups. "A dialog appears, showing all of the files to be deleted from the project", with a Delete check box for each file [LC].
- Logic: Project Audio Browser > Edit > Select Unused, then Audio File > Delete. Unused means "aren't in the Tracks area or in a Live Loops cell" [LU]. Deleting a track keeps its audio in the project until removed [LU]. The page mentions no prompt on save.
- GarageBand: File > Clean Up Project, with one dialog and OK. "Deleting unused audio files" [GBC].
- Other Logic text on the same subject: [R-REC] section 7.

### Pro Tools

- Clip List menu > Select > Unused "selects clips that have not been placed in a track in the current session". "Unused Except Whole Files" skips whole-file clips. Offline clips show in italics and dimmed [PT p. 426].
- Clip List menu > Clear. "The Clear command cannot be undone." The dialog has "Automatically select all unused clips" and a Delete button for the file. Option-click Delete deletes each file with no further warning [PT p. 432].
- Compact "permanently deletes audio data" and "deletes any audio files for which there are no clips on tracks referencing those files" [PT p. 901].
- Inference: the Clip List shows unused clips only after the user runs Select > Unused. The guide shows no marker on an unused clip.

### REAPER

- File > Clean current project directory lists files in the project folder that are not in the project, and can only delete them [R-REC] section 7, [RG index p. 450].
- Project Bay, Source Media Bay: items dragged into the bay "are placed in the Source Media Bay only, until such time as they are actually added to the project". Right-click the title bar > "Remove all items that are not used in project" [RG pp. 222 to 224].
- No status hint on save is documented (unconfirmed).

### Hindenburg PRO and Audition

- Hindenburg: no unused-file tool in the PRO guide list. The nearest entry, "Clipboards - Delete Used", acts on clips in a clipboard group [HP]. See [R-REC] section 5.
- Audition: (S) "File > Close Unused Media" is named by a forum user (Dec 2021) [AC3]. A Community Expert says that deleting a file from the Files panel is "a deliberate, separate act" [AC3]. A thread reports that unused clips vanish at session close unless Preferences > Multitrack > "Reference all open audio and video files when saving sessions" is on [AC4]. No Adobe page was reached for any of these (unconfirmed).

### De-duplication of a re-imported file

- Pro Tools: "Automatically Copy Files on Import ... all audio files that are imported by dragging and dropping are copied to the current session's Audio Files folder" [PT p. 170]. The guide has no sentence on an import of a file that is already in the session (unconfirmed after a text search of the guide).
- REAPER: the preferences have "Copy imported media items to project media directory" [RG p. 448] and the Project Bay has "Copy media to project directory when importing to current project bay" [RG p. 222]. The guide has no sentence on an identical file (unconfirmed).
- Logic: the checked Apple pages give no rule for a second import of the same file (unconfirmed). [R-FI] section 5 has the other Logic and Audition import facts.
- Hindenburg: "No source says that an import of a file that is already in the Files folder reuses the file or makes a copy (unconfirmed)" [R-REC] section 5.
- Audition: no source (unconfirmed).

Default for Dirigible: Show unused media only on a user command with a list and a count, as Logic Select Unused, Logic Clean Up, Pro Tools Select > Unused, and GarageBand Clean Up Project do [LC] [LU] [PT p. 426] [GBC]. No checked editor shows a status on save or a prompt on save (unconfirmed for Hindenburg, Audition, and Reaper). No checked editor documents de-duplication of a re-imported identical file. Inference: do not de-duplicate on import. Open question: the gesture "drop the same file twice" was checked in no app.

## Claims that no source confirmed

- Pro Tools: heal with different clip gains, with more than two pieces, and whether heal writes a file. Any app-side automatic choice of fade slope.
- REAPER: the conditions of Heal splits, its treatment of item volume, and whether it ever renders. REAPER status hints for unused media. De-duplication.
- Logic: gain in the no-mixdown join; the curve of "X (Crossfade)"; a rule for a second import of one file; any prompt on save.
- Audacity 3.7: a clip-gain rule in the manual (only the source shows the step).
- Hindenburg: the conditions, gain rule, and file rule of Merge; the crossfade curve; any text chapter export; unused-file view; import de-duplication.
- Audition: Merge Clips (file, gain, rules); crossfade curve; Close Unused Media; import de-duplication.
- YouTube: `M:SS` and `H:MM:SS` forms on the vendor page. Apple Podcasts: whether `00:00` parses; the line shape of its TXT download. Riverside copy-list line shape (page not read). Transistor, Buzzsprout, Descript, Auphonic (description append): line shapes. Libsyn: all.

## Sources

- [PT] Avid, Pro Tools Reference Guide 2025.10 (PDF; text read with a local script; printed page numbers): https://resources.avid.com/SupportFiles/PT/Pro_Tools_Reference_Guide_2025.10.pdf
- [RG] Cockos, "Up and Running: A REAPER User Guide" v7.81, September 2026 (PDF; printed page numbers): https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [RW] Cockos, REAPER change log (versions and dates as written in the file): https://www.reaper.fm/whatsnew.txt
- [LJ] Apple, Logic Pro User Guide for Mac, Join regions: https://support.apple.com/guide/logicpro/join-regions-lgcpaa45acde/mac (older text with the same rules: https://help.apple.com/logicpro/mac/10.4/en.lproj/lgcpaa45acde.html)
- [LE] Apple, Logic Pro 10.4 guide, Edit fades: https://help.apple.com/logicpro/mac/10.4/en.lproj/lgcpf7c0cd53.html
- [LF] Apple, Logic Pro User Guide for Mac, Create fades on audio regions: https://support.apple.com/guide/logicpro/create-fades-on-audio-regions-lgcpf7c0ee6c/mac
- [LC] Apple, Logic Pro User Guide for Mac, Clean up projects: https://support.apple.com/guide/logicpro/clean-up-projects-lgcpce0efc05/mac
- [LU] Apple Support, Remove unused audio files in your Logic Pro for Mac project: https://support.apple.com/en-gb/118567
- [GBC] Apple, GarageBand User Guide for Mac, Clean up projects: https://support.apple.com/guide/garageband/clean-up-projects-gbndde92315b/mac
- [AM] Audacity manual, Edit menu, Audio Clips (Join): https://manual.audacityteam.org/man/edit_menu_clip_boundaries.html
- [AS] Audacity 3.7.8 source, `WaveTrack::Join` and `RebuildJoinedEnvelope`: https://raw.githubusercontent.com/audacity/audacity/Audacity-3.7.8/libraries/lib-wave-track/WaveTrack.cpp
- [AF] (S) Audacity forum, "Joining clips screws up envelope information": https://forum.audacityteam.org/t/joining-clips-screws-up-envelope-information/47620 (seen in a search summary only)
- [HP] Hindenburg, PRO guide list (function names and one-line texts; read through a page fetch): https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HK] Hindenburg, PRO 2 shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HS] Hindenburg, PRO story editing (Merge): https://hindenburg.com/hindenburg-pro-features/story-editing/
- [AUA] Adobe, Audition, arrange and edit multitrack clips (archived copy; no merge entry found): https://web.archive.org/web/2025/https://helpx.adobe.com/audition/desktop/mixing-multitrack-sessions/arranging-editing-multitrack-clips.html
- [AC1] (S) Adobe Community, "editing features for radio documentaries": https://community.adobe.com/questions-544/editing-features-for-radio-documentaries-157006
- [AC2] (S) Adobe Community, feature request "merging clips in multiple tracks at once" (search summary only): https://community.adobe.com/feature-requests-545/merging-clips-in-multiple-tracks-at-once-1435987
- [AC3] (S) Adobe Community, "delete unused takes": https://community.adobe.com/questions-544/delete-unused-takes-159942
- [AC4] (S) Adobe Community, "audition deletes unused clips when you close the session": https://community.adobe.com/questions-544/audition-deletes-unused-clips-when-you-close-the-session-164270
- [YT] YouTube Help, Video Chapters: https://support.google.com/youtube/answer/9884579
- [SPF] Spotify for Creators, Episode chapters: https://support.spotify.com/us/creators/article/episode-chapters/
- [APC] Apple Podcasts for Creators, Using chapters on Apple Podcasts: https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts
- [AUP] Auphonic Help, Production (chapters text format): https://auphonic.com/help/web/production.html
- [DS] Descript Help, Markers and chapters: https://help.descript.com/script-editing/markers-chapters.md
- [RS] (S) Riverside Help, Export chapters list with timestamps (fetch refused with 403; the line example is from a search summary): https://support.riverside.com/hc/en-us/articles/14980939825181-Export-chapters-list-with-timestamps
- [BZ] Buzzsprout Help, Create chapter markers: https://www.buzzsprout.com/help/61-chapter-markers
- [TF] Transistor Help, Which podcast apps support Chapters: https://support.transistor.fm/en/article/which-podcast-apps-support-chapters-1efishb/
- [TS] Transistor Help, How do I add time stamps to my podcast episodes: https://support.transistor.fm/en/article/how-do-i-add-time-stamps-to-my-podcast-episodes-cp0h19/
- [R-CH] Repo research `docs/research/chapters.md` (2026-10-09), sections 2 and 4.
- [R-P2] Repo research `docs/research/podcasting-2.md` (2026-09-27), section 5.
- [R-REC] Repo research `docs/research/recovery-tools.md` (2026-09-26), sections 5 and 7.
- [R-FI] Repo research `docs/research/file-import.md`, sections 3 and 5.
- [R-PF] Repo research `docs/research/podcast-features.md`, row F24.
- [R-EC] Repo research `docs/research/edit-commands.md`, section 5 (region menu of Hindenburg).
- [D35] Repo decision `docs/decisions/0035-clip-fades.md` (Command-F, no fade at a butt join).
- [D36] Repo decision `docs/decisions/0036-crossfades.md` (seamless join, equal power, 3 dB).
