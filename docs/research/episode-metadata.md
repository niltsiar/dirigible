# Episode metadata in MP3 and M4A files

Date: 2026-10-10

This document records the episode metadata that an MP3 file (ID3v2) and an M4A file (iTunes atoms) can hold. It says which podcast apps read each field from the file. Chapters are in `docs/research/podcasting-2.md` ([podcasting-2.md](podcasting-2.md)). This document does not repeat them. A claim that no owner source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## 1. Field table

"Feed" means that the app takes the value from the RSS feed, not from the file. "None found" means that no source shows an app that reads the field from the file.

| Field | ID3 frame (v2.3 / v2.4) | MP4 atom | Who reads it from the file | Source |
|---|---|---|---|---|
| Episode title | `TIT2` | `©nam` | Pocket Casts Android, only for a file that the user adds; feeds give the title | [S23] [S24] [PCA] |
| Show | `TALB` | `©alb` (also `tvsh`, show name) | None found | [S23] [MUT] |
| Author | `TPE1`; `TPE2` = album artist | `©ART`; `aART` = album artist | None found | [S23] [ITU] [MUT] |
| Episode number | No frame. Inference: `TRCK` | `tves` (32-bit integer) | None found; feed `itunes:episode` | [S23] [MUT] [SPS] |
| Season | No frame. Inference: `TPOS` | `tvsn` (32-bit integer) | None found; feed `itunes:season` | [S23] [MUT] [SPS] |
| Date | `TYER` (YYYY) + `TDAT` (DDMM) / `TDRC` (timestamp); v2.4 also has `TDRL` (release time) | `©day` | None found | [S23] [CHG] [MP3T] |
| Genre "Podcast" | `TCON`, a text string | `©gen`; `geID` (store genre ID; value for Podcasts unconfirmed) | None found | [S23] [S24] [MUT] |
| Language | `TLAN`, ISO 639-2 | No iTunes atom. The track language is in `mdhd` (`AVAssetWriterInput.languageCode`, ISO 639-2/T) | None found | [S24] [AVW] |
| Copyright | `TCOP` (starts with a year and a space) | `cprt` | None found | [S24] [MUT] |
| Explicit | No standard frame. Mp3tag maps none for ID3. `TXXX:ITUNESADVISORY` is a tagger convention (unconfirmed) | `rtng`, 8-bit: 0 none, 1 explicit, 2 clean | None found; feed `itunes:explicit` | [MP3T] [MUT] [SPS] |
| Short notes | `COMM` (encoding, language, descriptor, text) | `desc` | None found | [S24] [MUT] |
| Long notes | `TDES` (iTunes, non-standard) | `ldes` (Mp3tag only; Mutagen does not list it) | None found | [MP3T] [MUT] |
| Episode URL | `WOAF`; `WXXX` (URL always ISO-8859-1) | None | None found | [S24] |
| Feed URL | `WFED` (iTunes, non-standard) | `purl` (UTF-8 text) | None found | [MUT] [MP3T] [LAME] |
| Podcast flag | `PCST` (iTunes, non-standard) | `pcst` (boolean) | None found. Mutagen: iTunes reads `pcst` "only on import" | [MUT] [MP3T] [LAME] |
| Episode GUID | `TGID` (iTunes, non-standard) | `egid` (UTF-8 text) | None found | [MUT] [MP3T] |
| Keywords | `TKWD` (iTunes, non-standard) | `keyw` | None found | [MUT] [MP3T] |
| Category | `TCAT` (iTunes, non-standard) | `catg` | None found | [MUT] [MP3T] |
| Artwork | `APIC`, type `$03` front cover, `image/jpeg` or `image/png` | `covr`, data type 13 (JPEG) or 14 (PNG) | Pocket Casts, only when the feed has no episode image | [S23] [S24] [WKT] [PCK] [PCA] |
| Media kind | None | `stik` (Podcast value unconfirmed) | None found | [MUT] [MP3T] |

### The iTunes frames

- No id3.org document defines `PCST`, `TGID`, `TDES`, `WFED`, `TKWD`, or `TCAT` [S23] [S24] [ITU]. Apple publishes no definition (unconfirmed). Tagger source code and tagger documentation are the only references.
- Mutagen types `TGID`, `TDES`, `TKWD`, and `TCAT` as text frames [MUT].
- `PCST`: Mutagen writes an integer of at least 4 bytes, so the value 1 is `00 00 00 01` [MUT]. LAME 4.0 writes `PCST` as a text frame with an encoding byte [LAME]. The two framings differ. The framing that Apple expects is unconfirmed.
- `WFED`: Mutagen types it as a URL frame (no encoding byte) [MUT]. LAME writes it as a text frame, with the comment "iTunes expects WFED to be a text frame" and "violates standard" [LAME].
- Inference: no app in this list reads these frames. Do not make a feature depend on them.

### AVFoundation and Core Audio names

- The macOS 26.2 SDK header has `AVMetadataIdentifier` constants for `TIT2`, `TALB`, `TPE1`, `TPE2`, `TYER`, `TDAT`, `TDRC`, `TCON`, `TLAN`, `TCOP`, `COMM`, `TRCK`, `TPOS`, `WOAF`, `WXXX`, `TXXX`, and `APIC` [AVH].
- It has iTunes constants for song name, album, artist, album artist, release date, genre, genre ID, content rating, description, copyright, track number, disc number, and cover art [AVH].
- It has no constant for `PCST`, `TGID`, `TDES`, `WFED`, `TKWD`, `TCAT`, `pcst`, `purl`, `egid`, `keyw`, `catg`, `tves`, `tvsn`, or `ldes` [AVH].
- AVFoundation gives a frame with no constant by its raw key: Pocket Casts iOS reads `CHAP` and `CTOC` with the key space `org.id3` [PCI].
- `kAudioFilePropertyID3Tag` gets and sets a whole tag of "v2.2, v2.3, or v2.4", and does not change it. A set must come before `AudioFileWritePackets` [ATB].

## 2. Do the apps read metadata from the file?

- **Apple Podcasts:** it takes episode data from the RSS feed [APR]. From the file it reads chapters [AC] and loudness metadata ("modify the ID3 tags of an MP3 file or in the header of an MP4 file") [AAR]. No source says that it reads the title, notes, or art from the file (unconfirmed).
- **Overcast:** "Overcast displays MP3 and M4A chapter markers with titles, images, and/or link URLs." Its servers "download episodes to collect metadata" [OVP]. No source says that it shows embedded episode art or notes (unconfirmed). Overcast's encoder Forecast "embeds artwork, title, and description in each MP3" [OVF].
- **Pocket Casts:** the feed episode image comes first. When the feed has none, the app falls back "to artwork embedded in the audio file itself (for example, in the ID3 tags)". The setting "Use episode artwork" must be on [PCK]. The Android source reads `CHAP` (with `TIT2`, URL, and `APIC` sub-frames), `APIC`, `TIT2`, and `TLEN` [PCA]. It uses `TIT2` only for a file that the user adds [PCA]. The iOS source reads ID3 `CHAP`/`CTOC` and MP4 chapter groups through AVFoundation [PCI].
- **Spotify:** the delivery spec takes all metadata from an RSS XML file. It does not mention ID3 [SPS]. The upload page says: "If you're uploading MP3 files, we recommend keeping embedded artwork, ID3v2 tags, and other metadata as small as possible." [SPU]. The title, notes, season, episode, and art go in the upload form [SPU].
- **Hindenburg PRO 2:** "Embed ID3 metadata directly into MP3 files" [HF]. The PRO 2 field list was not found (unconfirmed). The Journalist 1.21 manual has these episode fields: Episode, Subtitle, Podcast, Episode No, Keyword, Image, Author, Summary, Date, Explicit (No, Yes, Clean), Copyright, Email, and the RSS feed name [HM p64]. File > Properties filters the fields by General, MP3, MP4, and Podcast. The values go into WAV, MP3, MP4, AIFF, and Apple Lossless exports [HM p74]. The ID3 version that Hindenburg writes is unconfirmed.

## 3. ID3v2.3 or ID3v2.4

- id3.org: "the most popular version implemented today is ID3 version 2.3". Version 2.4 "has not achieved popular status" [ID3].
- Encodings: v2.3 has `$00` ISO-8859-1 and `$01` UTF-16 with a BOM [S23]. v2.4 adds `$02` UTF-16BE and `$03` UTF-8 [S24S].
- Frame size: v2.3 uses a plain 32-bit size [S23]. v2.4 uses a synchsafe size [S24S]. Old iTunes read v2.4 frame sizes as plain integers, fixed "about iTunes 8" [ITU].
- v2.4 replaces `TYER`, `TDAT`, `TIME`, and `TRDA` with `TDRC`, and `TORY` with `TDOR` [CHG].
- Apple: Core Audio gets and sets v2.2, v2.3, and v2.4 tags [ATB]. iTunes writes all three [ITU].
- LAME 4.0 writes v2.3 by default, and v2.4 with UTF-8 only after `id3tag_add_v2_4_UTF8` [LAME].
- LAME bug: in v2.4 mode it still writes plain 32-bit frame sizes (`Sources/CLame/id3tag.c`, lines 1657 to 1768). A frame of 128 bytes or more is then not valid v2.4. An `APIC` frame is always that large [LAME].
- Windows Explorer and old players with v2.4: not checked.
- **Recommendation: write ID3v2.3 with `$01` UTF-16 and a BOM.** It is the most common version, Apple reads it, and LAME writes it correctly. Write the date as `TYER` + `TDAT`.

## 4. Artwork size

- Apple episode art: 3000 x 3000 px preferred, 1400 to 3000 px accepted through RSS, PNG or JPG, no transparency or alpha channel [AEA]. Show art has the same limits [ASC]. Chapter art: 3000 x 3000 px, PNG or JPG [ACA].
- No Apple source gives a size for art embedded in the file (unconfirmed). Spotify asks for small embedded art [SPU]. Hindenburg 1.21 recommends 300 x 300 or 900 x 900 for chapter images [HM p62].
- ID3 limits a tag to 256 MB (28-bit size) [S24S]. `APIC` type `$01` is a 32 x 32 PNG file icon, and type `$03` is the front cover [S23].
- LAME `id3tag_set_albumart` takes JPEG, PNG, or GIF. It writes picture type 0 ("Other"), not `$03`, with an empty description [LAME].
- Inference: embed a JPEG of 1400 x 1400 px or smaller. Keep the full 3000 px art for the feed.

## 5. Room for chapters and other facts for the design

- `CHAP` and `CTOC` frames go in the same ID3v2 tag as the fields above [podcasting-2.md](podcasting-2.md). LAME 4.0 does not write them [LAME]. State on 2026-11-24: built. `ID3Tag.swift` writes the tag (decision 0045). Inference of 2026-10-10: one ID3v2.3 tag writer in Dirigible must hold all frames, with `lame_set_write_id3tag_automatic(gfp, 0)` so that LAME writes no tag.
- The MP4 chapter list is a text track with a `chap` track reference. `AVAssetTrack.AssociationType.chapterList` exists. No source confirms a working write to an audio-only M4A ([podcasting-2.md](podcasting-2.md), section 6).
- On 2026-10-10, `MP3File.swift` wrote the LAME tag frame at byte 0. An ID3v2 tag at the start of the file moves that frame by the tag size. State on 2026-11-24: `MP3File.swift` writes the LAME tag frame after the ID3 tag, at offset `tag.count` (decision 0034, amended 2026-10-10).
- State on 2026-11-24: the M4A question below is answered. `M4ATags.swift` writes the tags (decision 0045).
- M4A: `AVAssetWriter.metadata` writes top-level metadata [AVW]. Export writes M4A with `AVAudioFile` (decision 0007). Open question: can `AudioFileSetProperty` with `kAudioFilePropertyInfoDictionary` or `kAudioFilePropertyAlbumArtwork` set iTunes atoms in an M4A? Probe for a later run: write an M4A with `AVAudioFile`, then try both properties and `AVAssetWriter` with `iTunesMetadataSongName` and a raw `tves` item. Read the file back with `AVAsset` and `mp4dump`.

## Sources

- [S23] ID3v2.3.0 (Mutagen mirror of id3.org): https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.3.0.html
- [S24] ID3v2.4.0 native frames: https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.4.0-frames.html
- [S24S] ID3v2.4.0 main structure: https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2.4.0-structure.html
- [CHG] ID3v2.4.0 changes: https://id3.org/id3v2.4.0-changes
- [ID3] id3.org home page: https://id3.org/
- [ITU] id3.org, iTunes: https://id3.org/iTunes
- [AVH] macOS 26.2 SDK, `AVFoundation.framework/Headers/AVMetadataIdentifiers.h` and `AVMetadataFormat.h` (Xcode 26.2). Online: https://developer.apple.com/documentation/avfoundation/avmetadataidentifier
- [AVW] macOS 26.2 SDK, `AVAssetWriter.h` (`metadata`) and `AVAssetWriterInput.h` (`languageCode`)
- [ATB] macOS 26.2 SDK, `AudioToolbox.framework/Headers/AudioFile.h` (`kAudioFilePropertyID3Tag`, `kAudioFilePropertyAlbumArtwork`) and `AudioFormat.h`
- [WKT] Apple, QuickTime File Format, well-known types: https://developer.apple.com/documentation/quicktime-file-format/well-known_types
- [MUT] Mutagen source, `id3/_frames.py`, `id3/_specs.py`, `mp4/__init__.py`: https://github.com/quodlibet/mutagen/tree/main/mutagen
- [MP3T] Mp3tag, tag field mappings: https://docs.mp3tag.de/mapping/
- [LAME] LAME 4.0 `libmp3lame/id3tag.c`, vendored as `Sources/CLame/id3tag.c`: https://sourceforge.net/projects/lame/files/lame/4.0/
- [APR] Apple, podcast RSS feed requirements: https://podcasters.apple.com/support/823-podcast-requirements
- [AAR] Apple, audio requirements: https://podcasters.apple.com/support/893-audio-requirements
- [AC] Apple, using chapters on Apple Podcasts: https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts
- [AEA] Apple, episode art template: https://podcasters.apple.com/support/5516-episode-art-template
- [ASC] Apple, show cover template: https://podcasters.apple.com/support/5514-show-cover-template
- [ACA] Apple, chapter art template: https://podcasters.apple.com/support/5528-chapter-art-template
- [OVP] Overcast, info for podcasters: https://overcast.fm/podcasterinfo
- [OVF] Overcast, Forecast: https://overcast.fm/forecast
- [PCK] Pocket Casts, episode artwork: https://support.pocketcasts.com/knowledge-base/episode-artwork/
- [PCA] Pocket Casts Android, `EpisodeFileMetadata.kt` and `AddFileActivity.kt`: https://github.com/Automattic/pocket-casts-android/blob/main/modules/services/repositories/src/main/java/au/com/shiftyjelly/pocketcasts/repositories/playback/EpisodeFileMetadata.kt
- [PCI] Pocket Casts iOS, `MNAVChapterReader.m`: https://github.com/Automattic/pocket-casts-ios/blob/trunk/Modules/Sources/MNAVChapters/MNAVChapterReader.m
- [SPS] Spotify, Podcast Delivery Specification 1.10 (May 2025): https://assets.ctfassets.net/jtdj514wr91r/4r4op9KhH3fY1t3BKt2eiH/7b1b682acf4c41baf79f9574d6dedd7f/Podcast_Delivery_Specification_v1.10_-_master_doc.pdf
- [SPU] Spotify for Creators, publishing audio episodes: https://support.spotify.com/us/creators/article/publishing-audio-episodes/
- [HF] Hindenburg PRO features: https://hindenburg.com/products/radio-podcast/features/
- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 62, 64, 74 (text read with PDFKit on 2026-10-10): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
