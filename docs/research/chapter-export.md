# Research: export one audio file for each chapter or marker

Date: 2026-10-28

Question: how do Audition, Audacity, Hindenburg PRO, Logic Pro, Reaper, and Descript export one file for each chapter, marker, label, or region? Feature: F95 of Dirigible.

Rules for this file:
- Each claim has a source in `## Sources` (S-number).
- "Not found" means that no primary source gave the fact. The searches are listed.
- "Inference:" means a rule that no source states. It needs a test.
- Audacity facts come from the source code at `master` on 2026-10-28 (files under `au3/`). The line numbers can move.

## 1. Audacity (best documented, source read)

Menu: File > Export Audio, "Multiple Files" (old name: Export Multiple) [S1, S2].

### 1.1 File names
- Three policies. "Using Label/Track Name", "Numbering before Label/Track Name", "Numbering after File name prefix" [S2, S3].
- Pattern "name": file = label text. An empty label gives `untitled` [S3].
- Pattern "number before": `%02d-` + label text. Example: `01-Intro` [S3].
- Pattern "number after prefix": `<prefix>-%02d`. The label text is not used. Example: `Show-01` [S3].
- Number = label index + 1. It has two digits (`%02d`). From 100 on it has three digits (printf rule; Inference: not tested).
- With "Include audio before first label", the index starts at -1. The first file gets 00 [S3, S2].
- The code puts the number before the extension. The extension comes from the chosen format [S3].
- Bad characters: `Internat::SanitiseFilename(name, "_")` replaces each excluded character with `_` [S3, S4].
- The exclude list = `wxFileName::GetForbiddenChars(format)` + `\` and `/` on all platforms (bug 1441) [S4].
- On macOS the format is `wxPATH_MAC`. For that format wxWidgets returns an empty forbidden list [S5]. So on macOS only `/` and `\` become `_`. A colon stays in the name (Inference: the Finder shows a colon as `/`; not tested).
- Windows list: `* ? \ / : " < > |` [S5].
- Two files with the same name in one run: `FileNames::MakeNameUnique` adds `-2`, `-3`, ... [S3, S6].

### 1.2 Loudness
- No loudness step in the export loop. The export setting has only file name, channels, t0, t1, and tags [S3].
- Result: no gain change. Any normalize is an effect that the user applies to the project before export (Inference from the code).

### 1.3 Tags
- Start from the project tags (`Tags::Get`) with defaults loaded. Copy them to every file [S3].
- Per file: `TAG_TITLE` = label text before sanitizing. `TAG_TRACK` = index + 1 [S3].
- Album, artist, and artwork: no per-file logic. They come from the project tags (Not found: artwork).
- No track total ("3 of 12") is set [S3].
- The manual says that the Edit Metadata dialog sets tags for all files and that bug #5825 applies the user text to the first file only [S2]. The source copies the tags of the previous file to the next file, then overrides title and track [S3].
- Chapter tags (ID3 CHAP) inside a file: Not found.

### 1.4 Range of each file
- Only the first (top) label track is used. The manual says so [S2]. The source takes `tracks.Any<LabelTrack>().begin()` [S3].
- Labels are sorted by start time (`SortLabels`) [S7].
- Point label: t0 = label time. t1 = start of the next label. For the last label t1 = `tracks.GetEndTime()` (end of the program) [S3, S2].
- Region label: t0 = label start. t1 = label end. The next label does not change t1 [S3, S2]. Audio between the end of a region and the next label is not exported. Overlapping regions export overlapping audio.
- Audio before the first label: dropped by default. With "Include audio before first label" it becomes file 00. The range is 0 to the first label start [S3, S2].
- The name of file 00 = the "First file name" field [S2]. In the source it is the name in the file name field of the options panel [S3].
- The manual says to use the box only if no label marks the start [S2].
- No handle, pre-roll, tail, fade, or gap. The range is exact [S3].
- Two labels at the same time, or a zero-length range: no guard found in `UpdateLabelExportSettings`. The first file would have t0 equal to t1 (Not checked in the export task).

### 1.5 Folder pick and existing files
- One dialog: a folder path, a format, a split mode, a name policy, and an optional prefix. No save panel per file [S1, S3].
- The folder is created if it does not exist (`Mkdir ... PATH_MKDIR_FULL`). If that fails the user sees "Unable to create destination folder" [S3].
- "Overwrite existing files" is off by default [S2, S3].
- Off: if a file exists, the new file gets `-2`, `-3`. The old file stays [S3, S2].
- On: the old file is renamed to a backup. After a good export the backup is deleted. After a failed export the old file is restored [S3].
- If one export stops, a dialog asks "Continue to export remaining files?" [S3].

## 2. Adobe Audition

### 2.1 Feature
- Waveform Editor > Window > Markers. Select range markers. Click "Export audio of selected range markers to separate files" [S8].
- Old name of the button: "Batch Export Marker Regions". The 2010 Adobe blog says that the button is off when only point markers are selected [S9].
- Only range markers export. A point marker has no end time (S9). A point marker can become a range with "Convert to Range" [S8].
- "Merge" in the Markers panel joins the selected markers. The merged marker takes the name of the first marker. Merged point markers become range markers [S8]. Merge does not split files.
- Multitrack: File > Export > Multitrack Mixdown gives one file. The option "Include markers and other metadata" only embeds markers in that file [S10]. The option has no per-marker split.

### 2.2 File names
- "Use Marker Names In Filename": the marker name is the prefix. Or type a "Prefix" [S8].
- "Postfix Starting": the number to start from. Audition adds numbers after the prefix, for example `prefix02`, `prefix03` [S8].
- The blog says: marker label as file name, or a custom prefix and a start number [S9].
- Zero padding, number place for the marker-name case, and replaced characters: Not found. Searches: helpx.adobe.com markers page, saving-exporting page, 2010 blog, web search for "Audition batch export marker file name illegal characters".

### 2.3 Loudness
- The export dialog lists no loudness option [S8]. Audition does not normalize in this export.
- Match Loudness is a separate panel. It scans each file, then matches each file to a standard (for example EBU R128). It works on files, not on this export [S11].
- One gain for the whole program: Not found.

### 2.4 Tags
- "Include Markers and Other Metadata": puts the audio markers and the Metadata panel fields in each file [S8].
- Per-file title = marker name: Not found. Track number = place: Not found. (Forum reports say that title tags do not reach the files; they are secondary and not used here.)

### 2.5 Range
- Each file = one range marker, start to end. Audio outside the selected ranges is not exported [S8, S9].
- The 2010 blog mentions a choice to add silence at the start and end of each range [S9]. The current help page does not list it (Not found in S8).
- Audio before the first marker, last file, two markers at one time, zero-length range: Not found.

### 2.6 Folder pick
- One dialog: "Location" with Browse, "Format", "Sample Type" [S8]. The prefix and number option sit in the same dialog.
- Behavior for an existing file name: Not found.

## 3. Hindenburg PRO

- Per-chapter export exists. "Chapters - Export Selection": "Export the selected chapters as individual files". "Chapters - Select and Export All Chapters": select all chapters, then use Export Selection [S12].
- Hindenburg has tutorial video pages for both items [S13]. The pages have only a title and no text.
- The release notes list "JSON export of chapters" and "PSC export for Chapters" (chapter lists, not audio) [S14].
- Not found for Hindenburg, for all five points (file names, loudness rule, tags, range, folder pick and overwrite rule).
- Searches tried: hindenburg.com guides and shortcut pages, release notes, "Export Selection chapters individual files", "Export Regions", the Hindenburg PRO user manual PDF (no URL on hindenburg.com/support or /academy/guides). The manual text was not reachable.
- Inference: Hindenburg writes the chapter as the selection and uses the normal Export dialog (format, loudness, metadata). A test in the app is needed.

## 4. Logic Pro

### 4.1 No export by marker
- Not found: a Logic Pro command that exports one file for each marker. Searches: the Logic Pro User Guide pages "Bounce a project", "Set the bounce range", "Export regions as audio files", "Export tracks as audio files", "Navigate using markers", and the web search "Logic Pro export by markers".
- Marker to range steps (manual, one marker at a time) [S15, S16]:
  1. Select a marker. Use "Set Locators by Marker and Enable Cycle" (Control-Option-C), or Shift-click the marker in the ruler. The cycle area then equals the marker [S16].
  2. File > Bounce > Project or Section. If Cycle is on, only the cycle area bounces [S15]. Start and End can be edited in the dialog [S17].
  3. Repeat for each marker.
- The cycle follows the marker length. A marker ends at the next marker (Inference: the page says "position and length of the marker" and does not define a point marker).

### 4.2 File names
- Bounce: the default file name = the output channel strip name (`Output 1-2`). The user edits "Save As". Default folder: `~/Music/Logic/Bounces` [S15].
- Several destination formats in one bounce: same name with different extensions [S15].
- Export regions and tracks: a filename Pattern from "filename elements" (drag elements in order, plus a Custom element) [S18, S19]. With several regions selected, the files use the region names [S18].
- Replaced characters: Not found.

### 4.3 Loudness
- Normalize menu in Bounce and in Export: Off, Overload Protection Only, On [S15, S18].
- "On" scans the bounce for the highest peak, then raises the peak to the maximum without clipping [S15]. So each bounce file has its own gain (peak, not LUFS).
- One gain for several files: Not found.

### 4.4 Tags
- Not found for Bounce. The Bounce and Export pages list no tag fields. Option "Include Tempo Information" exists for uncompressed files [S15].

### 4.5 Range
- Cycle area (from a marker) or selected regions or typed Start and End [S15, S17].
- "Include Audio Tail" extends the file for reverb and release. "Bounce 2nd Cycle Pass" adds the tail of the first pass to the start [S15].
- Apple advises to set the End a little past the last region, to keep effect tails [S15].
- Audio before the first marker: no rule (a marker is only a cycle source).
- Two markers at one time, zero-length range: Not found.

### 4.6 Folder pick
- Bounce window: Save As field, a folder browser, a New Folder button. The new folder stays for later bounces [S15].
- A name that already exists: Not found.

## 5. Reaper

### 5.1 Range
- Render to File > Bounds. Option "Project markers": "a separate item to be rendered from each project marker to the next". Option "Selected markers": "between each selected marker and the next marker" [S20, user guide 21.3].
- Option "Project regions" renders each region (selected in the Region/Marker Manager or the Region Render Matrix) [S20].
- The guide does not say what the last marker ends at. Not found.
- Markers `=START` and `=END` set the project edges for "Entire project" [S20].
- Edge controls: "Tail" setting (stored per project, off by default in new projects) [S21 changelog]. "2nd pass render" plays once so that FX tails are rendered [S20]. Postprocess: trim leading and trailing silence, pad start and end with silence, fades in and out [S20].
- Same-start regions: a fix exists for `$region` with several regions of the same start and end times [S21]. Zero-length range: Not found.

### 5.2 File names
- One File name field with wildcards, in one dialog with the Directory field. A slash in the pattern makes subfolders [S20].
- Wildcards for this feature (changelog, the guide only says "choose Wildcards" in the dialog) [S21]:
  - `$marker`: the name or number of the first marker in the rendered range. Later fixed to "the latest marker before the start" when none is inside the range.
  - `$markernumber`, `$regionnumber`, `$region`.
  - `$marker[001]` and `$region[001]`: set the offset and the number of digits.
  - `$markername` and `$regionname` give an empty string, not a number, when the name is empty.
- Example from the guide for regions: `$project\$region-$track` [S20].
- Replaced characters (slash, colon) in a marker name: Not found.
- Existing file: option "Silently increment filenames..." adds a number (`-001`, `-002`). It stops accidental overwrite [S20, S21]. Without the option: Not found (Inference: an overwrite prompt).

### 5.3 Loudness
- Render > Postprocess: normalize to LUFS-I, RMS-I, true peak, peak, LUFS-M max, or LUFS-S max, to a target level. Choose "each file separately", "to loudest file", or "as if files play together" [S20].
- "As if files play together" = one common gain for all files. The changelog calls it the old "as if one long file" [S21].
- Item normalize has the same three modes [S20 section 7.25].

### 5.4 Tags
- Metadata button in the Render dialog. Schemes: ID3, BWF, INFO, CART, CAFINFO, VORBIS, ASWG. Fields can use wildcards [S20, 21.1.2].
- Wildcards in the title field give a title for each file. The guide says wildcards work in metadata, but it does not list marker wildcards for the title (Inference).
- Option "Embed markers/regions" puts cues in WAV files [S20]. Artwork in each file: Not found.

### 5.5 Folder pick
- Directory field + Browse + File name in the same dialog. No save panel per file [S20].

## 6. Descript

- Export > Audio > "Export" menu: Current composition, Current selection, Current scene, Scenes, **Markers**, Line breaks, All compositions [S22].
- "Markers: Exports individual audio files for each Marker in the composition". "All compositions: Batch exports an audio file for every composition in your project" [S22]. Video export has the same list [S23].
- A marker is a section header in the script and a bookmark in the timeline: "Add markers to break your script into sections" [S24].
- Formats: m4a, wav, mp3. Advanced: channels, sample rate (44100 or 48000), bitrate [S22].
- Loudness: "Normalize volume: Off, Peak, -14, -16, -18, -23, -24 LUFS" [S22]. Whether the gain is per file or common: Not found.
- Tags: Metadata icon: show title, episode title, description, artwork, markers/chapters. ".wav files do not support artwork or chapter markers" [S22]. "Include markers as chapters" works for MP4, MP3, AAC [S24].
- Not found: file names for "Markers" and "Scenes", the characters replaced, the folder pick, the overwrite rule, and the range edges (audio before the first marker, last file, equal markers). Searches: help.descript.com export audio, video-gif, markers-chapters, llms.txt, feedback.descript.com batch-export threads.
- Inference: a Descript marker range = marker to next marker (the marker is a section header). The last range ends at the end of the composition. Needs a test.

## 7. Podcast hosts and chapters

- Apple Podcasts gives three ways to add chapters: the episode description, the RSS tag `podcast:chapters`, or the file metadata (MP4 header, or ID3 of MP3 or AAC) [S25].
- Apple advice: first chapter at 00:00:00, at least three chapters, at most six per hour, each at least two minutes, titles under 45 characters, only for episodes over 10 minutes [S25].
- Result: hosts take chapters as tags inside one episode file. The Apple chapter page does not ask for one audio file per chapter [S25].
- Apple RSS rules: each episode has one enclosure (URL, length, type). Only ASCII letters and digits in file names and URLs [S26, from a search summary; page not fetched].
- Audiobook flow (one file per chapter): Not researched (out of the fetched sources).

## 8. Comparison table

| App | 1. File names | 2. Loudness | 3. Tags | 4. Range | 5. Folder, existing file |
|---|---|---|---|---|---|
| Audacity | `name`, `NN-name`, `prefix-NN`; `%02d`; index + 1 (00 for pre-first); `/` `\` to `_`; empty = `untitled`; run duplicates `-2` | None in export; no gain change | title = label text; track = index + 1; rest from project tags; no total | Point: label to next label, last to program end. Region: own start to end. Pre-first dropped unless checked. No handles | One dialog, folder created; no overwrite: `-2` suffix; overwrite option with backup |
| Audition | Marker name or prefix; number after prefix (`prefix02`); padding not found | None in dialog; Match Loudness is separate, per file | "Include Markers and Other Metadata" (panel fields); per-file title not found | Range markers only; own start to end; point markers excluded; old blog: optional silence pad | One dialog (Location, Browse); overwrite rule not found |
| Hindenburg PRO | Not found | Not found | Not found | "Chapters - Export Selection" = individual files; edges not found | Not found |
| Logic Pro | No marker export. Bounce: `Output 1-2` or Save As; regions: pattern elements | Normalize Off / Overload only / On (peak, per file) | Not found | Marker to cycle by key command; Bounce limited to cycle; Include Audio Tail | Bounce window with Save As and folder; existing file not found |
| Reaper | `$marker`, `$markernumber[001]`, `$region`, `$regionnumber`; slash = subfolder; chars not found | Postprocess: each file, loudest file, or common gain ("play together"), LUFS-I etc. | Metadata dialog with wildcards; ID3, BWF, etc. | Marker to next marker; selected markers; regions; tail, pad, trim, fades; last marker not found | One dialog; "Silently increment filenames" adds `-001` |
| Descript | Not found | Off, Peak, -14, -16, -18, -23, -24 LUFS; per file or common not found | Show/episode title, description, artwork, chapters (no WAV) | Export "Markers" = one file per marker; edges not found (Inference: marker to next) | Not found |

## 9. Points for F95 defaults (from the findings, not from a source)

- Inference: the common pattern is `NN-name` with two digits, number = place, and `/` replaced by `_`. Audacity and Reaper (via `$marker[001]`) agree.
- Inference: default range = marker to next marker, last to program end. Audacity (point labels) and Reaper (project markers) agree. Audacity also exports the pre-first audio only when the user asks.
- Inference: loudness choices differ. Reaper gives both (each file, or common gain). A podcast mix that is already at target needs no gain change. Audacity adds none.
- Inference: tags in the file. Title = marker name and track = place are in Audacity. Chapter tags inside a per-chapter file have no source in any of the six apps.
- Test needed in Dirigible: a colon in a marker name, two markers at one time, a marker at the program end, and a zero-length range. No app source covers these.

## Sources

- S1 Audacity Manual, "Export Audio" dialog (3.4 and later): https://manual.audacityteam.org/man/export_audio_dialog.html (not fetched; the Audacity support page "Removed features" says Export Selection and Export Multiple are inside File > Export Audio since 3.4.0: https://support.audacityteam.org/llms-full.txt, section "Export Selection and Export Multiple").
- S2 Audacity Manual, "Export Multiple": https://manual.audacityteam.org/man/export_multiple.html (sections "Split files based on", "Name files", "Include audio before first label", "Overwrite existing files", "Edit Metadata").
- S3 Audacity source, `ExportAudioDialog.cpp` (functions `UpdateLabelExportSettings`, `DoExportSplitByLabels`, `DoExport`, setting names at the top): https://github.com/audacity/audacity/blob/master/au3/src/export/ExportAudioDialog.cpp
- S4 Audacity source, `Internat.cpp` (`Internat::Init`, `SanitiseFilename`): https://github.com/audacity/audacity/blob/master/au3/libraries/au3-strings/Internat.cpp
- S5 wxWidgets source, `wxFileName::GetForbiddenChars`: https://github.com/wxWidgets/wxWidgets/blob/master/src/common/filename.cpp
- S6 Audacity source, `FileNames::MakeNameUnique`: https://github.com/audacity/audacity/blob/master/au3/libraries/au3-files/FileNames.cpp
- S7 Audacity source, `LabelTrack::SortLabels`: https://github.com/audacity/audacity/blob/master/au3/libraries/au3-label-track/LabelTrack.cpp
- S8 Adobe Audition Help, "Using markers in Audition", sections "Adjust, merge, convert, or delete markers" and "Save audio between markers to new files" (WebFetch got HTTP 403; the same page was read through the locale copy): https://helpx.adobe.com/ca/audition/using/markers.html
- S9 Adobe blog, "Using Audition to save sections of a long audio file into separate files" (2010): https://blog.adobe.com/en/publish/2010/06/04/using-audition-to-save-section
- S10 Adobe Audition Help, "Save and export audio files", section "Export multitrack mixdown files": https://helpx.adobe.com/audition/using/saving-exporting-files1.html
- S11 Adobe Audition Help, "Adjusting loudness to match across the file" (Match Loudness panel; read through a search result summary only): https://helpx.adobe.com/audition/using/match-loudness.html
- S12 Hindenburg PRO shortcuts, group "Chapters": https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- S13 Hindenburg tutorial pages (title only): https://hindenburg.com/data/youtube/videos/how-to-export-all-chapters-in-hindenburg-pro-hindenburg/ and https://hindenburg.com/data/youtube/videos/how-to-export-a-chapter-in-hindenburg-pro-hindenburg/
- S14 Hindenburg release notes: https://hindenburg.com/support/release-notes/hindenburg-series/ (lines "Added PSC export for Chapters", "Added JSON export of chapters")
- S15 Apple Logic Pro User Guide, "Bounce a project to an audio file in Logic Pro for Mac" (sections "Bounce the current project to an audio file", "Set the bounce filename and location"): https://support.apple.com/guide/logicpro/bounce-a-project-to-an-audio-file-lgcp785a41c3/mac
- S16 Apple Logic Pro User Guide, "Navigate using markers", section "Set the cycle range to a marker": https://support.apple.com/guide/logicpro/navigate-using-markers-lgcpa855b268/mac
- S17 Apple Logic Pro User Guide, "Set the bounce range": https://support.apple.com/guide/logicpro/set-the-bounce-range-lgcp190ba9b7/mac
- S18 Apple Logic Pro User Guide, "Export regions as audio files": https://support.apple.com/guide/logicpro/export-regions-as-audio-files-lgcp8e5ce2d3/mac
- S19 Apple Logic Pro User Guide, "Export tracks as audio files": https://support.apple.com/guide/logicpro/export-tracks-as-audio-files-lgcpb27f70f9/mac
- S20 REAPER User Guide v7.83 (PDF): https://www.reaper.fm/userguide/ReaperUserGuide783c.pdf (chapter 21: 21.1.1 Wildcards, 21.1.2 Metadata, 21.3 Render to File options table, 21.5 Source Options, 21.10 Rendering Regions, 21.11; section 7.25 Normalizing Items)
- S21 REAPER changelog: https://www.reaper.fm/whatsnew.txt (entries on `$marker`, `$region`, `$marker[001]`, "add support for rendering between project markers", render tail default, "normalizing as if files play together (common gain)", auto-increment suffix `-001`)
- S22 Descript Help, "Export an audio file": https://help.descript.com/export-and-share/audio.md
- S23 Descript Help, "Export a video or GIF locally": https://help.descript.com/export-and-share/video-gif.md
- S24 Descript Help, "Markers and chapters": https://help.descript.com/script-editing/markers-chapters.md
- S25 Apple Podcasts for Creators, "Chapters on Apple Podcasts": https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts
- S26 Apple Podcasts for Creators, "Podcast RSS feed requirements" (search summary only, page not fetched): https://podcasters.apple.com/support/823-podcast-requirements
