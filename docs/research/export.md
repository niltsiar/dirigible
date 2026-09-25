# Export of the mix

Date: 2026-09-25

## Scope

This document answers the questions of the export run: the Hindenburg export flow, the mono downmix, AAC in AudioToolbox, sample-rate conversion on write, float to integer conversion, the save panel, `renamex_np`, and a full disk. `docs/research/export-and-dsp.md` already covers the encoders in AudioToolbox, FLAC, the Apple Podcasts bit rates, and loudness. This document does not repeat that content [EDSP].

Sources are the macOS 26 SDK headers on the development Mac (`xcrun --show-sdk-path`), the man pages, Apple documentation, the Hindenburg guides, and ITU-R BS.775-4. Each claim has a bracket tag. The Sources section defines each tag. The mark "(unconfirmed)" means that this research did not confirm the claim in a primary source. The mark "(tested)" means a local test on macOS 15.7.9, Intel x86_64, Xcode 26, on 2026-09-25 [T]. The test programs are in the session scratchpad and are not in git. The mark "(computed)" means arithmetic from the stated facts.

## 1. Hindenburg export

### Menu items and keys

- File > Export (⌘E) exports the session as one mixed-down file [HJ] [HPG]. The Journalist 1.21 guide calls it "Fast export" [HJ].
- File > Export Selection (⇧⌘E) exports the current selection only [HJ] [HPG]. The guide says: "Select the duration and number of tracks to be exported. Only the selected will be exported. To export a selection on all tracks, use ⌘A" [HJ]. A selection is thus a time range and a set of tracks.
- Other export commands: Chapters > Export Selection exports the selected chapters as individual files. Clipboards > Export Selection exports a clipboard clip [HPS] [HPG].
- File > Publish (Ctrl U on Windows) uploads to a podcast host. The host setup has "Audio export options: File Format, File Encoding, Loudness Normalization, Username, and Password" [HPS] [HPG]. The Mac key for Publish is not confirmed (unconfirmed).
- File > Save As > AES31 and File > Save As > AAF export the session, not a mix [HPS].
- Hindenburg Narrator has the same File > Export and File > Export Selection, plus book export presets for ACX and Findaway [HNG].

### Export options

- Formats in the export dialog: WAV, MP3, MP2 (`.wav` or `.mp2`), AAC (`.m4a`), Apple Lossless (`.m4a`), AIFF, FLAC, OPUS [HPS] [HPG].
- The Journalist 1.21 guide shows one options page per format ("Export / options"). Each format has named presets ("Encoding"). The user can add, rename, delete, and reset presets, and set one preset as the default for the format [HJ].
- Channels: Stereo or Mono for every format. MP3 also has Joint Stereo [HJ].
- Sample rate: "No conversion - follows session", 32000 Hz, 44100 Hz, or 48000 Hz for every format [HJ].
- MP3 bit rate: 32 to 320 kbit/s. AAC bit rate: 32 to 320 kbit/s, AAC-LC or AAC-HE, "Up to 40/80 kbps for mono/stereo" for HE. MP2: 128 to 384 kbit/s [HJ].
- Default AAC and MP3 presets: High Quality 192 kbit/s stereo, Medium Quality 128 kbit/s stereo, Low Quality 64 kbit/s mono [HJ].
- Bit depth: the Journalist 1.21 WAV and AIFF pages show no bit depth control. The guide says "all sessions are 16 bit" [HJ]. A 2025 Hindenburg article recommends "WAV, 24-bit, 48 kHz, stereo" for an archive copy [HD23]. Thus the current PRO version probably offers 24-bit export (unconfirmed).
- BWF: a WAV option adds a Broadcast Wave header with metadata [HJ].
- Loudness: the PRO export has a loudness normalization target [PVC1]. The presets were -24, -23, and -16 LUFS, and in 2018 Hindenburg added -14 and -18 LUFS [PVC2]. `export-and-dsp.md` section 4 lists the current presets [EDSP]. The standard (not PRO) Journalist had normalization only through Publish [PVC1].
- Mono loudness: a Buzzsprout review says that Hindenburg PRO detects a mono or stereo export and takes a mono export down 3 dB [BUZZ]. Hindenburg does not document this (unconfirmed).

### Progress, missing files, and range

- Progress bar and cancel button: no source describes them for export (unconfirmed). The Journalist guide shows a progress bar only for a transfer from the iPhone app [HJ].
- Missing files: when the session folder and the session file are apart, Hindenburg asks the user to "locate missing audio files" when it opens the session [HMISS]. No source describes an export with a missing file (unconfirmed).
- Timeline range: no source says whether File > Export starts at time 0 or at the first clip, or where it stops (unconfirmed). Export Selection uses the selection range [HJ].

## 2. Mono downmix

### Laws (computed)

For two channels L and R, the three common laws give these levels relative to one input channel:

| Law | Gain | Identical L and R (correlated) | Independent L and R at equal level (uncorrelated) |
|---|---|---|---|
| Average, 0.5 × (L + R) | -6 dB per channel | 0 dB | -3 dB |
| Equal power, 0.7071 × (L + R) | -3 dB per channel | +3 dB | 0 dB |
| Sum, L + R | 0 dB | +6 dB | +3 dB |

- Out-of-phase content cancels with every law. Hindenburg support says that a mono export of an out-of-phase stereo file is almost silent because "the left and right channel are mixed together" [HMONO]. Hindenburg thus sums the two channels for a mono export. The gain that it uses is not documented (unconfirmed).
- A mono voice clip on a center pan has L = R, so the average law keeps its level (computed).

### ITU-R BS.775-4

- Annex 4, Table 2 gives "Downward mixing equations for 3/2 source material" only [BS775].
- For the mono (1/0) format the coefficients are L 0.7071, R 0.7071, C 1.0000, LS 0.5000, RS 0.5000 [BS775].
- BS.775 has no separate equation for a 2/0 source. With C, LS, and RS at zero, Table 2 gives M = 0.7071 × (L + R) (computed).
- The standard adds: "the overall effect of such downward mixing equations ... will depend on other factors, such as the panning equations and microphone characteristics" [BS775].

### Apple AudioConverter and AVAudioConverter

- `kAudioConverterChannelMap`: "When I > O, the first O inputs are routed to the first O outputs, and the remaining puts discarded" [ACH].
- Default 2 to 1 conversion (tested): L = 0.4, R = 0.2 gives 0.4. The converter keeps L and discards R. It does not mix.
- `kAudioConverterPropertyPerformDownmix`: "1 meaning to perform a mix from input to output channels ... Defaults to 0 (no channel mixing)" [ACH]. It is not compatible with `kAudioConverterChannelMap` [ACH].
- With `PerformDownmix = 1` (tested): L = 0.4, R = 0.2 gives 0.3. The default mix map reads back as `[0.5, 0.5]`. This is the average law.
- `kAudioConverterPropertyChannelMixMap` is a row-major array of gains "from 0.0 to 1.0" [ACH]. The converter normalizes each map so that the gains of an output sum to 1 (tested): `[0.707, 0.707]`, `[0.4, 0.4]`, and `[0.9, 0.9]` all read back as `[0.5, 0.5]`. `[0.3, 0.6]` reads back as `[0.333, 0.667]`. Thus the mix map cannot give the equal-power law or the sum law.
- `PerformDownmix` and `ChannelMixMap` are in the macOS 26 SDK. They are not in the macOS 15.5 SDK header [SDKH]. The properties work on the macOS 15.7 runtime (tested). Their behavior on macOS 14 is not tested (unconfirmed).
- 1 to 2 conversion copies the mono channel to both outputs at the same level (tested): 0.4 gives `[0.4, 0.4]`.
- `AVAudioConverter.downmix`: "If YES and channel remapping is necessary, then channels will be mixed as appropriate instead of remapped. Default value is NO" [AVC].
- `AVAudioEnvironmentNode` is a 3D spatial mixer. This research did not examine it for a file export, because it is not a downmix API.

## 3. AAC in AudioToolbox

### Bit rates (tested)

`kAudioConverterApplicableEncodeBitRates` on an AAC-LC encoder from 32-bit float PCM gives these values in bit/s. The values are the same at 44.1 kHz and 48 kHz:

| Channels | Applicable bit rates | Default |
|---|---|---|
| Mono | 32000 40000 48000 56000 64000 72000 80000 96000 112000 128000 144000 160000 192000 224000 256000 | 64000 |
| Stereo | 64000 72000 80000 96000 112000 128000 144000 160000 192000 224000 256000 288000 320000 | 128000 |

- `kAudioCodecPropertyApplicableBitRateRange` is "An array of AudioValueRange indicating the target bit rates supported by the encoder in its current configuration" [ACD].
- The Apple Podcasts ranges in `export-and-dsp.md` (64–128 kbit/s mono, 128–256 kbit/s stereo) are all in these lists [EDSP].
- `AVEncoderBitRateKey` and `AVEncoderBitRatePerChannelKey` set the rate. "only one of AVEncoderBitRateKey and AVEncoderBitRatePerChannelKey should be provided" [AVS].
- A 1 s sine at 48 kHz mono and 96 kbit/s gave 56548 bit/s in the file (tested). The encoder uses fewer bits for a simple signal in its default mode.

### Bit rate strategy

- `AVEncoderBitRateStrategyKey` takes `AVAudioBitRateStrategy_Constant`, `_LongTermAverage`, `_VariableConstrained`, or `_Variable` (macOS 10.9) [AVS].
- These map to `kAudioCodecBitRateControlMode_Constant` (0), `_LongTermAverage` (1), `_VariableConstrained` (2), and `_Variable` (3) [ACD].
- The default mode of the AAC encoder is 1, long-term average (tested). "The provided target bit rate is achieved over a long term average (typically after the first 1000 packets)" [ACD].
- `AVEncoderAudioQualityForVBRKey` is "only relevant for AVAudioBitRateStrategy_Variable" [AVS].

### Priming and exact length

- `kAudioConverterPrimeInfo` on the AAC encoder gives 2112 leading frames and 0 trailing frames at 44.1 and 48 kHz, mono and stereo (tested).
- TN2258: "the priming value is currently fixed at 2112 samples and the remainder will always be less than 1024 samples" [TN2258].
- TN2258: "only the Core Audio File Format (.caf) and MPEG-4 Audio (.m4a) containers have a described means to carry this information" [TN2258].
- `AVAudioFile` writes the values into the `.m4a` as an `iTunSMPB` metadata atom (tested). For 48000 frames the atom text is `00000000 00000840 00000040 000000000000BB80`: 0x840 = 2112 priming, 0x40 = 64 remainder, 0xBB80 = 48000 valid frames. The file has no `elst` edit list atom (tested).
- `AudioFile` reads the values back as `kAudioFilePropertyPacketTableInfo`: "mNumberValidFrames ... minus mPrimingFrames, minus mRemainderFrames" [AF]. `afinfo` prints "48000 valid frames + 2112 priming + 64 remainder = 50176" (tested).
- "With ExtAudioFile, priming and remainder values are read from the file (if present) and those samples are removed from the decoded bitstream automatically" [TN2258]. `AVAudioFile(forReading:)` gave `length` = 48000, 48001, and 100000 for files of 48000, 48001, and 100000 frames (tested).

## 4. Sample-rate conversion on write

### ExtAudioFile

- `ExtAudioFileWrite`: "If the file has a client data format, then the audio data in ioData is translated from the client format to the file data format, via the ExtAudioFile's internal AudioConverter" [EAF].
- The header describes the converter as able to do "sample rate conversion" between two PCM formats [ACH].
- A 44.1 kHz 16-bit WAV file with a 48 kHz float client format received 48000 client frames. The file has 44100 frames at 44100 Hz (tested).
- `kExtAudioFileProperty_AudioConverter` gives the "underlying AudioConverterRef, if any. Read-only" [EAF]. After a change of a converter property, "you must set the kExtAudioFileProperty_ConverterConfig property on the ExtAudioFileRef afterwards. A NULL configuration is sufficient" [EAF].
- The converter exists after `kExtAudioFileProperty_ClientDataFormat` is set (tested).

### Converter quality

- `kAudioConverterSampleRateConverterComplexity`: "An OSType that specifies the sample rate converter algorithm". Values: `_Linear` ('line'), `_Normal` ('norm', "the default"), `_Mastering` ('bats', "higher quality range, more expensive"), `_MinimumPhase` ('minp') [ACH].
- `kAudioConverterSampleRateConverterQuality`: `kAudioConverterQuality_Max` 0x7F, `_High` 0x60, `_Medium` 0x40, `_Low` 0x20, `_Min` 0 [ACH].
- For `_MinimumPhase` the header gives noise floors: Low -96 dB, Medium -144 dB, High or Max -160 dB [ACH].
- On the ExtAudioFile converter, `Complexity = Mastering`, `Quality = Max`, and a NULL `ConverterConfig` all return noErr. The complexity reads back as 'bats' (tested).
- `AVSampleRateConverterAlgorithmKey` (`_Normal`, `_Mastering`, `_MinimumPhase`) and `AVSampleRateConverterAudioQualityKey` are the AVFAudio names [AVS]. `AVAudioConverter` has `sampleRateConverterQuality` and `sampleRateConverterAlgorithm` [AVC].

### AVAudioFile

- `initForWriting:settings:commonFormat:interleaved:error:` takes "the processing format to use when writing to the file" as a common format (float32, int16, and so on), not as a full `AVAudioFormat` [AVF]. The processing sample rate is the file sample rate (tested: file 44100 Hz, processing format 44100 Hz).
- `writeFromBuffer:error:` says: "Its format must match the file's processing format" [AVF].
- A 48 kHz buffer of 48000 frames written to the 44.1 kHz file returned no error. The file length became 48000 frames at 44100 Hz (tested). `AVAudioFile` did not resample and did not refuse the buffer. The audio thus plays slower and lower in pitch.

## 5. Float to integer PCM in AudioConverter

### Clip or wrap (tested)

- Float32 to Int16: 1.5 gives 32767. -1.5 gives -32768. 1.0 gives 32767. -1.0 gives -32768. 1e9 / 32768 gives 32767. The converter clips. It does not wrap.
- Float32 to Int24: 1.5 gives 0x7FFFFF and -1.5 gives 0x800000. The converter clips.
- NaN gives -32768.
- The header lists the supported PCM formats but does not describe clipping or rounding [ACH].

### Round or truncate (tested)

Values in units of one 16-bit step:

| Input | 0.5 | 1.5 | 2.4 | 2.5 | 2.6 | 3.5 | -0.5 | -1.5 | -2.4 | -2.5 | -2.6 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Output | 1 | 2 | 2 | 3 | 3 | 4 | 0 | -1 | -2 | -2 | -3 |

The converter rounds to the nearest step. A value halfway between two steps goes up (toward positive infinity). It does not truncate.

### Dither

The header text is [ACH]:

```
@constant   kAudioConverterPropertyDithering
				A UInt32. Set to a value from the enum of dithering algorithms below.
				Zero means no dithering and is the default. (macOS only.)
@constant   kAudioConverterPropertyDitherBitDepth
				A UInt32. Dither is applied at this bit depth.  (macOS only.)

@constant   kDitherAlgorithm_TPDF             Dither signal is generated by a white noise source with a triangular probability density function
@constant   kDitherAlgorithm_NoiseShaping     Use a static, perceptually weighted noise shaped dither
```

- The block is inside `#if !TARGET_OS_IPHONE`. It has no `API_AVAILABLE` mark [ACH].
- The property is in the macOS 10.9, 10.13, 11.3, 12.3, 13.3, 14.5, and 15.5 SDK headers [SDKH]. It is thus available on macOS 14.
- The default value reads back as 0 (tested). `kDitherAlgorithm_TPDF` and a bit depth of 16 return noErr. With TPDF, 8 frames of silence gave `[0, 0, 0, 0, 0, 0, 1, 0]` (tested). The dither is active.
- `AVAudioConverter.dither`: "Setting YES will turn on dither, if dither makes sense in given the current formats and settings. Default value is NO" [AVC].

## 6. NSSavePanel

- Replace confirmation: the save panel asks the user "whether to replace an existing file, if a file with the specified name already exists in the given location" [DLG]. This research did not find the exact text of the alert in an Apple source (unconfirmed).
- The panel does not delete the existing file. `URL`: "A file may already exist at `url` if the user choose to overwrite it" [NSP]. `panel:validateURL:error:`: "An item at `url` may not physically exist yet, unless the user decided to overwrite an existing item" [NSP]. The app writes the file after the panel closes.
- From macOS 10.15, "the system always displays the Save dialog in a separate process". When the user saves, "macOS adds the saved file to the app's sandbox (if necessary)" [NSPD].
- `accessoryView`: "the accessoryView's frame will be observed, and any changes the programmer makes to the frame will automatically be reflected in the panel" [NSP].
- `allowedContentTypes` (macOS 11): "If no extension is given by the user, the first preferred extension from the array will be used as the extension" [NSP]. The header says that `allowedContentTypes` "can be changed while the panel is running (ie: from an accessory view)" only in the `NSOpenPanel` part [NSP]. A live change in a save panel that updates the extension in the name field is common practice but not documented (unconfirmed).
- macOS 15 adds `showsContentTypes` ("a control for selecting the type of the saved file") and `currentContentType` [NSP]. On macOS 14 an accessory view with a format pop-up is necessary.
- `panel(_:userEnteredFilename:confirmed:)`: the panel calls it "before appending any required filename extension information, and before it asks the user whether to replace an existing file". "In macOS 10.15 and later, you cannot change the filename that the user selects" [DLG]. The return value can be `nil` to "cancel the save operation and leave the Save panel onscreen" [DLG].

## 7. renamex_np

- Declaration: `int renamex_np(const char *, const char *, unsigned int)`, available from macOS 10.12 [STDIO].
- `RENAME_SWAP`: "On file systems that support it (see getattrlist(2) VOL_CAP_INT_RENAME_SWAP), it will cause the source and target to be atomically swapped" [MAN].
- `RENAME_EXCL`: "On file systems that support it (see getattrlist(2) VOL_CAP_INT_RENAME_EXCL), it will cause EEXIST to be returned if the destination already exists" [MAN].
- Both flags together give `EINVAL` [MAN].
- Errors: `[EEXIST]` "flags has RENAME_EXCL set but new already exists". `[ENOTSUP]` "flags has a value that is not supported by the file system". `[ENOENT]` "flags has RENAME_SWAP set but new does not exist" [MAN].
- Plain `rename()`: "If new exists, it is first removed". It "guarantees that an instance of new will always exist, even if the system should crash in the middle of the operation" [MAN].
- `getattrlist` bits: `VOL_CAP_INT_RENAME_SWAP` and `VOL_CAP_INT_RENAME_EXCL` [GAL].
- No Apple source lists the file systems. A local test on 8 MB disk images gave these results (tested):

| File system | SWAP bit | EXCL bit | EXCL onto existing | EXCL onto new name | SWAP |
|---|---|---|---|---|---|
| APFS (also the system volume) | set | set | EEXIST | OK | OK |
| HFS+ | not set | set | EEXIST | OK | ENOTSUP |
| exFAT (FSKit) | not set | not set | EEXIST | ENOTSUP | ENOTSUP |
| MS-DOS FAT (FSKit) | not set | not set | EEXIST | OK | OK |

- On FAT, the calls succeed but the capability bits are not set. The atomicity of these calls on FAT is not known (unconfirmed). Do not trust the bits alone. Handle `ENOTSUP` at the call.

## 8. Full disk

- No Apple source names the error that `ExtAudioFileWrite`, `AudioFileWritePackets`, or `AVAudioFile.write(from:)` returns on a full disk (unconfirmed).
- A local test on full APFS and HFS+ disk images gave the same result for all three calls (tested):
  - `ExtAudioFileWrite` (WAV, 16-bit) returns -40. `errno` is 28 (`ENOSPC`) after the call.
  - `AudioFileWritePackets` (CAF, float) returns -40.
  - `AVAudioFile.write(from:)` (WAV, 24-bit) throws an `NSError` with domain `com.apple.coreaudio.avfaudio` and code -40.
- -40 is `kAudioFilePositionError`, "Invalid file position" [AF]. It is not `dskFulErr` (-34) and not `kAudioFileOperationNotSupportedError`.
- After the failed write, `ExtAudioFileDispose` returned noErr. The WAV file was readable and held all frames of the writes that succeeded (tested).

## Consequences for the export run

- Hindenburg has Export (⌘E) and Export Selection (⇧⌘E). An export API that takes a time range and a set of tracks covers both. The default range for a full export is not known from Hindenburg.
- Do not rely on the AudioConverter default for 2 to 1 channels. It drops R. Mix to mono in the app render code with a stated law, or set `PerformDownmix`. Its map is always normalized to the average law, and it is only in the macOS 26 SDK.
- Offer only AAC bit rates from the applicable list. Stereo starts at 64 kbit/s. Mono stops at 256 kbit/s.
- `AVAudioFile` writes `iTunSMPB`, so a test can assert that the read length equals the frames written.
- `AVAudioFile` does not resample and does not refuse a buffer at another rate. Resample before the write (`AVAudioConverter`) or write through `ExtAudioFile`. Test that the output length is the input length times the rate ratio.
- Float to integer clips and rounds. Dither is off by default. For a 16-bit export, turn on TPDF dither.
- The save panel keeps the old file. Write to a temporary file in the target directory, then rename it over the target. `rename()` replaces atomically. `RENAME_SWAP` and `RENAME_EXCL` are not on every file system.
- Treat -40 from a write, with `errno` `ENOSPC`, as "disk full". Show a clear message and delete the temporary file. The old export file stays unchanged.

## Sources

- [EDSP] Dirigible, `docs/research/export-and-dsp.md` (2026-09-23).
- [T] Local tests, macOS 15.7.9, Intel x86_64, Xcode 26, 2026-09-25. Swift and C programs in the session scratchpad, not in git.
- [ACH] macOS 26 SDK, `AudioToolbox.framework/Headers/AudioConverter.h`. Path: `$(xcrun --show-sdk-path)/System/Library/Frameworks/`.
- [ACD] macOS 26 SDK, `AudioToolbox.framework/Headers/AudioCodec.h`.
- [EAF] macOS 26 SDK, `AudioToolbox.framework/Headers/ExtendedAudioFile.h`.
- [AF] macOS 26 SDK, `AudioToolbox.framework/Headers/AudioFile.h`.
- [AVS] macOS 26 SDK, `AVFAudio.framework/Headers/AVAudioSettings.h`.
- [AVF] macOS 26 SDK, `AVFAudio.framework/Headers/AVAudioFile.h`.
- [AVC] macOS 26 SDK, `AVFAudio.framework/Headers/AVAudioConverter.h`.
- [NSP] macOS 26 SDK, `AppKit.framework/Headers/NSSavePanel.h`.
- [STDIO] macOS 26 SDK, `usr/include/sys/stdio.h`.
- [SDKH] Older macOS SDK headers: https://github.com/alexey-lysiuk/macos-sdk and https://github.com/phracker/MacOSX-SDKs
- [MAN] `man 2 rename` (rename, renameat, renamex_np, renameatx_np), macOS 15.7.9: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/rename.2.html
- [GAL] `man 2 getattrlist`, macOS 15.7.9: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getattrlist.2.html
- [DLG] Apple, `panel(_:userEnteredFilename:confirmed:)`: https://developer.apple.com/documentation/appkit/nsopensavepaneldelegate/panel(_:userenteredfilename:confirmed:)
- [NSPD] Apple, `NSSavePanel`: https://developer.apple.com/documentation/appkit/nssavepanel
- [TN2258] Apple, Technical Note TN2258, AAC Audio - Encoder Delay and Synchronization: https://developer.apple.com/library/archive/technotes/tn2258/_index.html
- [BS775] ITU-R BS.775-4 (12/2022), Multichannel stereophonic sound system with and without accompanying picture: https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.775-4-202212-I!!PDF-E.pdf
- [HJ] Hindenburg Journalist 1.21 user guide (OS X), pages 77–85: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HPG] Hindenburg PRO guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HPS] Hindenburg PRO shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HNG] Hindenburg Narrator guides: https://hindenburg.com/academy/guides/guides-narrator/
- [HD23] Hindenburg, Door 23: Export Audio & Loudness Standards (LUFS): https://hindenburg.com/2025-dec-calendar-content-1/december-23/?sector=user
- [HMONO] Hindenburg support, "When i export in mono i get silence": https://hindenburg.uservoice.com/knowledgebase/articles/294468-when-i-export-in-mono-i-get-silence
- [HMISS] Hindenburg support, "Missing audio files or no sound": https://hindenburg.uservoice.com/knowledgebase/articles/680065-missing-audio-files-or-no-sound
- [BUZZ] Buzzsprout, Hindenburg Journalist Pro review: https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough
- [PVC1] ProVideo Coalition, How to export -16 LUFS from Hindenburg Journalist: https://www.provideocoalition.com/export-16-lufs-hindenburg-journalist-without-dangers-insecure-ftp/
- [PVC2] ProVideo Coalition, Hindenburg adds -14 LUFS at NAB 2018: https://www.provideocoalition.com/hindenburg-adds-14-lufs-avid-pro-tools-intolerability-at-nab-2018/
