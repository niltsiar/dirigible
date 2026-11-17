# 0003. Session file: a document package with our own XML

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-11-17, run `2026-11-04-boundary-fuzz`. The reader refuses a package XML file with an element depth over 64, or a file on which the parser pass stops with libxml2 error 111. A file with an attribute value over the parser limit no longer opens (see Rules).
- Amended: 2026-11-16, run `2026-10-28-package-boundary`. The reader refuses a package XML file with a DTD or another encoding, and a package item that is a link or not of its kind (see Rules).
- Amended: 2026-11-07, run `2026-10-28-timeline-edits`. From version 16, a track can hold `follow="true"`. A track that does not follow writes no attribute (see 0073).
- Amended: 2026-11-03, run `2026-10-28-pre-roll`. A clip of a finalize at the recorded time starts at the playhead of `<recording>` or later: that playhead is the floor of 0004 **Timing**.
- Amended: 2026-09-24. A clip file over 4 GiB is RF64 (EBU Tech 3306) with the .wav name (see 0012).
- Amended: 2026-09-24. The media check runs at open, after each finalize, at each play start, and at window focus. A pool file is `.missing`, `.short(frames)`, or `.unreadable`. The package does not save the playhead (see 0016).
- Amended: 2026-09-25. A pasted clip gets the first free ID of `<source id>@<start>`. A nudged clip keeps its ID (see 0018).
- Amended: 2026-09-25. Before an export, the question lists only the files that the range reads on the chosen tracks. After it, the report names each file that rendered as silence (see 0019).
- Amended: 2026-09-27. The version policy of every file format is in 0024. A package whose `session.xml` has a newer version does not change: the sweep of leftover temporary files runs after the version check (see 0024).
- Amended: 2026-10-05, run `2026-10-05-mute-solo`. Version 5 adds `muted` and `soloed` on `<track>` (see 0039).
- Amended: 2026-10-02. A track route can be `<route app="BUNDLEID"/>`. A session with an app route writes `version="2"`; a session with none writes `version="1"` (see 0029).
- Amended: 2026-10-03, run 11a. A clip has `fadeIn` and `fadeOut` from version 3. A fade of 0 is not written, unlike gain, so a clip with no fade keeps its text (see 0035).
- Amended: 2026-10-04, run 11c-1. A clip has `crossfadeIn` and `crossfadeOut` from version 4. A crossfade of 0 is not written (see 0036).
- Amended: 2026-10-09, run `2026-10-09-autosave-backups` (see 0043). The package has a `Backups/` folder with copies of `session.xml`, named for the UTC time of the copied file. A backup copy uses the same durable write as a save.
- Amended: 2026-10-10, run `2026-10-10-episode-metadata` (see 0045). Version 6 has an `<episode>` element after `<markers>`. The package has an `Artwork/` folder with the episode image, named `<UUID>.jpg` or `<UUID>.png`. An import writes a new file and never replaces one, so undo and the backups keep their image.
- Amended: 2026-10-14, run `2026-10-13-transcript-1` (see 0055). Version 8 has a `<transcripts>` element after `<episode>`, with one reference per transcript; the words are in `Transcripts/<UUID>.xml` (0055).
- Amended: 2026-10-19, run `2026-10-18-envelope-ducking`. From version 10, a clip can hold `<envelope>` with `<point frame="F" gain="dB"/>` children: file frames in strictly ascending order, gains relative to the clip gain. A clip with no point writes no element (see 0060).
- Amended: 2026-10-22, run `2026-10-18-envelope-ducking`. From version 11, a track can hold `role="dialogue"`, `"music"`, or `"effects"`. A track with no role writes no attribute (see 0060).
- Amended: 2026-10-27, run `2026-10-14-render-link` (see 0057). A `<file>` can hold one `<origin source offset gain>` element, with one element for each effect of the render in chain order.

## Context

R5 asks for an XML file that describes the tracks and the clips. R6 asks for clip files in WAV or FLAC in their own folder. The user asked for our own format unless a strong open format fits. `docs/research/session-formats.md` compares AES31-3, AES31-4, OpenTimelineIO, AAF, FCPXML, and Hindenburg `.nhsx`. None stores the capture timing of each device, and each has another gap: AES31-3 is not XML, the AES31-4 spec is behind a paywall, OTIO is JSON, AAF is binary, FCPXML is built for video.

`docs/research/export-and-dsp.md` section 2 measured seeking in a FLAC file through `AVAudioFile`: 0.65 s at minute 28, against less than 1 ms for WAV.

## Decision

**Layout.** A session is a document package, `<Name>.dirigible/` (`LSTypeIsPackage`), with `session.xml` and a `Clips/` folder inside. Finder moves and copies the XML and its clips as one item. A clip refers to its file by a path relative to `Clips/`. (Amended by 0043: `Backups/` holds copies of `session.xml`.)

**Clip files.** 24-bit WAV at the session sample rate. Capture writes CAF first and converts at stop (0004). FLAC is a later preference, because it seeks slowly.

**Schema, version 1.** Our own XML, namespace `https://github.com/niltsiar/dirigible/session`.

- `<session version="1" sampleRate="48000">` holds `<captures>`, `<files>`, `<tracks>`, `<markers>`, and, while a take runs or is pending, `<recording>`.
- `<capture id>` is one device segment (0004): `deviceUID`, `deviceName`, `hostTimeNanos` and `sampleTime` of the first frame, `nominalSampleRate`, `measuredSampleRate`, `latency`, and `resampledFromRate` when finalize resampled, and `driftCorrected="false"` when finalize refused the fit. Both can be present.
- `<file id path channels length capture>`: `channels` is 1 or 2; the parser refuses any other value. `capture` refers to a `<capture id>`. An imported file has no `capture`.
- `<track id name gain layout="mono|stereo">` with an optional `<route device="UID" channels="1 2"/>` (or, from version 2, `<route app="BUNDLEID"/>`, 0029) and its `<clip id file start offset length gain/>` children. A file's channel count must match its track's layout; the parser refuses a mismatch.
- `<marker id name position kind="marker|chapter"/>`.
- `<recording take="3" playheadFrame="..." takeStartHostTimeNanos="...">` lists the armed track IDs as `<arm track="t1"/>` children. It holds both values of the take anchor, so recovery after a relaunch can place the clips. It is present while a take runs or is pending, and a finalize that succeeds removes it (0004). The reader refuses a `<recording>` with an unknown track ID. A pre-roll take adds `preRoll="true"` (version 15, 0024); the reader refuses `preRoll` below version 15 and any other value.

**Rules.**

- Every position and length is an integer frame count at the session rate. No decimal seconds. A frame value is in 0...2^40 (about 260 days at 48 kHz), so no sum of two values can overflow. The edits refuse a value outside this range, and the reader uses the same edits, so a file that the app writes always reads back.
- Clips on one track never overlap. Placing a clip overwrites the clips under it: they are trimmed, split, or removed (Hindenburg paste). A trim does not grow a clip into its neighbor. The reader refuses two clips that overlap.
- When an edit splits a clip, the right part gets the first free ID of `<id>@<frame>`, `<id>@<frame>-2`, and so on, where `<frame>` is the start of the right part. The ID depends only on the session, so finalize and undo stay deterministic.
- Gain is in dB. Zero values are written, not left out. A fade of 0 is not written (0035), and a crossfade of 0 is not written (0036).
- The model keeps the layout rule on every edit, not only at parse time. Adding, moving, or routing a clip or a file of the other layout throws `.layoutMismatch`. A layout change of a track that has clips throws too. A route has 1 channel on a mono track and 2 on a stereo track; the parser refuses a mismatch, and `setRoute` throws `.layoutMismatch`.
- The reader refuses a file with a dangling ID (a clip whose file, or a file whose capture, does not exist in the XML). A missing or short audio file does not refuse the load: the clip gets a "missing media" state, and the player renders it as silence. Export does not ship that silence without notice: before it renders, it lists the missing-media clips and asks the user to confirm, and the export report names them.
- The take anchor: timeline start = playhead at record start + (first-frame host time - take start host time) - latency. Host time is compared only inside one take.
- Save atomically and durably, because `session.xml` is the only record of a running take (0004): write a temporary file with a unique name in the package, flush it with `fcntl(F_FULLFSYNC)` (with `fsync` when the volume refuses `F_FULLFSYNC`), rename it over `session.xml`, then flush the package folder the same way.
- Before the rename, the save reads its own XML back and compares it with the session. A session that would not read back fails the save (`.wouldNotReadBack`), and the old file stays. When the save makes the package, it also flushes the parent folder.
- IDs, names, paths, and device fields hold no control characters and no U+FFFE or U+FFFF. XML 1.0 cannot hold most of them, and it reads tab, LF, and CR in an attribute back as spaces. The edits refuse such text.
- The reader refuses a root element outside the session namespace, and two markers with one ID. It matches elements by local name and namespace, so a prefixed file reads too.
- The reader refuses a package XML file (`session.xml`, a backup, a transcript file) with `.malformedXML` when it does not start with `<` after an optional UTF-8 BOM, is not UTF-8, holds a NUL byte or `<!DOCTYPE`, or has an XML declaration whose `encoding` is not `UTF-8` in any case (`UTF8` is refused). A DTD can read a file outside the package or grow without limit. libxml2 also reads UTF-16, UTF-7, and EBCDIC, where a DTD has no `<!DOCTYPE` bytes. The writer writes none of these, so no saved file changes.
- Before the parse, an `XMLParser` pass reads each package XML file. The reader refuses the file with `.malformedXML` when the element depth is over 64 (the root counts as 1), or when the pass stops with libxml2 error 111 (`XML_ERR_USER_STOP`), for example on an attribute value of 11 MB or a name of 60,000 bytes. The pass reads no byte after either stop, and deep nesting overflows the stack of the `XMLDocument` parse. Another parser error does not refuse the file, so a text node of any size opens. The writer nests 6 deep at most. But a build before this rule can have saved an attribute value over the parser limit (about 10 MB), because no edit limits its length (item 1563). Such a file does not open, a revert to such a backup is refused, and the prune scan counts such a backup as damaged, so it keeps no file (0047 D2). A confirmed prune then moves each file that only that backup holds to the Trash (item 1789).
- The reader refuses a package item that is a link or not of its kind with `.unsafeItem`, before it reads `session.xml`. `.lock` and `session.xml` are regular files, and `.lock` has 1 link at most. `Clips/`, `Transcripts/`, `Backups/`, `Artwork/`, and `Capture/` are folders. Each entry of `Artwork/`, `Capture/`, and `Backups/` is a regular file. An entry of `Clips/` or `Transcripts/` can be a link, and its target is a regular file, or a folder in `Clips/`. After the read of `session.xml`, the open checks each pool file in a subfolder of `Clips/` with `stat`. The read of a backup for a revert makes the same check for the paths of that backup. A `Clips/` or `Transcripts/` folder that does not list (no read access) does not stop the open: a take recovery and a write fault need the open. Then the open checks each pool file or transcript file that `session.xml` names with `stat`, because search access alone opens a known path. It refuses with `.unsafeItem` an item that `stat` shows and that is not a regular file, after links: a FIFO or a device there would make a later read wait for ever. It passes a regular file, a missing item, a dangling link, and an item that `stat` cannot read (for example ELOOP, EACCES, or ENOTDIR). The later read of that item reports the error. Each entry of a `Clips/` or `Transcripts/` folder that lists follows the same rule: an `fstatat` error passes, and the later read reports it. For the other package items, another `lstat` or listing error stops the open with `.unreadableItem`, which names the item: a `Capture/`, `Artwork/`, or `Backups/` folder that does not list stops the open, and `dirigible info` and `dirigible take map` then exit 2 with `cannot read <package>/Capture: Permission denied.` for `Capture/`. A package path that cannot be searched, or that is a file, stops the open with `.readFailed`, the read error of `session.xml`.
- Undo and redo keep the current `<recording>`. It records a take on the disk, not an edit. An edit that changes only `<recording>` makes no undo entry, and an undo that would remove an armed track throws.
- The reader refuses a version higher than it knows, with a clear error. Each new element or attribute that carries user data raises the version. An old app that skips an unknown element and saves would delete that data. The version policy of every file format is 0024.
- The XML code is in `DirigibleCore` (0002), with `XMLDocument` for writing and reading.

**Interchange.** The first export for other editors is the AES31-3 ADL: sample-accurate, audio-first, and a small plain-text writer. FCPXML and OTIO can follow. A best-effort `.nhsx` import comes later.

## Consequences

- Version 3 adds fades (0035), version 4 adds crossfades (0036), and version 5 adds mute and solo (0039). Later versions add gain envelopes, effects (R8, R9), pan, chapter metadata, and loudness per file. Each raises the version.
- A user who wants the WAV files opens the package with "Show Package Contents". The Release 1 timeline run decides whether the app also offers "Reveal clips in Finder".
- The UTI and the `LSTypeIsPackage` entry go in `Support/Info.plist` in the Release 1 session run, checked by `AppBundleTests`.

## Alternatives considered

- **A session file with a sibling clips folder** (like Hindenburg). Rejected by the plan gate: a user who moves only the XML file loses the audio.
- **An open format as the native file.** Rejected for the reasons in the context. Each can still be an export target.
- **Positions in decimal seconds** (like `.nhsx`). Rejected: not sample-exact.
- **FLAC clips by default.** Rejected for Release 1: seeking is too slow for scrubbing.
