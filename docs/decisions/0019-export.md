# 0019. Export: one ExtAudioFile writer, a mono fold in our code, a Studio export job, and a replace only over the confirmed item

- Status: accepted
- Date: 2026-09-25
- Accepted: 2026-09-25, after plan gate 1 of the export run. The gate kept Record on during an export, moved the export to a utility GCD queue, ran the take checks before the cancel, and added the settle gate.
- Amended: 2026-10-05, run `2026-10-05-mute-solo`. The export renders only the heard tracks of its source, and the media check of an export skips the files of unheard tracks. The panel and `dirigible export` say when a track of the source is not heard (see 0039).
- Amended: 2026-10-05, run `2026-10-05-file-import`. Capture first applies to an import too: a take start in another window, and the disk check of a take on the same volume, end the import, which then throws `.importYielded` (see 0040).
- Amended: 2026-10-03, run 9a. WAV 16 and FLAC 16 get a seeded TPDF dither; each export stays repeatable, and FLAC equals WAV bit for bit. An export with a loudness target renders two passes: progress maps pass 1 to 0...0.25 and pass 2 to 0.25...1, with at most 101 calls. A clean export with a target shows the report in a banner; with silent files, the one alert also has the report line. `dirigible export` takes `--loudness podcast|speech|ebu|atsc`. Only an export with a target is limited: with Off, a mix over full scale still clips. See 0032.
- Amended: 2026-10-03, MP3 run. `ExportFormat` has `.mp3(BitRate)`; `AACBitRate` is `BitRate`. MP3 goes through LAME, not `ExtAudioFile`: `writeFile` gives its body a write function. An MP3 file rate other than 32, 44.1, or 48 kHz throws `.rateNotSupported` before any file exists. `dirigible export` takes `.mp3`. See 0034.
- Amended: 2026-10-15, run `2026-10-15-export-loudness`. The progress of an export with a target maps pass 1 to 0...0.15, the trial passes of the gain search to 0.15...0.3, and the write to 0.3...0.75 (0.15...0.75 with no trial pass, and up to 1 with no read-back). The read-back and each retry round share 0.75...1 in equal bands, with at most 101 calls. The call of 1.0 comes after the read-back. See 0032.
- Amended: 2026-11-02, run `2026-10-28-chapter-export-files` (see 0067). One export job can hold a set of files, one for each chapter or marker of the range. The target check covers every file of the set before the first write, and the window asks once before it replaces any of them. A stop keeps the finished files and removes the file in hand. Dirigible never deletes the older files of the stem.
- Amended: 2026-11-20, run `2026-10-28-stem-export` (see 0078). `exportStems` in `Render/ExportStems.swift` is a further public writer: one WAV or FLAC file for each heard track or role, all from the range start, in a new folder that appears whole or not at all. It renders and encodes each file only through `exportMix`, as an item of the item loop. `ExportResult` gives the sample peak of the file; the behavior of `exportMix` does not change. The name in front of `-<NN>-<title>` of a set is the prefix; a stem is one file of a stem export.

## Context

Release 1 run 5 (`docs/requirements/releases.md`) exports the mix: WAV, AAC in `.m4a`, and FLAC (R11 part, 0007), mono or stereo (R15), with progress and Cancel, never during a take, and never over a file that the user did not confirm. 0003 asks for a missing-media question before an export and a report after it. 0011 asks for a `dirigible` command. 0016 says that playback, `dirigible render`, and export use one mix render (`MixReader`). Research: `docs/research/export.md`.

Probes on 2026-09-25 (Intel i5-8259U, macOS 15.7.9, Swift 6.2.4; `.scratchpads/runs/2026-09-25-export/probe/output.txt`):

- P1, P2. `ExtAudioFile` with a float32 client writes WAV 16 and 24, FLAC 16 and 24, and AAC in M4A. FLAC decodes bit for bit equal to the WAV of the same depth. The AAC read length equals the frames written.
- P3. Float to integer clips and rounds half up. No dither by default.
- P4. `ExtAudioFile` resamples when the client rate differs from the file rate, with an exact length. `AVAudioFile` does not resample: it writes 48 kHz frames into a 44.1 kHz file with no error (research).
- P5. AAC takes 32 to 256 kbit/s mono and 64 to 320 kbit/s stereo at 44.1 and 48 kHz. At 96 kHz the format set gives `'fmt?'`.
- P6. AAC keeps a 1 kHz sine within 0.01 dB. White noise loses up to 1.7 dB.
- P7. 2 h of stereo at 48 kHz: WAV 24 in 4.8 s, FLAC 24 in 57 s, AAC 128 in 51 s.
- P8, P8b. A full disk gives -40 from `ExtAudioFileWrite` with errno ENOSPC; a lost volume gives -40 with errno EIO.
- P9. `renamex_np(RENAME_SWAP)` on FAT reports success and deletes the old file. exFAT gives ENOTSUP for `RENAME_EXCL` onto a new name and for `RENAME_SWAP`. `rename(2)` replaces on APFS, exFAT, and FAT. A new file at the same name gets a new `st_ino`.
- P9b. A new file at the same name also gets a new `st_ino` after `unlink` then create at once, and after `rename(2)` of a new file over it, on APFS, exFAT, and FAT (FSKit mounts, macOS 15.7.9). `st_birthtime` repeats on FAT (1 s) and exFAT (10 ms), so it adds nothing to the identity.
- P10. A 2-channel client into a 1-channel file keeps L and drops R.
- P11. `NSSavePanel.url` follows a live change of `allowedContentTypes`.
- S1. A SwiftUI sheet on the hosted content of a window attaches an AppKit sheet and turns the close button off. The probe did not show the key status.

## Decision

**Commands.** File > Export... (Cmd-E) exports the whole mix: frames 0 up to `session.end`, all tracks. File > Export Selection... (Shift-Cmd-E) exports the range of the Marks on the selected tracks, as Hindenburg does. Both open a save panel with an accessory view: the format (WAV, AAC, FLAC), the bit depth (16 or 24, default 24) for WAV and FLAC, the bit rate (64, 96, 128, 160, 192, 256 kbit/s, default 128) for AAC, the channels (stereo or mono, default stereo), and the rate (the session rate, 44.1 kHz, or 48 kHz, default the session rate). A format change sets `allowedContentTypes`, so the extension follows (P11). The app defaults keep the last options.

**Writer.** `exportMix` in `DirigibleAudio/Render/Export.swift` is the one public writer. It takes a session, an `ExportSource` (a range and nil or a set of tracks), `ExportOptions` (an `ExportFormat` of `.wav(BitDepth)`, `.flac(BitDepth)`, `.aac(BitRate)`, or `.floatCAF`; a `ChannelLayout`; an `ExportRate` of `.session`, `.hz44100`, or `.hz48000`), the target URL, an optional `ConfirmedFile`, a package source, and a progress closure. It writes every format through `ExtAudioFile`, with a float32 client at the session rate. The file rate is the chosen rate; the converter of `ExtAudioFile` resamples (P4). The WAV file type is `kAudioFileRF64Type`, as `ClipWriter`: a plain RIFF WAV under 4 GiB and RF64 above it. The AAC bit rate goes to `kAudioConverterEncodeBitRate` of the converter, then a nil `kExtAudioFileProperty_ConverterConfig`. An AAC file rate above 48 kHz throws `.rateNotSupported` before any file exists (P5). There is no dither (P3); so each export is repeatable, and FLAC equals WAV bit for bit. `renderMix` goes: `dirigible render` calls `exportMix` with `ExportOptions.render` (float32 stereo CAF at the session rate, never a replace), so render and export cannot differ. `RenderError` becomes `ExportError`, and `removeRenderLeftovers` becomes `removeExportLeftovers`.

**Mono.** The mix renders stereo (0016). A mono export folds each chunk to `0.5 * (L + R)` in our code before the write (0007, P10). A mono track (L = R) keeps its level. A signal only in L is 6.02 dB lower. L = -R gives silence.

**Range and tracks.** The export takes a frame range and an optional set of track IDs. `MixReader` reads `Session.heardTracks(in:)`: the tracks of the set that are heard, so it skips the tracks that are not in the set, are muted, or are not soloed while another track is (0039).

**Progress and Cancel.** `exportMix` renders and writes 1 s chunks. After each write it calls a synchronous progress closure on the export thread when the percent changes (at most 101 calls), and it calls a cancel check (`Task.isCancelled` by default). A cancel throws `.cancelled`. The last call (1.0) comes after the last write and before the close and the move. After the close, the export reads the cancel check once more: a cancel there throws `.cancelled` before the flush and the move, so a take start does not wait for them (code gate 1).

**Package path.** At each chunk the export reads the package path from its source: `lock.package()` in Studio, the fixed path in the CLI. A package that moves on its volume keeps its audio. A package that the lock no longer finds throws `.packageUnavailable`.

**Faults.** -40 from `ExtAudioFileWrite` with errno ENOSPC is `.diskFull`; any other failing status is `.writeFailed(status)` (P8, P8b). EMFILE and ENFILE at a file open are `.openFailed` (0016). A missing, short, or unreadable file is not an error: it renders as silence, and the report names it.

**File safety.** The export writes `.<name>.<UUID>.tmp` next to the target, closes it, and flushes it with `F_FULLFSYNC` (with `fsync` where the volume refuses it). After the move it flushes the folder. The move:

- With no confirmed item: the no-replace move of 0016. `renamex_np(RENAME_EXCL)`; on ENOTSUP or EPERM (exFAT), a claim with `O_CREAT | O_EXCL`, then `rename(2)` over the claim. An item at the target gives `.exists`.
- With a confirmed item (the save panel asked "replace?", or `--replace`): the caller gives the `(st_dev, st_ino)` of the item that the user confirmed, read at the confirmation. At the move, when the item at the target has the same identity, `rename(2)` replaces it atomically. When the target is empty, the no-replace move runs. When another item is at the target, the export throws `.exists` and that item does not change.
- `RENAME_SWAP` is not used: on FAT it deletes the old file (P9).
- Every exit removes the temporary file. The export makes the temporary file with `O_EXLOCK` and holds that flock until its end; a volume that refuses the lock (ENOTSUP) gets the file with no lock. At its start, an export removes the dead temporary files of exports to the same target: only a file that it can lock with `O_EXLOCK | O_NONBLOCK`, so the file of a live export stays (code gate 1). The flock holds on APFS, exFAT, and FAT (probe g1-flock). In the CLI, Control-C cancels the export, so the export removes its own temporary file, and the exit status is 130.

**Studio.** `Studio.export(_:_:to:replacing:)` runs `exportMix` on `DispatchQueue.global(qos: .utility)`, bridged to the job task with a continuation, so its disk reads yield to a take in another window. The chunk loop does not run in a Swift task: a caller that awaits a task raises it to the priority of that caller. On the GCD thread `Task.isCancelled` is false, so a task cancel sets a flag that the cancel check of `exportMix` reads. `exportProgress` (nil when no export runs) is observable. `cancelExport()` cancels. The export renders the session of its start: an edit during an export is saved and does not change the file. An export throws `.busy` during a take start, a take, a finalize, a pending take, another export, or a `settle()`. A take start during an export runs its device lookup, route, and microphone access checks first; a refusal keeps the export. Then it cancels the export and waits for its end, then runs its disk check and its start save, and records: capture comes first, and the export can run again. Capture comes first across windows too (code gate 1): the app gives each studio the studios of the other windows (`otherStudios`). At the same step, a take start also ends the exports of the other windows. Such an export throws `.exportYielded`, and its window shows an alert with the reason. An export of another window can start during a take (it runs at utility QoS, M4). Before a disk-low stop, the disk watcher of the take ends each export of another window whose target is on the volume of the package (`st_dev`), and counts the space again at the next check. `settle()` sets its settling flag before its first await, then cancels the export and waits for its end, so Close and Quit leave no temporary file and no export starts after them. `exportFaults(_:)` checks the files that an `ExportSource` reads, off the main actor.

**Window.** Before the panel, the window asks the media question when a file that the range reads has a fault: the paths, then Export or Cancel. Then the save panel. While the export runs, a sheet shows the progress bar and Cancel, and the window close button is off (S1). The sheet also has a Record button: the sheet can hold the key status, so the Record menu item may not reach the window. The design does not depend on the key status of the sheet: Studio gates the take and snapshots the session. A take start that its checks refuse keeps the export, and the sheet shows its error in one line under the progress bar: a window alert would wait behind the sheet until the export ends (code gate 1). After the export, an alert names each file that rendered as silence; a clean export shows nothing. A failure shows an alert with the message of its error. A cancel shows nothing. Export and Export Selection are off while a step of the export flow runs. Record stays on while the media check runs and while the export runs; it is off only while the question or the save panel shows, because one Cancel frees it and a take would drop the typed name.

**CLI (0011).** `dirigible export <package> --out <file> [--bits 16|24] [--bitrate 64|96|128|160|192|256] [--mono] [--rate 44100|48000] [--from N] [--to N] [--track ID]... [--replace] [--allow-missing]`. With no `--rate`, the session rate. The extension of `--out` gives the format: `.wav`, `.m4a`, or `.flac`. Another extension, an option of another format, or a value outside its list is a usage error (exit 64). A missing, short, or unreadable file in the range gives exit 2 with the path, unless `--allow-missing`: then one warning line per file and exit 0. The warning lines come from the faults that `exportMix` returns. A fault that only the export finds (a file that goes bad after the check) also gives exit 2 with the path, unless `--allow-missing`; the output file is then written with those clips as silence, and the error says so (code gate 1). An existing `--out` gives exit 2 unless `--replace`. The CLI reads the identity of `--out` at its start as the confirmed item. The CLI takes no package lock, as `render`. `dirigible render` does not change.

## Consequences

- 0003 gets an amended line: the export question and report.
- 0007 gets an amended line: WAV 16 or 24-bit, the AAC bit rates, and the rates; `ExtAudioFile`, not `AVAudioFile`.
- 0011 gets an amended line: `dirigible export`.
- 0016 gets an amended line: `renderMix` is replaced by `exportMix` with `ExportOptions.render`; `MixReader` takes a track set.
- 0002 gets an amended line: `Studio+Export.swift` and `Render/Export.swift`.
- A mix above full scale clips in the integer and FLAC formats (P3). The Release 2 limiter (0008) fixes it.
- A crash during an export leaves a temporary file next to the target until the next export to that target. On a volume with no flock, it stays.
- A take start that its disk check or its start save refuses has already cancelled the export. The user runs the export again. The disk check comes after the cancel, so it sees the space of the removed temporary file.
- The `st_ino` identity on FAT and exFAT is proven only for the FSKit mounts of macOS 15 (P9b). macOS 14 is a manual check.
- The identity check and the `rename(2)` are two calls: an item that replaces the confirmed one in the microseconds between them is replaced. We accept this window.
- The FLAC and AAC encoders on macOS 14 have no test on a macOS 14 machine: a manual check.

## Alternatives considered

- **`AVAudioFile` for the write.** Rejected: it does not resample, and it accepts frames of another rate with no error (research).
- **The AudioConverter downmix (`kAudioConverterPropertyPerformDownmix`).** Rejected: it is only in the macOS 26 SDK, and the default 2-to-1 conversion drops R (P10). Our fold is one vDSP call.
- **0.7071 x (L + R) (BS.775).** Rejected: a mono voice on both channels comes out 3 dB hotter and can clip; 0007 and 0008 use 0.5.
- **`RENAME_SWAP` for the replace, with a swap back on a wrong identity.** Rejected: FAT deletes the old file (P9), and exFAT and HFS+ refuse it.
- **Delete the old target before the export.** Rejected: a failed or cancelled export would lose the old file.
- **An export job that the window owns, with only a gate in Studio.** Rejected: cancel, progress, and the lock life move into the app target, and each window exit path must call the end of the gate.
- **The chunk loop in a detached task at utility priority.** Rejected: an await of the task from the main actor raises its priority.
- **Record refused during an export.** Rejected: a refused Record can lose a live moment; the export can run again.
- **`dirigible render` as a mode of `export`.** Rejected: `render` has its own tests and callers; one private writer already keeps the two equal.
- **TPDF dither for 16-bit.** Deferred to the Release 2 gain stage (backlog).
