# Research: chapter title, URL, and image inside the audio file

Date: 2026-10-11

This file adds to [chapters.md](chapters.md), [podcasting-2.md](podcasting-2.md) (section 6), and [episode-metadata.md](episode-metadata.md). "(unconfirmed)" marks a claim that no primary source confirms. "Inference:" marks our reading of the sources.

## 1. Hindenburg

- Journalist 1.21: View > Chapters (Option-Command-H) opens the Chapters view. Shift-Command-Enter adds a chapter at the playhead. Right-click on a marker makes it a chapter [HM p61, p62].
- A chapter has Time, Title, Image, and URL, "used by iTunes", for "Enhanced Podcasts (AAC) or Audio Books" [HM p61].
- Title: click and rename. URL: two fields, "URL Title" (the text "viewed in iTunes") and "URL" (the link) [HM p63].
- Image: drag and drop, or right-click > Set image. Formats: JPG, PNG, GIF, BMP. "Any size", resized "for iTunes" [HM p62].
- PRO guide entries: Chapters - Add Image ("Import or drag image to the Chapter"), Clear Image, Move Image ("Repossition or crop"), Rotate Image Left/Right, URL, URL Title [HG].
- MP3 chapters came in version 1.52 (Hindenburg reply, 2016-09-02) [HU]. Users reported in 2017 and 2019 that Overcast did not recognize these chapters [HU].
- No Hindenburg source says that PRO 2 writes the image and the URL into MP3 `CHAP` (unconfirmed).

## 2. M4A chapter images

- SDK: the chapter track "may be a text track, a video track, or a timed metadata track" (`AVAssetTrack.h`, `AVTrackAssociationTypeChapterList`) [SDK].
- SDK: chapter groups include "items with the common key AVMetadataCommonKeyArtwork, if such items are present" (`AVAsset.h`) [SDK].
- ChapterForge copies Apple-made files: audio `tref/chap` points to a `tx3g` title track and a `vide` JPEG track. A third `tx3g` URL track has no `chap` reference. Text tracks have `tkhd` flags 1, the image track flags 7 [CF]. This conflicts with "normally not enabled" in QTFF ([podcasting-2.md](podcasting-2.md)). Which flags Apple writes is unconfirmed.
- ChapterForge: use baseline JPEG, 4:2:0, all images one size [CF].
- Pocket Casts iOS (MP4): title from key `title`, image from the first `artwork` item `dataValue`, URL from the title item `extraAttributes["HREF"]` [PCI].
- ffmpeg `mov.c`: a video chapter track becomes one attached picture (the first frame only). A text chapter track gives titles only [FM].
- Overcast shows M4A chapter images and URLs ([episode-metadata.md](episode-metadata.md)). Apple Podcasts: no current Apple source (unconfirmed). Auphonic (2013): "Chapter image and title in Apple's Podcast app" [AB].

## 3. M4A chapter URL

- The QTFF text sample is a 16-bit length, the text, then optional atoms. Its atom table has no `href` [QT].
- ChapterForge writes the URL as an `href` box in `tx3g` samples. It copies each URL into the title sample too, so AVFoundation shows it as `extraAttributes[HREF]` [CF]. Inference: `href` is the 3GPP timed-text hypertext box (TS 26.245 not read).
- `"HREF"` is not a public constant. The SDK has only `AVMetadataExtraAttributeValueURIKey`, `...BaseURIKey`, and `...InfoKey` (`AVMetadataFormat.h`) [SDK].
- Readers: Pocket Casts iOS reads it and keeps only `http` or `https` [PCI] [PCP]. ffmpeg `movtextdec.c` has no `href` code [FT]. ChapterForge: QuickTime, Music, and Books show no URL [CF].

## 4. Writing with AVFoundation

No Apple doc, sample, or WWDC session shows a chapter write. The constant is `AVTrackAssociationTypeChapterList` (Swift `AVAssetTrack.AssociationType.chapterList`). `AVAssetTrackAssociationTypeChapterList` does not exist [SDK]. Recipes, best evidence first:

1. `AVAssetWriter` with `AVFileTypeAppleM4A`. Text input: `assetWriterInputWithMediaType:outputSettings:sourceFormatHint:` (`AVMediaTypeText`). The hint comes from `CMFormatDescriptionCreate` (`kCMMediaType_Text`, `kCMTextFormatType_3GText`, extensions). Set `marksOutputTrackAsEnabled = NO`. Call `addTrackAssociationWithTrackOfInput:type:` on the audio input. Each sample is a big-endian 16-bit length and UTF-8 text. Set a language tag: idb says that AVFoundation skips an untagged chapter track [ID]. Evidence: holos does this, and its test reads the titles back with `loadChapterMetadataGroups` [HO]. That repo has 0 stars and we did not run it (unconfirmed).
2. The same with `CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData` and QT `'text'`, plus `languageCode = "und"`. idb uses it for video [ID]. The 2019 forum thread got -12717 from this call ([podcasting-2.md](podcasting-2.md)).
3. Image track: an `AVMediaTypeVideo` input with JPEG samples and a second `chapterList` association. Only the header comment supports it [SDK]. The header names "chapter name tracks and chapter image tracks" for `AVAssetWriterInputMediaDataLocationBeforeMainMediaDataNotInterleaved` [SDK]. No header says that `.m4a` takes video. `availableMediaTypes` gives the answer at run time [SDK].
4. `AVMutableMovie`: `-[AVMutableMovieTrack addTrackAssociationToTrack:type:]`, `appendSampleBuffer:decodeTime:presentationTime:error:` (Swift `append(_:decodeTime:presentationTime:)`; `append(_:)` with `CMReadySampleBuffer` from macOS 26), `insertMediaTimeRange:intoTimeRange:`, `writeMovieHeaderToURL:fileType:options:error:`, `isCompatibleWithFileType:` [SDK]. `AVMovie.h` names chapter tracks as a use. Its examples name only `AVFileTypeQuickTimeMovie` [SDK].
5. `AVAssetWriterInputMetadataAdaptor` writes a `mebx` track. ffplay then shows times with empty titles. QuickTime and AVAsset show no chapters. The file was `.mp4` with video [AF4].

## 5. MP3 ID3 CHAP

- The addendum permits a `CHAP` with no `CTOC`, for example for images in sync with the audio. It names no URL frame and no picture type [ID3].
- Pocket Casts iOS: `CHAP` with `TIT2`, `WXXX`, and `APIC` of any picture type. It searches from the end, so the last frame of each ID wins. Chapters outside the first `CTOC` are hidden. When all chapters are hidden (no `CTOC`), it shows all [PCI] [PCP].
- Pocket Casts Android: a `UrlLinkFrame` (which W frames: media3 decoder not read) and any `APIC`. It needs no `CTOC`. It scales a large image down to the screen size [PCA].
- Overcast's Forecast writes "titles, link URLs, and images". It also writes chapters "that don't display in the chapter list" [OF]. Inference: these are `CHAP` frames outside the `CTOC`.
- ffmpeg writes `CTOC` flags 0x03, IDs `ch0`, `ch1`, ..., and offsets 0xFFFFFFFF. In a `CHAP` it writes only the text tags of `write_metadata`, no `APIC` [FI].
- Apple Podcasts and MP3 chapter images: no Apple source (unconfirmed). The picture type is a plan decision.

## 6. chapters.json `img` and `url`

- The spec says only "The url of an image" and "The url of a web page". It has no absolute or relative rule. Every example is absolute `https` [JC].
- Podlove Simple Chapters: `image` "is an URL", with no other rule [PSC].
- Auphonic: chapter images go into MP3 and MP4, not Vorbis Comment. It resizes them to at most 1400 x 1400 [AH]. Its Podcasting 2.0 JSON export is documented, but the `img` value is not (unconfirmed).
- Hindenburg's JSON `img` value: unconfirmed. Inference: a local image needs an upload and a public URL.

## 7. Apple Podcasts

- It reads chapters from the MP4 header and from MP3/AAC ID3 [AC].
- "If you submit chapters through your hosting provider, you can include images." The page says nothing about URLs or about images in the file [AC].
- Chapter art is 3000 x 3000 PNG or JPG ([episode-metadata.md](episode-metadata.md)). No size limit for art in the file (unconfirmed).

## 8. Probe P1 results (2026-10-11, macOS 15, Xcode 26.3)

- `AVAssetWriter` with `.m4a` writes a disabled `tx3g` track and a JPEG video track, both linked with `.chapterList`. AVFoundation and `ffprobe -show_chapters` read each title and start. Use `.m4a`, not `.mp4`: an `.mp4` decodes 133056 frames of 132300 and has no `iTunSMPB`.
- Set `movieTimeScale` and the `mediaTimeScale` of each chapter input to the output sample rate. At the default 600, a copy with no chapter decodes 131072 frames, and the audio track time range is 130188 frames.
- A start reads back at k / rate with no priming offset. The writer moves a first sample after 0 to 0, so a later first chapter needs a chapter at 0.
- Two text samples at one time stop the writer with -11800 (underlying -16364), and the file has no `moov`.
- A PNG video input fails `canAdd` for `.m4a` and `.mp4`, so a PNG chapter image must become a JPEG first.
- A gap in the image track does not give "no image": the image of the chapter before it stays.
- A 3GPP `href` box after the title text reads back as `extraAttributes["HREF"]` on the title item. ffprobe shows no URL.
- With the chapter samples first and one cancel read per sample, a cancel stops the copy of a 1 h file in about 5 ms.
- The writer does not finish while each thread of the Swift concurrency pool waits. Call the copy from a GCD thread or the main thread, not from many blocked tasks.

## Open questions for the plan

- P1 (M4A): a Swift script with `AVAssetWriter` `.m4a` prints `availableMediaTypes`. It writes 3 `tx3g` chapters, one with `href`, and a JPEG video track. It reads back with `loadChapterMetadataGroups` and `commonKeyArtwork`, and prints the title, time range, `extraAttributes`, and the artwork byte count. Open it in Music and QuickTime Player.
- P2: the same file through `AVMutableMovie`. Print `isCompatibleWithFileType(.m4a)`.
- P3: write the text track enabled and disabled. Which one does Music show?
- P4 (MP3): our ID3 writer makes `CHAP` with `WXXX` and `APIC`, once with and once without `CTOC`. Read it back with `AVAsset` ID3 metadata and the Pocket Casts hidden rule.
- P5: a Hindenburg PRO trial exports MP3 and M4A with one image and one URL chapter. Inspect them with `mp4dump` and `ffprobe -show_chapters`.

## Sources

- [HM] Hindenburg Journalist 1.21 guide, pages 61 to 63 (read with PDFKit, 2026-10-11): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HG] Hindenburg PRO guide: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HU] Hindenburg feedback, "Support podcast chapters for mp3s": https://hindenburg.uservoice.com/forums/224350-general/suggestions/13532589-support-podcast-chapters-for-mp3s
- [SDK] macOS 26.2 SDK (Xcode 26.3): `AVAssetTrack.h`, `AVAsset.h`, `AVAssetWriter.h`, `AVAssetWriterInput.h`, `AVMovie.h`, `AVMovieTrack.h`, `AVMediaFormat.h`, `AVMetadataFormat.h`, `AVFoundation.apinotes`, `CMFormatDescription.h`, `CMFormatDescriptionBridge.h`, `AVFoundation.swiftmodule/arm64e-apple-macos.swiftinterface`
- [QT] QuickTime File Format, text sample data: https://developer.apple.com/documentation/quicktime-file-format/text_sample_data
- [CF] ChapterForge README: https://github.com/tillt/ChapterForge/blob/main/README.md
- [PCI] Pocket Casts iOS, `MNAVChapterReader.m`: https://github.com/Automattic/pocket-casts-ios/blob/trunk/Modules/Sources/MNAVChapters/MNAVChapterReader.m
- [PCP] Pocket Casts iOS, `PodcastChapterParser.swift`: https://github.com/Automattic/pocket-casts-ios/blob/trunk/podcasts/PodcastChapterParser.swift
- [PCA] Pocket Casts Android, `EpisodeFileMetadata.kt`: https://github.com/Automattic/pocket-casts-android/blob/main/modules/services/repositories/src/main/java/au/com/shiftyjelly/pocketcasts/repositories/playback/EpisodeFileMetadata.kt
- [FM] ffmpeg `mov.c` (`mov_read_chapters`): https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/mov.c
- [FT] ffmpeg `movtextdec.c`: https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/movtextdec.c
- [FI] ffmpeg `id3v2enc.c` (`write_ctoc`, `write_chapter`): https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/id3v2enc.c
- [HO] holos, `AudioBookWriter.swift` and `Tests/HolosSynthesisTests/AudioBookWriterTests.swift`: https://github.com/orlenko/holos/blob/main/Sources/HolosSynthesis/AudioBookWriter.swift
- [ID] facebook/idb, `ChapterTrackMuxer.swift`: https://github.com/facebook/idb/blob/main/FBSimulatorVideo/ChapterTrackMuxer.swift
- [AF4] Apple Developer Forums, chapter titles missing with AVAssetWriter (2024): https://developer.apple.com/forums/thread/745696
- [ID3] ID3v2 Chapters 1.0 (Mutagen mirror): https://mutagen-specs.readthedocs.io/en/latest/id3/id3v2-chapters-1.0.html
- [OF] Overcast, Forecast: https://overcast.fm/forecast
- [JC] JSON Chapters format: https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/examples/chapters/jsonChapters.md
- [PSC] Podlove Simple Chapters: https://podlove.org/simple-chapters/
- [AH] Auphonic help, production (chapters): https://auphonic.com/help/web/production.html
- [AB] Auphonic blog, chapter marks and enhanced podcasts (2013): https://auphonic.com/blog/2013/07/03/chapter-marks-and-enhanced-podcasts/
- [AC] Apple, using chapters on Apple Podcasts: https://podcasters.apple.com/support/5482-using-chapters-on-apple-podcasts
