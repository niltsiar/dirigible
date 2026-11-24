# Podcasting 2.0 chapters and transcripts, and the Argo app

Date: 2026-09-27

This document records the Podcasting 2.0 JSON chapters format, the Podcasting 2.0 transcript formats, the Argo app, and the ways to put chapters into an MP3 or an M4A file. It says which apps and hosts make and read these files. It ends with a recommendation for Dirigible. It starts from the notes of a subagent of 2026-09-24 (a local run folder, not in git). Each claim was checked again against its source on 2026-09-27. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

Related documents: `docs/research/podcast-features.md` (F19 markers, F27 transcripts, F55 metadata, F56 chapters), `docs/decisions/0018-edit-commands.md` (markers and chapters in Release 1), `docs/decisions/0011-command-line-front-end.md` (a `dirigible` command for each package or audio file feature), `docs/decisions/0019-export.md` (export range).

## 1. JSON chapters format

- The spec page says "Version 1.2 - Updated on 2021.04.15" [JC]. Its examples, and the example file, write `"version": "1.2.0"` [JC] [JE]. No newer version was found on 2026-09-27. Audacity 3.7.8 writes "1.2.0" [AU].
- The top-level object has two required properties: `version` (string) and `chapters` (array of chapter objects) [JC].
- Optional top-level properties: `author`, `title`, `podcastName`, `description`, `fileName` (strings), and `waypoints` (boolean) [JC].
- A chapter object has one required property: `startTime`, "expressed in seconds with float precision for fractions of a second" [JC].
- Optional chapter properties: `title` (string), `img` (URL of chapter art), `url` (URL of a related web page), `toc` (boolean), `endTime` (float seconds), and `location` (object with required `name` and `geo`, a RFC 5870 geo URI, and optional `osm`) [JC].
- `toc` set to false makes a "silent" chapter: a player does not show it in the table of contents or as a jump-to point. A missing `toc`, or `true`, is a normal chapter [JC].
- "Chapter order is assumed to be in ascending order based on the `startTime`" [JC].
- The server sends the file with the content type `application/json+chapters` [JC]. The feed links the file with `<podcast:chapters url="..." type="application/json+chapters" />` in the `<item>` [PC].
- The tag page gives the reasons for an external file: the chapters can change after the episode is published, a web browser can show them, and chapter images do not make the audio file larger [PC].

## 2. Transcript formats

- The `<podcast:transcript>` tag has `url` and `type` (required), and `language` and `rel` (optional). The type examples are `text/plain`, `text/html`, `text/vtt`, `application/json`, and `application/x-subrip` [PT].
- With `rel="captions"`, a player treats the file as closed captions, whatever the type, and expects time codes in it [PT].
- The transcript examples page says: "WebVTT is used by Apple Podcasts for ingest, and also natively supported by web browsers. Because the WebVTT format is the most flexible, it's an ideal choice if you can only support one format." [TE].
- WebVTT: a voice span `<v Name>` gives the speaker when the speaker changes. The page recommends lines of 65 characters or fewer [TE].
- SRT: speaker name followed by a colon at a speaker change. The page gives at most 2 lines and 32 characters for each line [TE].
- JSON: `{"version": "1.0.0", "segments": [...]}`. Each segment has `speaker`, `startTime`, `endTime` (if available), and `body`. At the highest fidelity, one segment holds one word [TE].

Who reads transcripts:

- Apple Podcasts accepts VTT and SRT, through the RSS transcript tag or an upload in Podcasts Connect. A VTT file can name the speaker of each line [AT].
- Spotify accepts an upload of a VTT or SRT file of 5 MB or less [SP]. Since 2025-06-12, a show hosted on Spotify for Creators can publish its transcripts with `podcast:transcript`. On that date Spotify had "no timeframe" to read the tag from other hosts [SN]. No later change was found (unconfirmed).
- Transistor accepts a pasted text or a `.srt`, `.vtt`, `.txt`, or `.json` file [TF].
- Hindenburg PRO 2 exports a transcript as SRT, VTT, or TXT (`podcast-features.md`, F27, [HX]).

## 3. The Argo app

- Argo is a free macOS app by Emilio Cano. It needs macOS 13 or later, runs on Apple silicon and Intel, and is a direct download, not from the App Store [AR] [AB].
- The site gives version 1.0 on 2026-06-15 [AR]. The blog post that announces it has the date 2026-06-26 [AB]. The notes of 2026-09-24 gave 2026-06-26 as the launch date.
- Argo makes Podcasting 2.0 `chapters.json` files. Input: manual entry, a JSON import, or OCR of a screenshot with the macOS text recognition. Each chapter can have an image and a URL. It shows a live JSON preview and validates the file before the export [AR] [AB].
- It uploads the file with FTP or SFTP. It keeps the passwords in the macOS Keychain [AB].
- Argo does not put chapters into the MP3 or M4A file. The chapters stay in the separate JSON file that the feed links [AB]. The site does not mention ID3, MP4 chapters, or transcripts [AR].
- Inference: Argo has no format of its own. A `chapters.json` from Dirigible opens in Argo, and a user can add images and URLs and upload the file there.

## 4. Other apps that make chapter files

- Hindenburg PRO 2.02 added "JSON export of chapters" [H2]. The release note page is dated 19 December 2023. Its URL names build 2590, and its text names build 2586. No source shows the shape of the JSON: the Podcasting 2.0 format or a format of Hindenburg (unconfirmed). The Hindenburg function page and video on chapter export gave no text on 2026-09-27 [HE].
- An older third-party tool reads the markers of a Hindenburg project file into `[{start, title, href}]`, with `start` in milliseconds [EP]. This is not the format of Hindenburg 2.02.
- Audacity 3.7.8 (released 2026-06-11) exports a label track as Podcast 2.0 chapters JSON with `version` "1.2.0", `startTime`, and `title` [AU] [AP]. The notes of 2026-09-24 gave only the merge date of the pull request (2025-12-30).

## 5. Who reads chapters

- Apple Podcasts takes chapters from three places: timestamps in the episode description, the `<podcast:chapters>` tag in the feed, and the audio file: "Specify chapters in the header of an MP4 file or by modifying the ID3 tags of an MP3 or AAC file." [AC].
- From iOS 26.2, Apple Podcasts makes chapters for English full and bonus episodes of 10 minutes or more, when its transcript succeeds [AC].
- Apple Podcasts reads JSON chapters from iOS 26.2 and iPadOS 26.2 [PN] [RC]. Apple's own page does not give the version for the tag (unconfirmed on the Apple page). No source says which source wins when an episode has more than one (unconfirmed).
- Podverse, Fountain, and Castamatic show the title, time, URL, and art of Podcasting 2.0 chapters. Spotify shows the title and time only [RC].
- RSS.com publishes Podcasting 2.0 chapters and does not embed ID3 chapters. It tells a user who wants ID3 chapters to add them with another tool before the upload [RC].
- Buzzsprout "uses and supports the Podcast Namespace" for chapters. Its chapter editor takes text input or a JSON file [BZ]. Buzzsprout says it can "add chapters to your audio file" [BZ]. Inference: Buzzsprout writes ID3 chapters into the MP3 (unconfirmed).
- Apple Podcasts reads ID3 chapters in an MP3 or AAC file [AC] [PN]. The podnews FAQ does not mention MP4 chapters [PN].
- A secondary source says that Apple Podcasts, Overcast, Pocket Casts, Castro, and Podcast Addict show chapter images, and that Spotify shows only the chapter titles [FS]. No Spotify page was checked for ID3 chapters (unconfirmed).

## 6. Chapters inside the audio file

### ID3v2 CHAP and CTOC (MP3, also AAC with ID3)

- "ID3v2 Chapters 1.0" is an addendum to ID3v2.3 and ID3v2.4 (BBC R&D and Dan O'Neill, 2005) [ID]. id3.org returned HTTP 503 on 2026-09-27. The Mutagen mirror has the text.
- `CHAP` frame: an element ID (a null-terminated string, unique in the tag), a start time and an end time (32-bit, milliseconds from the start of the file), a start offset and an end offset (32-bit byte counts; all bytes 0xFF means "use the time"), and optional sub-frames [ID].
- The sub-frames give the chapter name (`TIT2`), a description (`TIT3`), URLs, and images [ID].
- `CTOC` frame: an element ID, flags (bit a is the top-level bit, bit b is the ordered bit), an entry count (8-bit, more than zero), the child element IDs, and optional sub-frames. One `CTOC` has the top-level bit [ID].
- The spec recommends a `TIT2` in each `CHAP` and `CTOC` [ID].
- Inference: a `CHAP` frame needs an end time, so an export writes each end time as the start of the next chapter, and the last end time as the file length. The 8-bit entry count limits one `CTOC` to 255 chapters.
- LAME writes basic ID3 tags. No source was checked that says LAME writes `CHAP` or `CTOC` (unconfirmed). Inference: Dirigible needs its own ID3v2 tag writer for chapters. That writer also serves F55 (title, artwork).

### MP4 and M4A

- Two forms exist. QuickTime chapters: a text track with one sample for each chapter, and a `chap` track reference from an enabled track to the text track. The text track is normally disabled. When more than one track has a `chap` reference, QuickTime uses the first one it finds [QC].
- Nero chapters: a `chpl` box in `udta`, a flat list of times and titles. Nero, ffmpeg, and MP4Box read and write it [MA] [MP].
- mp4v2 lists the QuickTime form for "QuickTime, iTunes, Apple devices" and the Nero form for "Nero software, various players" [MP]. Many M4A editors write both forms [MA] (secondary source).
- Apple's page says "the header of an MP4 file" and does not name the form [AC]. Inference: Apple reads the QuickTime form, because the QuickTime File Format documents only that form.

### What AVFoundation can do

- Read: `AVAsset.loadChapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys:)` returns the chapters of a file [AV2]. A test can use it to check an export.
- Write: `AVAssetTrack.AssociationType.chapterList` exists from macOS 10.9 [AV1]. `AVAssetWriterInput.addTrackAssociation(withTrackOf:type:)` with a text input is the documented way to make a track reference.
- No Apple sample or Apple engineer answer shows a working write of chapters to an audio-only M4A. Three Apple Developer Forums threads (2019, 2020, 2023) report failures: error -12717 when the text format description is made, a zero-byte or corrupt file, and chapter metadata items with a time of zero. None has an answer from Apple [AF1] [AF2] [AF3]. A Swift Forums thread ends with a link to a third-party library, SwiftTaggerMP4 [SF].
- Result: AVFoundation can perhaps write a QuickTime chapter track into an M4A, but no source confirms it (unconfirmed). A probe must prove it before a plan depends on it. The fallback is a small MP4 box writer that adds `chap`, the text track, and `chpl` to the file that `ExtAudioFile` writes.

## 7. What Dirigible has today

- A `Marker` has an ID, a name, a position in frames at the session rate, and a kind: `marker` or `chapter` (`Sources/DirigibleCore/Model.swift`). Add Chapter (Shift-Cmd-Return) makes "Chapter N" (0018).
- `dirigible marker set <package> --kind chapter` and `dirigible marker remove` already exist (0018).
- State on 2026-09-27: a chapter had no image, no URL, and no `toc` flag. State on 2026-11-24: a chapter has a link and an image (`Marker.url` and `Marker.image` in `Sources/DirigibleCore/Model.swift`; F56 is done). A marker has no `toc` flag. `dirigible chapters import` reads the JSON field `toc`: a chapter with `toc` false becomes a plain marker.
- Export writes frames 0 to `session.end`, or the range of the Marks for Export Selection (0019).

## Recommendation

State on 2026-11-24: recommendations 1 to 3 landed. `dirigible chapters export` and `dirigible chapters import` exist (`Sources/DirigibleCLI/ChaptersCommand.swift`), and F56 is done. `dirigible export` embeds the chapters of the range in every MP3 and M4A file, with the URL and the image of each chapter. The text below is the plan of 2026-09-27.

**1. Export `chapters.json` from the chapter markers: yes, as a small Release 2 run.**

- It is worth it. The chapter markers exist in Release 1, and Apple Podcasts now reads JSON chapters from iOS 26.2. Hindenburg PRO 2 and Audacity 3.7.8 have the same export. Argo and Buzzsprout take the file as input, so a user can add art and URLs and upload it there. The cost is small: one pure function in `DirigibleCore` (Foundation `JSONEncoder` only), one CLI command, one menu item, and two strings in English and Spanish.
- Content: `"version": "1.2.0"` and `chapters`. Each chapter has `startTime` and `title` only, in ascending order (at one position, by ID). Write only markers of the kind `chapter`. Write no `img`, `url`, `toc`, or `endTime`: the model has no values for them. Add them with F56.
- Time: `startTime` = (position − export range start) / session rate, rounded to milliseconds. The ID3 `CHAP` frame also uses milliseconds, so both paths give the same times. Seconds do not depend on the export rate.
- Range: File > Export Chapters... writes the chapters of the whole session. For a range (Export Selection), drop the chapters outside the range. Inference: a chapter at the range start is at 0.
- Leave the file with no chapters out: an export with no chapter markers is an error, not an empty file.

**2. Import `chapters.json` to chapter markers: Release 3, with F56.**

- Import is a boundary: parse and validate the JSON there (a missing or negative `startTime`, an unknown version). The questions (replace the chapters or add to them, and where to keep `img` and `url`) need the F56 model. Without F56, an import loses the art and the URLs.
- Frame = round(`startTime` × session rate). Skip a chapter with `toc` false, or keep it as a marker of the kind `marker`. The F56 run decides.

**3. Embed chapters in the audio file: Release 3, with F55 and F56.**

- MP3: write an ID3v2.4 tag with `CHAP` frames (with `TIT2`) and one top-level, ordered `CTOC`. Put it in the same ID3 writer as F55. The MP3 export arrives in Release 2 (0007), so this step can come only after it.
- M4A: first a probe of the AVFoundation chapter track write (section 6). If it fails, write the boxes directly. Write the QuickTime form. Add `chpl` only if a target player needs it.
- WAV and FLAC: no chapters.

**4. Transcripts (F27): keep them in Later.** When F27 comes, write VTT first (Apple, Spotify, and the Podcasting 2.0 examples take it, and it names the speaker), then SRT, then the JSON format. This research changes nothing in the F27 order.

**CLI (0011).**

- Release 2: `dirigible chapters export <package> --out <file.json> [--from N] [--to N] [--replace]`. It writes the file and nothing to stdout. Exit 2 for a package fault or an existing `--out` without `--replace`. Exit 1 when the session has no chapter markers. Exit 64 for a bad range. `--json` is not needed: the extension of `--out` gives the format, as in `dirigible export`.
- Release 3: `dirigible chapters import <package> <file.json> [--replace]`, which writes the new marker IDs, one on each line. The embed has no command of its own: `dirigible export` always writes the chapters of the range into an MP3 or M4A file.
- Inference: the noun `chapters` (plural) names a file of chapters. The existing `marker` noun edits one marker.

## Sources

- [JC] JSON Chapters format, Podcast Namespace: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/examples/chapters/jsonChapters.md
- [JE] JSON Chapters example file: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/examples/chapters/example.json
- [PC] The podcast:chapters tag: https://podcasting2.org/docs/podcast-namespace/tags/chapters
- [PT] The podcast:transcript tag: https://podcasting2.org/docs/podcast-namespace/tags/transcript
- [TE] Transcript formats, Podcast Namespace examples: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/examples/transcripts/transcripts.md
- [AR] Argo site: https://getargo.app/
- [AB] Argo announcement, Sujetame el micro (2026-06-26): https://sujetameelmicro.com/argo-una-app-para-crear-chapters-de-podcasting-2-0-en-el-mac/
- [H2] Hindenburg PRO 2.02 release note: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2590/
- [HE] Hindenburg chapter export pages (no text found): https://hindenburg.com/data/functions/chapters-select-and-export-all-chapters/ and https://hindenburg.com/data/youtube/videos/how-to-export-all-chapters-in-hindenburg-pro-hindenburg/
- [HX] Hindenburg PRO 2 transcription: https://hindenburg.com/hindenburg-pro-2-features/transcription/
- [EP] podcast-chapter-parser-hindenburg: https://github.com/eteubert/podcast-chapter-parser-hindenburg
- [AP] Audacity pull request 9935: https://github.com/audacity/audacity/pull/9935
- [AU] Audacity 3.7.8 release: https://github.com/audacity/audacity/releases/tag/Audacity-3.7.8
- [AC] Apple, using chapters on Apple Podcasts: https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts
- [AT] Apple, transcripts on Apple Podcasts: https://podcasters.apple.com/support/5316-transcripts-on-apple-podcasts
- [PN] Podnews, Apple Podcasts automatic chapters FAQ (2025-11-04, updated 2026-04-21): https://podnews.net/article/apple-chapters-faq
- [RC] RSS.com, chapter support across different apps: https://help.rss.com/en/support/solutions/articles/44002628416-chapter-support-across-different-apps
- [BZ] Buzzsprout, chapter markers: https://www.buzzsprout.com/help/61-chapter-markers
- [TF] Transistor, add transcripts: https://support.transistor.fm/en/article/how-to-add-transcripts-to-your-podcast-episodes-1tau786/
- [SP] Spotify, managing episode transcripts: https://support.spotify.com/us/creators/article/managing-episode-transcripts-on-spotify/
- [SN] Podnews, Spotify supporting Podcasting 2.0 for transcripts (2025-06-12): https://podnews.net/update/spotify-transcripts-p20
- [FS] Add ID3 tags and chapters to a podcast MP3 (secondary source): https://freestreamhosting.org/how-to-add-id3-tags-and-chapters-to-a-podcast-mp3/
- [ID] ID3v2 Chapters 1.0 (Mutagen mirror): https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2-chapters-1.0.html (original, HTTP 503 on 2026-09-27: https://id3.org/id3v2-chapters-1.0)
- [QC] Apple, QuickTime File Format, chapter lists: https://developer.apple.com/documentation/quicktime-file-format/chapter_lists
- [MA] mp4-atom pull request 232, Nero chpl box: https://github.com/kixelated/mp4-atom/pull/232
- [MP] mp4v2 mp4chaps (DeepWiki): https://deepwiki.com/enzo1982/mp4v2/5.2-mp4chaps:-chapter-manager
- [AV1] Apple, AVAssetTrack.AssociationType.chapterList: https://developer.apple.com/documentation/avfoundation/avassettrack/associationtype/chapterlist
- [AV2] Apple, AVAsset chapter metadata groups: https://developer.apple.com/documentation/avfoundation/avasset/loadchaptermetadatagroups(withtitlelocale:containingitemswithcommonkeys:)
- [AF1] Apple Developer Forums, writing chapter data with AVAssetWriter (2019): https://developer.apple.com/forums/thread/115722
- [JCH] Commit history of the JSON Chapters spec file (2026-10-09): https://github.com/Podcastindex-org/podcast-namespace/commits/main/docs/examples/chapters/jsonChapters.md
- [JT] Podcast Namespace repo tree, no JSON Schema for chapters (2026-10-09): https://api.github.com/repos/Podcastindex-org/podcast-namespace/git/trees/main?recursive=1
- [SS] SchemaStore catalog, no chapters schema (2026-10-09): https://www.schemastore.org/api/json/catalog.json
- [H5] Hindenburg PRO 2.05 build 2716, PSC export for chapters: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2716/
- [UV] Hindenburg feedback, "Export chapters in JSON 2.0 format": https://hindenburg.uservoice.com/forums/224350-general/suggestions/47499599-export-chapters-in-json-2-0-format
- [LP] Logic Pro, use marker information from audio files: https://support.apple.com/guide/logicpro/use-marker-information-lgcpadb63ff8/mac
- [GB] Apple, GarageBand for Mac enhanced podcasts: https://support.apple.com/en-us/101746
- [AF] Audacity 3.7.8 FileMenus.cpp, Export Labels: https://github.com/audacity/audacity/blob/Audacity-3.7.8/src/menus/FileMenus.cpp
- [TM] Transistor, add MP3 chapters: https://support.transistor.fm/en/article/how-do-i-add-mp3-chapters-to-my-podcast-episode-1ts9azc/
- [AF2] Apple Developer Forums, writing chapters to audio asset (2020): https://developer.apple.com/forums/thread/134008
- [AF3] Apple Developer Forums, chapter marks in M4A (2023): https://developer.apple.com/forums/thread/735028
- [SF] Swift Forums, writing chapters to an audio asset in AVFoundation: https://forums.swift.org/t/writing-chapters-to-an-audio-asset-in-avfoundation/37441
