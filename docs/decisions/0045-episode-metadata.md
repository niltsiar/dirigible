# 0045. Episode metadata: one episode element in session.xml version 6, artwork files in the package, and an own ID3v2.3 writer

- Status: accepted
- Date: 2026-10-10
- Accepted: 2026-10-10, after plan gates 1 and 2 of run `2026-10-10-episode-metadata`.
- Amended: 2026-10-11, run `2026-10-11-chapters-in-file`. A marker can have a URL and an image. The image is a file in `Artwork/` with the rules of the episode artwork, and `session.xml` is then version 7 (see 0024). The MP3 has `CTOC` and `CHAP` frames, and an M4A with chapters goes through an `AVAssetWriter` copy, not the export session pass. The title sample of a chapter with a URL has a 3GPP `href` box, and a chapter image goes into the image track as a JPEG.
- Amends: 0003 (the layout has `Artwork/`), 0024 (`session.xml` is version 6 with episode data), 0034 (an MP3 with episode data starts with an ID3 tag, and the LAME tag frame follows it), 0041 (the tools `episode_set` and `episode_get`).

## Context

F55 (R10, R11) asks for the metadata that podcast apps read: title, show, author, episode and season numbers, date, genre, language, copyright, the explicit flag, a description and notes, the episode and feed URLs, the podcast flags, and the artwork, in the session, the MP3 and M4A exports, the app, and the CLI. Run 5 (F56 part) adds chapters inside the file with a title, a URL, and an image.

Research ([episode-metadata](../research/episode-metadata.md)): Apple Podcasts, Overcast, and Spotify take the episode fields from the RSS feed; they read only chapters (and loudness) from the file. Pocket Casts reads APIC when the feed has no episode image. Hindenburg embeds ID3. id3.org calls v2.3 the most popular version.

Probes of run `2026-10-10-episode-metadata` (macOS 15.7.9, Swift 6.2.4):

- AVFoundation has no MP3 output type (`AVAssetWriter` raises "Invalid file type UTI"), and `AudioFileSetProperty(kAudioFilePropertyInfoDictionary)` on an MP3 gives 'pty?'.
- A v2.3 tag in front of the LAME tag frame keeps the exact length (132300 frames) in AVFoundation and ffprobe. AVFoundation reads each frame.
- An `AVAssetExportSession` passthrough with iTunes metadata items writes each atom and keeps the audio packets (same MD5), the frame count, and `iTunSMPB`.
- An XML attribute reads LF back as a space; element text keeps it.

## Decision

**Model.** `DirigibleCore` (Foundation only) has small value types with throwing initializers: `EpisodeNumber` (1 to 99999), `WebURL` (`http` or `https`, stored as its `absoluteString`, refused when that is not all ASCII), `CalendarDate` (year, month, day), `LanguageCode` (three lowercase letters; an ISO 639-2/B code maps to its T code by a fixed table, for example `fre` to `fra`; no ICU data), `EpisodeLine` (one line, no control character) and `EpisodeNotes` for `summary` and `notes` (LF and tab stay; CR LF, CR, a vertical tab, and a form feed become LF; the other control characters, U+FFFE, and U+FFFF go, because a paste from a PDF can hold them and nobody sees them, so notes refuse no text); in both, a value of only whitespace (`Character.isWhitespace`) is no value, and an artwork name `<UUID>.jpg` or `<UUID>.png`. `Episode` is a plain struct of optional typed fields. The reader, the CLI, the MCP tools, and the UI parse at the boundary. Genre is always Podcast and is not stored. `Session.episode` is set only through `Session.setEpisode(_:)`, one edit and one undo entry. An empty episode is the default.

**session.xml.** One optional element after `<markers>`. Each attribute is written only when it has a value; the element is written only when the episode is not empty.

```xml
<episode title="Café" show="The Show" author="Ana" number="12" season="3" date="2026-10-10"
         language="spa" copyright="© 2026 Ana" explicit="true" episodeURL="https://..."
         feedURL="https://..." guid="urn:uuid:..." artwork="0F3A...-.jpg">
  <summary>Short description</summary>
  <notes>Long notes, with line breaks</notes>
</episode>
```

`fileVersion` is 6 when the episode is not empty, else as before. The reader refuses `<episode>` in a file of version 5 or lower (`.invalidValue`), as for fades (0035). The attribute names are frozen: a rename makes a newer file read as damaged (0024 P1).

**Artwork.** The app and the CLI refuse an iCloud file whose data is not on the Mac (`sourceIsDownloaded`, 0040). They copy the chosen file, with its bytes unchanged, to a dot-temporary name in `Artwork/` (`artworkFolderName` and `temporaryArtwork(of:)` beside `clipsFolderName` in `SessionWriter.swift`), call `fsync`, rename it to `Artwork/<UUID>.<ext>`, and flush the folder with `fullFlush`. Only then does the edit name it. The app runs the copy and the edit through `Studio.blockingRun`, which stops play, as `pasteAcross` does. `removeTemporaryFiles` removes a leftover dot-temporary file in `Artwork/` under the open lock. A new image always gets a new name, so undo, redo, and a backup revert (0043) find their image. The import reads the type and the pixel size with `CGImageSource` properties, with no full decode, and refuses a file that is not a square JPEG or PNG with a side of at most 3000 px. This run removes no artwork file; the unused-file scan of F87 includes `Artwork/`.

**MP3.** Dirigible writes its own ID3v2.3 tag (UTF-16 with a BOM) as a list of frames: TIT2, TALB, TPE1, TPE2, TRCK, TPOS, TYER, TDAT, TCON, TLAN, TCOP, TXXX ITUNESADVISORY, COMM, TDES, WOAF, WXXX, WFED (a URL frame, as AVFoundation and Mutagen read it), PCST (`00 00 00 01`), TGID, and APIC (type 03). `writeMP3` writes the tag at offset 0, then the audio, then the LAME tag frame at the offset of the tag size. An empty episode writes no tag, so the file is the same as before. Run 5 appends CHAP and CTOC to the same list.

**M4A.** After the `ExtAudioFile` write, a passthrough `AVAssetExportSession` pass copies the temporary file to `.<name>.<UUID>.tag.tmp` in the same folder with iTunes metadata items. The leftover sweep runs in two steps: it removes each dead `.tmp` file (the lock probe), then each `.tag.tmp` file with no `.tmp` file of its UUID. The source opens with `AVURLAssetOverrideMIMETypeKey` `audio/mp4`, because a `.tmp` source fails with -11800 (OSStatus -16979). The items are (©nam, ©alb, ©ART, aART, tves, tvsn, ©day, ©gen, cprt, rtng, desc, ldes, purl, pcst, egid, covr). `exportMix` is synchronous: it waits for `exportAsynchronously` in a loop of 50 ms waits that reads `isCancelled()` and calls `cancelExport()`, then waits a bounded time for the completion. It reads `isCancelled()` again after the pass completes. It flushes the tagged file through a flush seam (a stored closure that defaults to `fullFlush`) before the move, removes both temporary files on each exit, and calls progress 1.0 after the pass. An empty episode skips the pass. Run 5 replaces this pass with an `AVAssetReader` to `AVAssetWriter` copy that adds a chapter track.

**CLI and MCP.** `dirigible episode set` has one option for each field; an empty value clears it. `dirigible episode show` prints the fields. The MCP tool `episode_set` takes the same fields, and `episode_get` returns them. The JSON keys of `episode show`, `episode_get`, and the `episode` object of `info --json` are the argument names of `episode_set`: `episode`, `episode_url`, and `feed_url`, not the `session.xml` names.

## Consequences

- An older build refuses a session with episode data ("made by a newer version of Dirigible (version 6)").
- WAV and FLAC exports carry no metadata. The M4A file has no language.
- Unused artwork files stay in the package until F87.
- LAME writes WFED as a text frame because iTunes expected one. AVFoundation reads such a frame as an empty URL, so Dirigible writes a URL frame. No podcast app reads WFED.
- The episode fields do not reach the podcast apps that read the feed. The user enters them again in the host. The chapters of run 5 are the part that those apps read from the file.

## Alternatives considered

- **A generic list of key and value pairs** (`<meta key="title" value="..."/>`). It adds a field with no version raise, but an older build that reads it drops an unknown key on save (0003), and the types (numbers, dates, URLs) move from the reader to each caller. Rejected.
- **A sidecar file** (`episode.json` in the package). It keeps `session.xml` unchanged, but the undo, the backup copy (0043), and the version policy (0024) cover only `session.xml`. Rejected.
- **Artwork bytes in session.xml** (base64). One file to copy, but `Session` is `Hashable` and the lanes compare it, and each save writes megabytes. Rejected.
- **LAME `id3tag.c`.** It writes v2.3 text frames and APIC, but with picture type 0, and no CHAP or CTOC, which run 5 needs. Rejected.
- **ID3v2.4 with UTF-8.** Smaller text, but less widely read than v2.3. Rejected.
