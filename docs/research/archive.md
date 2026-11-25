# Research: archive a session to FLAC

Date: 2026-11-04

Scope: reference behavior and platform facts for the FLAC archive feature. This file gives no release rule and no scope rule. A line that starts with "Inference:" has no owner source. A line that starts with "Unconfirmed:" names a claim that no primary source confirmed.

## Summary

- No reference DAW in this list has a documented "archive to FLAC and unarchive" command (F1 to F10).
- Reaper is the only DAW with documented FLAC project media. Its Save As can convert all media to FLAC into a new folder (F11 to F13).
- Logic Pro references Apple Lossless files in place (F7). Pro Tools lists no FLAC (F9).
- Audacity stores raw samples in SQLite and compacts by copy and rename (F14 to F16).
- Apple names FLAC since macOS 10.13 (F17). Encode, decode, MD5, and seek behavior are not documented (F18 to F20). The probe list is F21.
- FLAC has an MD5 of the PCM data, a seek table, and APPLICATION blocks for WAV chunks (F22 to F26).
- Seek without a table is a guided search. A table narrows it (F27, F28).

## 1. Hindenburg PRO

### F1. Hindenburg has no documented archive, compact, or compress command for a session

- The Hindenburg PRO guide index lists these session commands: New, Open, Save, Save As, Save as AES31, Import Session Into Session, and Properties. It lists no archive or compact command. Source: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- The release notes of version 2.05 (build 2724) say: "Added 'Delete unused files' option". The notes give no more detail. Source: https://hindenburg.com/support/release-notes/hindenburg-series/
- The Narrator guide lists "Tools - Session Cleanup: Cleanup your session". This is Narrator, not PRO. The text gives no detail. Source: https://hindenburg.com/academy/guides/guides-narrator/
- Unconfirmed: what "Delete unused files" and "Session Cleanup" do to the audio files. No Hindenburg manual text was reachable.

### F2. Hindenburg exports to FLAC, but no source says a session holds FLAC audio

- The PRO guide index lists FLAC, WAV, MP2, AAC, Apple Lossless, AIF, and OPUS only as export formats. Source: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- The index says "File - Export: Export your session as a mixed down file". Export makes a mixdown. It does not change the session audio. Same source.
- Unconfirmed: the audio file format of Hindenburg session files (WAV is likely). One third-party page says the default record format is WAV (https://kpfa.org/recording-using-hindenburg/). This is not a vendor source.
- Unconfirmed: whether Hindenburg opens a session whose audio files are FLAC.

### F3. Hindenburg Save As is the vendor method to move a session

- The vendor support article says: "The best way of moving a session is to use 'save as' from within Hindenburg. This way all the files and links are placed in the right folders." Source: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- The same article says the session file (.nhsx) and the session audio folder must stay together. The folder has the name of the session. Same source.
- Unconfirmed: that Save As copies only the files that the session uses. A search snippet of a 2014 support forum post says this. The post itself was not read.
- Unconfirmed: that Save As or any other command changes the audio file format.

## 2. Logic Pro

### F4. Logic Consolidate copies external assets into the project. It does not convert them

- Text: Consolidate copies assets "to the Media folder inside the project". This includes audio files. It ensures that the assets stay with the project "if you move or copy the project to another computer, or archive the project for later use".
- Menu path: File > Project Management > Consolidate. The dialog has one checkbox per asset type.
- The assets of any alternative of the project are also copied.
- Source: https://support.apple.com/guide/logicpro/consolidate-assets-in-a-project-lgcpce09b9d8/mac

### F5. Logic Save As and Save a Copy As copy assets. They have no format option

- File > Save As asks for "Package" or "Folder" and for the asset types to copy. Source: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
- File > Save a Copy As saves "copies of your recordings" and all saved assets. Apple text: "You can use the Save a Copy As option for archiving and moving data." Same source.
- File > Project Settings > Assets sets which asset types are copied when the project is saved. Source: https://support.apple.com/guide/logicpro/manage-project-assets-lgcpce0d70e7/mac
- The same page says that saving a project without assets "can save disk space", but the project then cannot reach the referenced files after a move.

### F6. Logic converts audio files only through Copy/Convert File in the Project Audio Browser

- The command is Audio File > Copy/Convert File. The dialog sets sample rate, bit depth, file format, stereo conversion, and dither type. Source: https://support.apple.com/guide/logicpro/move-copy-and-convert-audio-files-lgcp757ec334/mac
- A checkbox "Change file reference in Project Audio" replaces the file in the project with the copy. If it is off, both the copy and the original show in the Project Audio Browser. Same source.
- Unconfirmed: the list of file formats in the dialog. The page does not list them.

### F7. Logic supports Apple Lossless audio files and plays them in the project

- Apple lists these file formats: WAVE and AIFF (16, 24, 32 bit), CAF (integer and float PCM, A-law, u-law, AAC, ALAC), MP3 and AAC, Apple Lossless, QuickTime Audio. Source: https://support.apple.com/guide/logicpro/media-and-file-formats-overview-lgcp32add66e/mac
- Apple text: "Apple Lossless files contain compressed audio information... The sound of the compressed audio file is identical to the original recording." Same source.
- Apple says you can import AIFF, WAV, AAC, MP3, and Apple Lossless files as "compressed audio files". The region "points to" the compressed file. "You can edit this region in the same way as a normal audio region". Source: https://support.apple.com/guide/logicpro/import-compressed-audio-files-lgcp4f68cbe3/mac
- Result: Logic references ALAC and other compressed files in place. The page does not say Logic writes ALAC project audio on its own.
- Unconfirmed: a Logic command that converts a whole project to ALAC or to any compressed format. No source shows one.

## 3. Pro Tools

### F8. Pro Tools current guide: bit depth change does not touch existing files. Save Session Copy In sets rate and depth

- Avid text: a bit depth change "only applies to new recordings, renders, or commits. It does not alter the bit depth of existing audio files in the session". Source: https://www.avid.com/pro-tools/user-guide/change-sample-rate-bit-depth
- To change sample rate: File > Save Session Copy In, then choose the new sample rate and bit depth in the dialog. Same source.
- Avid warns that a session can hold files with mixed bit depth and sample rate. Same source.

### F9. Pro Tools current guide lists WAV, AIFF, and MP3 for import. FLAC is not listed

- Avid text: "Pro Tools supports common formats like WAV, AIFF, and MP3". The page lists "Other formats commonly used in audio production" without names. "Pro Tools can automatically convert it on import". Source: https://www.avid.com/pro-tools/user-guide/import-audio
- The Pro Tools | First 12.3 help (a cloud product, not full Pro Tools) says WAV or BWF (with WAV Extensible and RF64) imports without conversion. It says AAC, ACID, AIFF, MP3, QuickTime, REX, and Sound Resource files are "converted to 32-bit Float WAV on import". FLAC is not listed. Source: https://apps.avid.com/protoolsfirsthelp/version12.3/enu/Pro%20Tools%20First%20Help/sess7.import.17.07.html
- Unconfirmed: that a Pro Tools session can hold FLAC. No Avid page says so. The evidence is only that FLAC is absent from the Avid lists.

### F10. Pro Tools Save Copy In has an audio file type option and "Compact Selected" exists. No current Avid page was reachable

- Older Pro Tools 7.3 text (a manual mirror, not Avid hosted) sets "Audio File Type" to AIFF or BWF (.WAV) in Save Copy In. Source: https://manualshive.com/en/manual/digidesign/pro-tools/2497177?page=261
- The same family of manuals lists "Compact Selected" as a region command. It needs at least one audio track selected. Source: https://manualshive.com/en/manual/digidesign/pro-tools/2497177?page=846
- Unconfirmed in current Pro Tools: the exact options of Save Session Copy In (audio file type, "Convert To Specified Format", "Items to Copy") and the exact behavior of Compact Selected. Only third-party pages (Sweetwater, a university wiki, forum posts) describe them.
- Inference: a session copy converts only to a PCM type (BWF or AIFF). This is by analogy with the 7.3 text. The most common gesture (archive a session to a compressed type) is not covered.

## 4. Reaper

### F11. Reaper records to and imports FLAC. It also renders to FLAC

- Project Settings, Media: "Recording format - typically WAV or MP3, but there are others, e.g. AIFF, DDP, FLAC, OGG Vorbis Video (GIF) and WavPack." Each format has its own settings. Source: REAPER User Guide v7.84, Chapter on project settings. https://www.reaper.fm/userguide/ReaperUserGuide784c.pdf
- Import media file types include FLAC (.FLAC). The guide, section 4.8, lists them. Same source.
- Render to File: output formats include FLAC. "for FLAC encoding depth and data compression level". Same source (Render to File, "Primary/Secondary output format").
- The Batch File/Item Converter and the consolidate/glue dialog list FLAC among their output formats. Same source (sections 21 and 7).
- The guide says the Media Explorer can embed metadata in .FLAC files. Same source, section 4.4.

### F12. Reaper "Save project as" can copy and convert all media to FLAC

- Guide section 3.3: "Create subdirectory for project. If you also select Copy all media into project directory you may also specify a format for these items to be converted."
- Guide, example in chapter 3 (before section 3.44; the section number was not read): enable "Create subdirectory for project", "Copy all media into project directory", and "Convert media". Click Format, enable "Set format to save as", and choose FLAC, MP3, or Ogg Vorbis.
- Guide text: "All audio media items in the project will be converted to the specified format as they are copied across. The format of the original items will remain unchanged."
- Source: https://www.reaper.fm/userguide/ReaperUserGuide784c.pdf
- Result: Reaper converts into a new project folder. The original project stays unchanged. It does not convert in place.

### F13. Reaper keeps peak files next to the media. It has a clean command

- Reaper stores waveform data in "Vox.wav.reapeaks" and index data in "Vox.wav.reapindex" files. Source: https://www.reaper.fm/userguide/ReaperUserGuide784c.pdf (file types list)
- File > "Clean current project directory" removes unused media files from the project folder. Same source.
- Unconfirmed: whether Reaper plays and edits FLAC items "in place" without a decode cache. The guide says that FLAC is a record and import format. It does not say how Reaper seeks in FLAC.

## 5. Audacity

### F14. A .aup3 project is one SQLite database. Samples are uncompressed BLOBs

- Table `sampleblocks` has the columns blockid, sampleformat, summin, summax, sumrms, summary256 (BLOB), summary64k (BLOB), and samples (BLOB). The source comment says "Rows are immutable -- never updated after addition, but may be deleted." Source: au3/libraries/au3-project-file-io/ProjectFileIO.cpp, lines 161 to 189. https://github.com/audacity/audacity/blob/f51738cd5a7daa8c0c1012cf3ea44242f4b33ca2/au3/libraries/au3-project-file-io/ProjectFileIO.cpp
- `SqliteSampleBlock` binds the raw sample bytes with `sqlite3_bind_blob(stmt, 7, mSamples.get(), mSampleBytes, ...)`. The source has no call to a compressor on the samples. Source: au3/libraries/au3-project-file-io/SqliteSampleBlock.cpp, line 769. https://github.com/audacity/audacity/blob/f51738cd5a7daa8c0c1012cf3ea44242f4b33ca2/au3/libraries/au3-project-file-io/SqliteSampleBlock.cpp
- Manual text: the project is saved "in uncompressed, lossless quality in a database file with an aup3 extension". Source: https://manual.audacityteam.org/man/file_menu_save_project.html
- Manual text: a project is "a single database project file". The database also makes two temporary files, WAL and SHM. Source: https://manual.audacityteam.org/man/audacity_projects.html

### F15. Audacity compaction copies to a temp file, then renames. It keeps a backup until the swap works

- `ProjectFileIO::Compact` runs only if less than 81 percent of the stored blocks are in use, or if `force` is set (`ShouldCompact`, `current / total > 80` means no compaction).
- Steps: copy used blocks to `<name>_compact_temp`; close the connection; compare sizes; keep the new file only if it is smaller; flush to disk; rename the original to `<name>_compact_back`; rename the temp file to the original name; open the new file; delete the backup. If a rename or open fails, the code renames the files back.
- Source: ProjectFileIO.cpp, `ShouldCompact` (line 1281) and `Compact` (line 1602). https://github.com/audacity/audacity/blob/f51738cd5a7daa8c0c1012cf3ea44242f4b33ca2/au3/libraries/au3-project-file-io/ProjectFileIO.cpp
- The manual says undo audio is discarded when the project closes. Source: https://manual.audacityteam.org/man/audacity_projects.html

### F16. Audacity has no FLAC storage inside a project

- No source shows a compressed sample store in .aup3. Audacity exports FLAC as a separate command.
- Unconfirmed: the manual text for "Save Lossless Copy of Project" and "Save Compressed Copy of Project". The pages that were read do not cover them. A search snippet of the upgrade page names them.
- Unconfirmed: a user-facing "Compact project" menu command. The source runs compaction at save and close time.

## 6. Apple frameworks

SDK used: MacOSX26.2 SDK in Xcode on this Mac. Host: macOS 15.8.1 (build 24H32). Paths are under `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks`.

### F17. The SDK defines FLAC as a format ID and as a file type

- `kAudioFormatFLAC = 'flac'`. Header text: "Free Lossless Audio Codec, the flags indicate the bit depth of the source material." File: CoreAudioTypes.framework/Headers/CoreAudioBaseTypes.h, lines 384 and 431.
- `kAudioFileFLACType = 'flac'`. Header text: "Free Lossless Audio Codec". File: AudioToolbox.framework/Headers/AudioFile.h, lines 72 and 99.
- The headers carry no `API_AVAILABLE` tag for either name.
- Apple documentation for `kAudioFormatFLAC` says it was introduced in macOS 10.13, iOS 11.0, and watchOS 4.0. Source: https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac (JSON form: https://developer.apple.com/tutorials/data/documentation/coreaudiotypes/kaudioformatflac.json)
- Apple documentation for `kAudioFileFLACType` lists the platforms but gives no "introduced at" version. Source: https://developer.apple.com/tutorials/data/documentation/audiotoolbox/kaudiofileflactype.json
- The macOS 14 floor of Dirigible is above 10.13. A tag of 10.13 does not say that the encoder works. See F21.

### F18. The SDK header says nothing about FLAC encode versus decode

- No header says "FLAC encoder" or "FLAC decoder". The words "flags indicate the bit depth of the source material" are the only FLAC-specific rule.
- The Apple Lossless flags exist in the same header: `kAppleLosslessFormatFlag_16BitSourceData = 1`, `_20BitSourceData = 2`, `_24BitSourceData = 3`, `_32BitSourceData = 4`. File: CoreAudioBaseTypes.h, lines 509 to 547. The header ties these flags to ALAC only.
- Inference: the FLAC format flags use the same values as the ALAC flags. The header does not say so. The probe in F21 must check it.
- `kAudioConverterPropertyBitDepthHint` ('acbd') is "a hint to some encoders like lossless about how many bits to preserve in the input". A negative value means a float source. File: AudioToolbox.framework/Headers/AudioConverter.h, line 180.

### F19. AVFoundation: AVAudioFile reads as float by default. The file type key is 10.13 or later

- `AVAudioFile initForReading:error:` "opens the file for reading using the standard format (deinterleaved floating point)". File: AVFAudio.framework/Headers/AVAudioFile.h, lines 32 to 41.
- `initForReading:commonFormat:interleaved:error:` selects the processing format. The `AVAudioCommonFormat` values are Float32, Float64, Int16, and Int32. There is no 24-bit packed choice. File: AVAudioFile.h line 54 and AVAudioFormat.h lines 18 to 36.
- `initForWriting:settings:error:` takes the settings dictionary of `AVAudioRecorder`. "The file type to create can be set through the corresponding settings key. If not set, it will be inferred from the file extension." File: AVAudioFile.h, lines 56 to 72.
- `AVAudioFileTypeKey` is available from macOS 10.13. Its value is "an integer (audio file type) from AudioFile.h". `AVEncoderBitDepthHintKey` takes "an integer from 8 to 32". `AVLinearPCMBitDepthKey` takes 8, 16, 24, or 32. File: AVFAudio.framework/Headers/AVAudioSettings.h, lines 22, 25, and 40.
- Unconfirmed: that `AVAudioFile` can write FLAC with `AVFormatIDKey = kAudioFormatFLAC`. No Apple page says so.
- Unconfirmed: whether the 24-bit decode of FLAC gives 24-bit integer or float. The file format of a FLAC file is a compressed format. The client data format decides the PCM type. See F21.

### F20. The afconvert help on this Mac lists FLAC as a data format

- `afconvert -hf` (a help listing, not a conversion) on macOS 15.8.1 shows `'flac' = FLAC (.flac)` with data format `'flac'`. It shows `'flac'` as a data format in the CAF list and in the M4A list. It shows `'Oggf'` with `'flac'`, `'opus'`, and `'vorb'`.
- The listing does not say whether each entry is decode only or decode and encode.
- Source: tool output on this Mac, `afconvert -hf`, 2026-11-04.

### F21. What the afconvert probe must check (the lead runs it)

Use a 16-bit file, a 24-bit file, a 32-bit float file, mono, stereo, and one long file (at least 30 minutes, 48 kHz, stereo, 24-bit). Use real speech, not silence.

1. Encode: `afconvert -f flac -d flac <src.wav> <out.flac>`. Does it succeed for 16 bit, for 24 bit, and for float input? Record the exit code and the stderr text.
2. Output bit depth: read the STREAMINFO of `<out.flac>`. Is "bits per sample" 16 for a 16-bit source? Is it 24 for a 24-bit source? What does a float source give?
3. Format flags: run `afinfo <out.flac>` and read the ASBD `mFormatFlags` of the file. Does it use the ALAC values 1 to 4? Run the same check through `ExtAudioFileGetProperty(kExtAudioFileProperty_FileDataFormat)`.
4. Decode: `afconvert -f WAVE -d LEI24 <out.flac> <back.wav>`. Is `back.wav` bit exact to `src.wav` (use `cmp` on the PCM data or `afinfo`+hash)? Repeat with `-d LEI16`, `-d LEF32`, and `-d BEI24`.
5. Native decode type: open `<out.flac>` with `ExtAudioFile` and read `kExtAudioFileProperty_FileDataFormat` and the default client format. Open the same file with `AVAudioFile` and read `fileFormat` and `processingFormat`. What PCM type does a 24-bit FLAC give (Int32 aligned high, packed 24, or Float32)? Is the decode of float output equal to the integer source after rounding?
6. 32-bit float input: does the encoder accept it, or does it return an error? Does it convert to 24 bit? This tells whether the archive can hold a float session file.
7. AVAudioFile write: `AVAudioFile(forWriting:settings:)` with `AVFormatIDKey = kAudioFormatFLAC`, with and without `AVAudioFileTypeKey`. Does it work? Does it write a bit exact file?
8. AudioFile API: `AudioFileCreateWithURL` with `kAudioFileFLACType`, and `AudioFileOpenURL` on a FLAC file. Are `kAudioFilePropertyAudioDataPacketCount` and `kAudioFilePropertyPacketTableInfo` valid? What is the packet size? Does `AudioFileReadPacketData` at a random packet work?
9. Sample count: is the frame count of the FLAC (STREAMINFO total samples) equal to the source frame count to the last sample? Check lengths that are not a multiple of the block size.
10. Channels and rate: 1 and 2 channels, 44.1 and 48 kHz. Do 3 or more channels work?
11. MD5: does the encoder write a nonzero MD5 in STREAMINFO? Compare it to `md5` of the PCM data (little endian, interleaved, signed, F22). Then change one MD5 byte in a copy and decode it. Does the decoder report an error (F23 explains why this matters)?
12. Corruption: flip one byte in the middle of an audio frame in a copy. Does the decode fail at the frame (CRC), skip it, or output silence? Does `afconvert` exit with a non-zero code?
13. Truncation: cut the last 1 KB of a copy. Does the decode report an error? Does the frame count change?
14. Seek table: does the Apple encoder write a SEEKTABLE block? Read the metadata blocks from the file header. How many points? Does it write a PADDING block?
15. Seek speed: open the long file with `ExtAudioFile` and `AVAudioFile`. Time 100 random seeks and reads of 4096 frames. Do this for a FLAC with the Apple seek table and, if the lead has the reference `flac` tool, for a copy without a seek table (`flac --no-seektable`). Also time the same seeks on the WAV source. Report the median and the 99th percentile.
16. Reference tool interop: decode the Apple file with the reference `flac -t` (if installed) and the reverse (a file from `flac` read by `afconvert`). Does Apple read a file from `flac --keep-foreign-metadata`? Does it ignore the APPLICATION blocks?
17. Metadata: does Apple keep or drop Vorbis comments, APPLICATION blocks, and a PADDING block when it re-encodes?
18. Disk size: record the size ratio of FLAC to WAV for real speech at 24 bit and at 16 bit.
19. Write time: time the encode of the long file. Check that the encode can run in a background task and write to a temporary name.
20. Partial output: stop an encode half way (kill the process). Does a partial file stay at the output path? Is that file readable as FLAC? The result shows if the archive code needs a temporary name and a rename.

## 7. FLAC format

### F22. FLAC STREAMINFO has an MD5 of the unencoded samples. A decoder can check it

- Text, RFC 9639 section 8.2: the message to the MD5 algorithm "consists of all the samples of all channels interleaved". Samples are signed and little endian. The value 0 means "not known". The checksum "allows the decoder to determine if an error exists in the audio data". Source: https://www.rfc-editor.org/rfc/rfc9639.html (section 8.2, Table 3)
- The RFC does not say that a decoder must verify the MD5.
- The libFLAC header says the stream decoder "provides MD5 signature checking". Checking is off by default until the client turns it on. "MD5 checking is automatically turned off ... if there is no signature in the STREAMINFO block or when a seek is attempted." Source: https://github.com/xiph/flac/blob/59fa3402cb19b6b7c85b916f138cfb03c7b27504/include/FLAC/stream_decoder.h (about lines 148 to 160)
- The reference `flac` tool, in decode and test mode (`-t`), reports an error "when the MD5 signature of the decoded audio does not match the stored MD5 signature". Source: https://xiph.org/flac/documentation_tools_flac.html
- The `flac` encoder option `--verify` "decodes the output in parallel and compares to the original". Same source.

### F23. No source says that the Apple decoders check the MD5

- Unconfirmed: that AudioToolbox or AVFoundation checks the STREAMINFO MD5. No Apple page or header says so. See F21 item 11 for the probe.
- Inference: a FLAC frame has an 8-bit header CRC and a 16-bit footer CRC (RFC 9639 section 9.1.8 gives the header CRC). A decoder may stop on a CRC failure (section 5, "MAY stop decoding"). The Apple behavior on a CRC failure is also unconfirmed. See F21 item 12.
- Inference: to prove a lossless archive, the app must compare its own hash of the decoded PCM with a hash of the source PCM. It cannot rely on the Apple decoder to check the stored MD5.

### F24. FLAC limits for bit depth, rate, channels, and block size

- Bits per sample: 4 to 32. Sample rate: 1 to 1048575 Hz. Channels: 1 to 8. Source: https://www.rfc-editor.org/rfc/rfc9639.html (sections 1 and 8.2)
- Block size: the minimum and maximum block size in STREAMINFO "MUST be in the 16-65535 range". The streamable subset allows at most 16384 samples per block (4608 at 48 kHz or less). Source: same page, sections 8.2 and 7.
- STREAMINFO stores total samples. The value 0 means unknown. Source: same page, section 8.2.
- Result: FLAC holds integer samples only (4 to 32 bit). The RFC defines no float sample type. Unconfirmed: what an Apple encoder does with float input (F21 item 6).

### F25. SEEKTABLE: format and effect

- Each seek point is 18 bytes: sample number of the first sample of the target frame (64 bit), byte offset from the first frame header (64 bit), and number of samples in the frame (16 bit). Source: https://www.rfc-editor.org/rfc/rfc9639.html (section 8.5, Table 7)
- Placeholder points have sample number 0xFFFFFFFFFFFFFFFF. They "MUST all occur at the end of the table". Points are sorted by sample number and are unique. Only one SEEKTABLE is allowed. Same source, section 8.5.1.
- Text: "By adding seek points to a stream, this delay can be significantly reduced." And: "It is possible to seek to any given sample in a FLAC stream without a seek table, but the delay can be unpredictable." Same source, section 8.5.
- The reference encoder adds one seek point every ten seconds by default. Source: https://xiph.org/flac/documentation_tools_flac.html (option `--seekpoint`). The page text is ambiguous (its example reads "-s 10s"). Treat the default as documented but check it in the probe.
- The `flac` option `--no-seektable` writes no seek table. Same source.

### F26. FLAC can hold WAV chunks in APPLICATION blocks

- IANA registers these APPLICATION IDs: `riff` (0x72696666, "FLAC RIFF chunk storage"), `aiff` (0x61696666), and `w64 ` (0x77363420). Source: https://www.iana.org/assignments/flac/flac.xhtml and RFC 9639 section 12.2.
- The foreign metadata document says: for WAVE and RF64 files the ID is `riff`. "All chunks are copied completely, except for the first chunk (which contains all others) and the chunk containing the audio, of which only the headers (identifier and size) are copied. It is important for proper restoration that the order of the chunks is retained." Source: https://github.com/xiph/flac/blob/59fa3402cb19b6b7c85b916f138cfb03c7b27504/doc/foreign_metadata_storage.md
- Example in that document: a simple WAVE file gives 4 `riff` blocks (RIFF header, "WAVE", full `fmt ` chunk, `data` chunk header).
- The `flac` option `--keep-foreign-metadata` saves the non-audio chunks on encode and restores them on decode. Input and output must be regular files. It "will exit with error if no such chunks are found". `--keep-foreign-metadata-if-present` warns instead. Chunks cannot be converted between formats. Source: https://xiph.org/flac/documentation_tools_flac.html
- The RFC text itself only registers the ID. The storage rules are in the foreign metadata document, which is an informal document of the flac project (a 2021 flac-dev thread says so: https://lists.xiph.org/pipermail/flac-dev/2021-August/006500.html).
- Unconfirmed: whether the Apple encoder or decoder reads or writes `riff` blocks. See F21 item 16.
- Unconfirmed: whether the project WAV files carry chunks that Dirigible needs (for example `bext`, `iXML`, `cue `). That is a repo fact, not a research fact.

## 8. FLAC seek speed

### F27. Why a seek without a SEEKTABLE costs more

- Each FLAC frame header holds the sample number (variable block size) or the frame number (fixed block size). This allows "fast, sample-accurate seeking" without a table. Source: https://www.rfc-editor.org/rfc/rfc9639.html (section 6). The coded number must match the frame count. "In a stream where these requirements are not met, seeking is not (reliably) possible" (section 9.1.5).
- The stream has no index of frame sizes. Frames have variable byte size. A decoder must guess a byte position, find a frame sync code, and read the frame number.
- The libFLAC seek routine `seek_to_absolute_sample_` does this. It starts with bounds from the first frame offset and the stream length. It estimates a byte position by linear interpolation between the bounds: `pos = lower_bound + (target - lower_sample) / (upper_sample - lower_sample) * (upper_bound - lower_bound) - approx_bytes_per_frame`. It seeks the file, flushes, and decodes one frame. It repeats with new bounds until the target frame is found. The Ogg variant switches to a binary search after 2 proportional iterations and to a linear search when the current sample is within `FLAC__MAX_BLOCK_SIZE * 2` of the target. Source: https://github.com/xiph/flac/blob/59fa3402cb19b6b7c85b916f138cfb03c7b27504/src/libFLAC/stream_decoder.c (lines 3647 to 3830 and the Ogg variant near line 3905).
- Each probe step costs one file seek and one frame decode. The number of steps depends on the stream. This matches the RFC word "unpredictable".

### F28. A SEEKTABLE narrows the search bounds

- When a seek table exists, libFLAC refines the lower and upper bound with the nearest seek point at or below the target and the nearest above it. It ignores placeholder points and points with `frame_samples == 0` or a sample number past the end. Source: stream_decoder.c lines 3710 to 3760, same URL as F27.
- If a point is at or below the target, the decoder starts its search at that point. With a point every N samples, the decoder has to decode at most about N samples of audio (plus the frame) to reach the target, plus one file seek.
- The table is optional. A table with a point every ten seconds (F25) bounds the decode to about ten seconds of audio. A table with a point every second bounds it to one second.
- Inference: no primary source gives a measured time per seek for any N. The relation between N and seek time is by reading the algorithm. The probe in F21 item 15 must measure it on Apple code.
- RFC 9639 section 8.5 says a seek table is "generally not usable for seeking in a FLAC file embedded in a container". Offsets "MUST NOT be updated on muxing" (section 8.5.1). A FLAC in an MP4 or CAF container uses the container packet table, not the SEEKTABLE.

## 9. Lead probe: afconvert round trip on the tester corpus

### F29. The AudioToolbox FLAC codec round trip is sample-equal on every corpus clip

The lead ran `probe-flac/roundtrip.sh` in the probe sandbox on macOS 15.8.1 (24H32). It found 61 `Clips/` WAVs in the three tester packages. Each is RIFF, 2 channels, 48 kHz, 24-bit integer (format tag 1), with the chunks `JUNK`, `fmt `, `FLLR`, `data`. For each file: `afconvert -f flac -d flac/3`, then `afconvert -f WAVE -d LEI24`, then a compare of the `data` bytes.

- 61 of 61 files are sample-equal after the round trip. A copy with one flipped data byte gives `DIFF data byte 1000`, exit 1: the grader detects a change.
- The FLAC files have the blocks STREAMINFO and VORBIS_COMMENT only. There is no SEEKTABLE and no APPLICATION block. The block size is 4608. The STREAMINFO depth is 24 bits.
- The STREAMINFO MD5 of each file equals the MD5 of the `data` bytes of its source WAV (61 of 61).
- The decoded WAV has the format tag 65534 (extensible), no `JUNK` chunk, and an `FLLR` chunk. So the afconvert WAV writer does not give back the source header. The samples are equal.
- With no format flag, the encoder wrote 24 bits (STREAMINFO read), and the round trip stayed equal. With the 16-bit flag `/1`, the round trip stayed sample-equal; the probe did not read the depth of that file. Inference: afconvert takes the FLAC depth from the source, so the flag does not set the depth in this path.
- Sizes: 3,659,204,884 WAV bytes give 1,778,629,176 FLAC bytes (ratio 0.486). Per package (1 to 3): 0.231, 0.472, 0.537. The largest file is 1,158,377,692 WAV bytes (598,279,203 FLAC bytes).
- The probe measured no time: a probe that times something takes the build lock (`scripts/probe.sh` header), and this run takes no lock.

Source: `probe-flac/roundtrip-output.txt`, `probe-flac/roundtrip.sh`, `probe-flac/flacprobe.py` in the run folder.

## Open questions for the plan

1. Does the Apple encoder write a SEEKTABLE, and how many points? (F21 item 14)
2. Does the Apple decoder check the MD5 or the frame CRCs? (F21 items 11, 12)
3. Does the 24-bit FLAC decode give integer or float? Is the 24-bit round trip bit exact? (F21 items 4, 5)
4. Does the encoder accept 32-bit float PCM? (F21 item 6)
5. Does Apple seek in FLAC files fast enough for editing? Compare with WAV. (F21 item 15)
6. Which non-audio WAV chunks do Dirigible sessions need to keep? (repo fact)
7. Which DAW commands would a tester expect? Only Reaper has a documented FLAC convert on Save As (F12). Logic and Pro Tools have no documented lossy or lossless compress step.

## Claims with no primary source

- Hindenburg: the audio file format of session files, the result of "Delete unused files" and "Session Cleanup", whether Save As copies only used files, and whether Hindenburg opens FLAC session audio (F1 to F3).
- Logic Pro: the list of file formats in Copy/Convert File, and any whole project convert to ALAC (F6, F7).
- Pro Tools: the current options of Save Session Copy In and Compact Selected, and FLAC in a session (F9, F10).
- Reaper: how Reaper seeks in FLAC items and whether it decodes to a cache (F13).
- Audacity: the manual text of "Save Lossless Copy of Project" and "Save Compressed Copy of Project", and a user-facing Compact command (F16).
- Apple: the macOS version when the AudioFile and AVAudioFile FLAC encoder works, encode of float input, 24-bit decode type, MD5 check, CRC behavior, SEEKTABLE written, and `riff` block handling (F17 to F20, F23).
- FLAC: a measured seek time for any seek point spacing (F28).

## Sources

- Hindenburg PRO guide index: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- Hindenburg Narrator guide index: https://hindenburg.com/academy/guides/guides-narrator/
- Hindenburg release notes: https://hindenburg.com/support/release-notes/hindenburg-series/
- Hindenburg support article on missing audio files: https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- Logic Pro, Consolidate project assets: https://support.apple.com/guide/logicpro/consolidate-assets-in-a-project-lgcpce09b9d8/mac
- Logic Pro, Save projects: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
- Logic Pro, Manage project assets: https://support.apple.com/guide/logicpro/manage-project-assets-lgcpce0d70e7/mac
- Logic Pro, Move, copy, and convert audio files: https://support.apple.com/guide/logicpro/move-copy-and-convert-audio-files-lgcp757ec334/mac
- Logic Pro, Media and file formats: https://support.apple.com/guide/logicpro/media-and-file-formats-overview-lgcp32add66e/mac
- Logic Pro, Import compressed audio files: https://support.apple.com/guide/logicpro/import-compressed-audio-files-lgcp4f68cbe3/mac
- Avid, Changing sample rate and bit depth: https://www.avid.com/pro-tools/user-guide/change-sample-rate-bit-depth
- Avid, Importing audio: https://www.avid.com/pro-tools/user-guide/import-audio
- Avid, Pro Tools | First 12.3 supported audio file formats: https://apps.avid.com/protoolsfirsthelp/version12.3/enu/Pro%20Tools%20First%20Help/sess7.import.17.07.html
- Pro Tools Reference Guide (older version, third-party mirror): https://manualshive.com/en/manual/digidesign/pro-tools/2497177?page=261 and https://manualshive.com/en/manual/digidesign/pro-tools/2497177?page=846
- REAPER User Guide v7.84: https://www.reaper.fm/userguide/ReaperUserGuide784c.pdf (index page: https://www.reaper.fm/userguide.php)
- Audacity manual, Save Project: https://manual.audacityteam.org/man/file_menu_save_project.html
- Audacity manual, Audacity projects: https://manual.audacityteam.org/man/audacity_projects.html
- Audacity source, ProjectFileIO.cpp: https://github.com/audacity/audacity/blob/f51738cd5a7daa8c0c1012cf3ea44242f4b33ca2/au3/libraries/au3-project-file-io/ProjectFileIO.cpp
- Audacity source, SqliteSampleBlock.cpp: https://github.com/audacity/audacity/blob/f51738cd5a7daa8c0c1012cf3ea44242f4b33ca2/au3/libraries/au3-project-file-io/SqliteSampleBlock.cpp
- Apple SDK headers on this Mac: CoreAudioTypes.framework/Headers/CoreAudioBaseTypes.h, AudioToolbox.framework/Headers/AudioFile.h, AudioToolbox.framework/Headers/AudioConverter.h, AVFAudio.framework/Headers/AVAudioFile.h, AVAudioFormat.h, AVAudioSettings.h (MacOSX26.2 SDK)
- Apple developer documentation, kAudioFormatFLAC: https://developer.apple.com/documentation/coreaudiotypes/kaudioformatflac
- Apple developer documentation data, kAudioFileFLACType: https://developer.apple.com/tutorials/data/documentation/audiotoolbox/kaudiofileflactype.json
- RFC 9639, Free Lossless Audio Codec (FLAC): https://www.rfc-editor.org/rfc/rfc9639.html
- IANA FLAC Application Metadata Block IDs: https://www.iana.org/assignments/flac/flac.xhtml
- xiph.org flac tool documentation: https://xiph.org/flac/documentation_tools_flac.html
- xiph flac source, stream_decoder.c: https://github.com/xiph/flac/blob/59fa3402cb19b6b7c85b916f138cfb03c7b27504/src/libFLAC/stream_decoder.c
- xiph flac source, stream_decoder.h: https://github.com/xiph/flac/blob/59fa3402cb19b6b7c85b916f138cfb03c7b27504/include/FLAC/stream_decoder.h
- xiph flac, foreign metadata storage: https://github.com/xiph/flac/blob/59fa3402cb19b6b7c85b916f138cfb03c7b27504/doc/foreign_metadata_storage.md
- flac-dev list, 2021-08, on foreign metadata documentation: https://lists.xiph.org/pipermail/flac-dev/2021-August/006500.html
