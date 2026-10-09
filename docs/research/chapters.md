# Research: chapters export (JSON chapters, other apps, file name)

Date: 2026-10-09

This file fills the gaps in `docs/research/podcasting-2.md` (2026-09-27) for the chapters export run. It does not repeat the facts of that file. "(unconfirmed)" marks a claim that no primary source confirms. "Inference:" marks our reading of the sources.

## 1. JSON Chapters format: recheck

- The spec still says "Version 1.2 - Updated on 2021.04.15". Its examples and `example.json` write `"version": "1.2.0"` [JC] [JE].
- The last changes to the spec file are a reorganization (2025-06-13) and link fixes (2026-01-30). The format did not change [JCH].
- Top level, required: `version` (string) and `chapters` (array) [JC].
- Top level, optional: `author`, `title`, `podcastName`, `description`, `fileName` (strings), and `waypoints` (boolean) [JC].
- Chapter, required: `startTime` (float), "expressed in seconds with float precision for fractions of a second" [JC].
- Chapter, optional: `title` (string), `img` (string, URL), `url` (string, URL), `toc` (boolean), `endTime` (float, seconds), `location` (object with required `name` and `geo`, optional `osm`) [JC].
- No official JSON Schema exists. The repo tree has `docs/examples/chapters/` (`jsonChapters.md`, `example.json`, `exampleComplex.json`) and `docs/schema/` (an XSD for the RSS tags only). No file is a JSON Schema for chapters [JT].
- SchemaStore has no schema for podcast chapters on 2026-10-09 [SS].
- File name: the spec gives no name for the chapters file. `fileName` is "The name of the audio file these chapters apply to", not the name of the chapters file [JC].
- Rounding: the spec gives no rounding rule and no precision limit [JC].
- Integer or float: the spec says "float", but every example `startTime` is an integer (0, 94, 168, 260) [JC] [JE]. Inference: JSON has one number type, so an integer such as `168` is a valid value.
- Chapter at 0: both examples start with `{"startTime": 0, "title": "Intro"}` [JC] [JE]. The spec does not require a chapter at 0 (unconfirmed: no sentence about it).
- Order: "Chapter order is assumed to be in ascending order based on the `startTime`" [JC].

## 2. Hindenburg PRO

- The Hindenburg PRO guide lists these chapter functions [HG]:
  - "Chapters - Export Selection: Export the selected chapters as individual files".
  - "Chapters - Select and Export All Chapters: Select all chapter and choose 'export selection'".
  - "Publish - Create Publish Target - Enhanced Podcast: Set up you own Podcast for self Hosting with Chapters".
  - Chapters can have an image and a link.
- Inference: "Export Selection" writes audio files (one for each chapter), not a chapter list. `docs/research/export.md` has the same reading [HG].
- The function page "Chapters - Select and Export All Chapters" has only a title and no body text on 2026-10-09 [HE].
- Release 2.02, build 2590 (page date 19 December 2023): "Added JSON export of chapters" [H2]. No Hindenburg page gives the menu path, the dialog, the file name, or the JSON shape (unconfirmed).
- A user asked on 2024-08-09, after that release, for an export to the "Podcasting 2.0 <podcast:chapters> JSON format" [UV]. Inference: the JSON of 2.02 is perhaps not the Podcasting 2.0 format, or users do not find it (unconfirmed).
- Release 2.05, build 2716 (3 July 2025): "Added PSC export for Chapters" [H5]. Inference: PSC is Podlove Simple Chapters, an XML chapter format for feeds [PSC]. Hindenburg does not expand the abbreviation (unconfirmed).
- Chapters in the audio file: build 2550 "Fixed chapters/metadata in m4a files larger than 128 MB", build 2544 "Fixed wrong ID3 header size", build 2606 "Chapter markers in MP3 files imported as cue points" [HR]. Transistor lists Hindenburg as a tool that embeds chapters into the audio file [TM].
- Inference: Hindenburg writes chapters into MP3 and M4A at export or publish. It has a separate chapter-file export. No source shows if that export is a menu item or an option of the export dialog (unconfirmed).

## 3. Logic Pro, GarageBand, Audacity, others

- Logic Pro (guide versions 10.5 to 12.3): "When you record or bounce an audio file, the current Marker List is added to the file." The commands are Navigate > Other > Import Marker from Audio File, Remove Marker from Audio File, and Export Marker to Audio File [LP].
- The table of contents of the Logic Pro guide has no entry with "chapter" or "podcast" [LP]. Inference: Logic Pro has no podcast chapter feature and no chapter-file export.
- GarageBand: Apple lists only GarageBand 3, 4, 5, and 6 as able to make enhanced podcast files "which can contain audio or video, chapter markers, images, and URL links" (page published 2025-03-20) [GB]. Inference: the current GarageBand cannot make chapters.
- Final Cut Pro: nothing new. `docs/research/final-cut-pro.md` [MK] covers it.
- Audacity 3.7.8: the command is File > Export Other > Export Labels... [AF]. The save dialog has the title "Export Labels As:" and the default name `labels.txt` [AF].
- Pull request 9935 adds the file type "Podcast Chapters" (extension `json`) to the type list of that save dialog [AP].
- The `.json` extension of the file name selects the format [AP].
- Result: in Audacity the JSON export is a file type in the save dialog of an existing menu item. It is not a new menu item and not a check box [AF] [AP].
- Audacity writes `version` "1.2.0" and, for each label, `startTime` with 3 decimals and `title`. It writes no `endTime`, although a label has an end time [AP].
- Reaper, Descript, and Riverside: not checked.

## 4. File name next to the audio

- No spec or host page found names a required file name [JC] [PC] [BZ].
- The tag page example links `https://example.com/episode1/chapters.json`: a folder for each episode and the name `chapters.json` [PC].
- Argo makes "`chapters.json`" files (`podcasting-2.md` [AR]).
- Buzzsprout takes a "JSON File" in its chapter editor and gives no name rule [BZ].
- Transistor: in 2022, "this doesn't support Podcasting 2.0 chapter tags yet" [TC]. Its help page describes only chapters in the MP3 file [TM]. No later Transistor page about JSON chapters was found (unconfirmed).
- Blubrry: only a search summary says that a user links a `.json` chapters file at publish (unconfirmed, page not read).
- Inference: `chapters.json` is the usual name on a web server, one folder for each episode. Next to a local audio file, `<episode>.chapters.json` or `<episode>.json` is not a documented convention. Inference: a default name of `<episode>.json` in a save panel lets the user rename the file before upload.

## Open questions for the plan

- Hindenburg: where is the JSON export in the menu, and what does it write? Only a run of Hindenburg PRO 2.02 or later can answer.
- Default name: `chapters.json` (matches the web convention) or the session name with `.json` (no overwrite between episodes in one folder). This is a plan decision.

## Sources

- [JC] JSON Chapters format (raw): https://raw.githubusercontent.com/Podcastindex-org/podcast-namespace/main/docs/examples/chapters/jsonChapters.md
- [JE] Example file (raw): https://raw.githubusercontent.com/Podcastindex-org/podcast-namespace/main/docs/examples/chapters/example.json
- [JCH] Commit history of the spec file: https://github.com/Podcastindex-org/podcast-namespace/commits/main/docs/examples/chapters/jsonChapters.md
- [JT] Repo tree (GitHub API, recursive): https://api.github.com/repos/Podcastindex-org/podcast-namespace/git/trees/main?recursive=1
- [SS] SchemaStore catalog: https://www.schemastore.org/api/json/catalog.json
- [PC] podcast:chapters tag: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/tags/chapters.md
- [HG] Hindenburg PRO guide: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HE] Hindenburg function page (title only): https://hindenburg.com/data/functions/chapters-select-and-export-all-chapters/
- [H2] Hindenburg PRO 2.02 build 2590: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2590/
- [H5] Hindenburg PRO 2.05 build 2716: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2716/
- [HR] Hindenburg release notes index (builds 2544, 2550, 2606): https://hindenburg.com/support/release-notes/hindenburg-series/
- [UV] Hindenburg feedback, "Export chapters in JSON 2.0 format": https://hindenburg.uservoice.com/forums/224350-general/suggestions/47499599-export-chapters-in-json-2-0-format
- [PSC] Podlove Simple Chapters: https://podlove.org/simple-chapters/
- [LP] Logic Pro, use marker information from audio files: https://support.apple.com/guide/logicpro/use-marker-information-lgcpadb63ff8/mac
- [GB] Apple, GarageBand for Mac enhanced podcasts: https://support.apple.com/en-us/101746
- [MK] Final Cut Pro, add chapter markers: https://support.apple.com/guide/final-cut-pro/add-chapter-markers-verc9cacc031/mac
- [AF] Audacity 3.7.8 FileMenus.cpp: https://github.com/audacity/audacity/blob/Audacity-3.7.8/src/menus/FileMenus.cpp
- [AP] Audacity pull request 9935 (merged 2025-12-30): https://github.com/audacity/audacity/pull/9935
- [AR] Argo site: https://getargo.app/
- [BZ] Buzzsprout, chapter markers: https://www.buzzsprout.com/help/61-chapter-markers
- [TC] Transistor changelog, MP3 chapters: https://transistor.fm/changelog/mp3-chapters-notes/
- [TM] Transistor, add MP3 chapters: https://support.transistor.fm/en/article/how-do-i-add-mp3-chapters-to-my-podcast-episode-1ts9azc/
