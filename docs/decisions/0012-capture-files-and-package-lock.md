# 0012. Capture files, the sidecar format, and the package lock

- Status: accepted
- Date: 2026-09-24

## Context

Decision 0004 fixes the capture pipeline and leaves four details open. The capture-finalize run (`.scratchpads/runs/2026-09-24-capture-finalize/design.md`) needs them before its first file on disk:

- 0004 names the segment files `<trackID>-<take>-<segment>.caf`. A `TrackID` is free text. It can hold `/`, which makes a path outside the folder, and `-`, which makes the take number impossible to parse.
- 0004 says what the sidecar holds, not how its bytes look or how a reader finds a torn record.
- 0011 found a race between the CLI and Studio: the CLI reads `session.xml` with no `<recording>`, Studio saves `<recording>`, and the CLI save removes it. 0011 asks the capture run for a package lock.
- 0002 lists a `Recorder` actor in `DirigibleAudio`. The first capture run has no IOProc, so a `Recorder` would only forward calls.
- 0004 keeps a take pending when finalize throws. A fault that recurs on every run (a corrupt CAF, an ID that the session refuses) would then block the take, and its armed tracks, forever.
- A 24-bit WAV has 32-bit sizes. A stereo take at 48 kHz passes 4 GiB after about 4.1 h, a mono take after about 8.3 h.

Local probes on 2026-09-24 (`.scratchpads/runs/2026-09-24-capture-finalize/probe/`, `output.txt`):

- `flock` refuses a second descriptor of one file in the same process. `AVAudioConverter` converts from a fractional input rate (48002.4 Hz) with the length and an impulse position within 1 frame.
- The AudioFile WAVE writer refuses a write past 4 GiB (`kAudioFileDoesNotAllow64BitDataSizeError`). `AVAudioFile` with `AVAudioFileTypeKey = kAudioFileRF64Type` wrote 716,000,000 frames of 24-bit stereo (4,296,004,096 bytes) as RF64 and read all frames back. The same writer under 4 GiB wrote a plain RIFF WAV, byte for byte equal to the output without the key. Without the key, the large file was BW64.
- `AVAudioFile.close()` returns void (macOS 15 SDK), so it cannot report a close error. `ExtAudioFileDispose` returns a status. `ExtAudioFile` with `kAudioFileRF64Type` wrote 1,432,000,000 mono 24-bit frames as RF64 and read all frames back. On a full disk, each writer failed a write (status -40) and dispose returned 0; no free space gave good writes and a failed close.

## Decision

**Files in the package.**

- `Capture/` holds the raw segments: `<stem>.caf` (float32, interleaved, 1 or 2 channels, at the header rate) and `<stem>.sidecar`. `Clips/` holds `<stem>.wav` (0003).
- The stem is `take<take>-<arm>-<segment>`. `<arm>` is the 1-based index of the track in `<recording>` (the order of the `<arm>` elements). `<segment>` counts from 1 for each device. Each part is a decimal integer.
- The capture ID, the file ID, and the clip ID of a segment are its stem.
- Each part of a stem has 1 to 9 digits and no leading zero, so a name has one spelling and no part overflows. File names match `^take([1-9][0-9]{0,8})-([1-9][0-9]{0,8})-([1-9][0-9]{0,8})\.(caf|sidecar|wav)$`.
- The next take number is 1 plus the highest take number in: the matching names in `Capture/` and `Clips/`, the capture, file, and clip IDs of `session.xml` whose part before the first `@` is a stem, and the take of `<recording>`. Other names and IDs do not count. So a take number is never reused, also after a user empties a folder.
- A clip file over 4 GiB is RF64 (EBU Tech 3306). The writer is `ExtAudioFile` and sets the RF64 file type on every clip; under 4 GiB the file is a plain RIFF WAV. A write or dispose status other than noErr is a WAV that cannot be written or closed. The name stays `<stem>.wav`.
- `recovery-attempt` is the marker of 0004, in the package root. It is not flushed: it guards against a crash loop of the process, and a process crash keeps the page cache.

**Sidecar, version 1.** Little-endian. An 8-byte magic `DRGSIDE1`, then records. A record is a UInt32 payload length, a UInt8 kind, the payload, and the FNV-1a 32-bit hash of the kind and the payload.

- Kind 1, the header, is the first record only: first sample time (Float64), first host time in nanoseconds (UInt64), nominal rate (Float64), latency in device frames (Int32), channel count (UInt8), device UID and device name (each a UInt16 length and UTF-8), and the available nominal rates (a UInt16 count and a min and max Float64 for each).
- Kind 2, a checkpoint, is 24 bytes: file frame (Int64), sample time (Float64), host time in nanoseconds (UInt64).
- The writer writes and flushes the magic and the header before the first CAF frame.
- The reader refuses the sidecar when the magic, the version, or the header is bad. It keeps the checkpoints up to the first record that is short, has a bad hash, has a value that is not finite, or goes back in file frame or host time. It drops that record and every record after it.
- A segment whose CAF has frames but whose sidecar is missing or refused is not placed. Its files stay.

**Finalize faults.** Finalize places each segment on its own: it adds the capture, the file, and the clip of a segment only when all three succeed.

- A fault of one segment leaves that segment unplaced, and the other segments are placed. The take ends: the save removes `<recording>`. These faults are: no sidecar, a refused sidecar, a CAF that does not open as a CAF or has a read error with no errno, a CAF whose rate or channel count differs from the header, a WAV whose length read-back differs, and an ID or value that the session refuses.
- Only a fault that can go away fails the whole take and keeps it pending (0004): `Capture/` or a segment file does not open or read with an errno other than ENOENT (for example EACCES, or EIO in the middle of a CAF read), or `Clips/` or a WAV cannot be made, written, or closed (for example ENOSPC). A retry can then succeed.
- The stop, the recovery at open, the retry, and `dirigible take finalize` use this one rule.

**Unplaced segments.** A segment is unplaced when its CAF in `Capture/` has frames (or does not open), its take is not the pending take, and no file in the session refers to capture `<stem>`. Studio derives the list at each open and after each finalize. Nothing stores it, and the schema does not change. `dirigible take finalize` writes `Warning: Capture/<stem>.caf is not on the timeline.` on stderr for each one and exits 3. Exit 2 (the take stays pending, or the package is locked or unreadable) wins over 3.

**Package lock.** `PackageLock` in `DirigibleCore` takes an exclusive, non-blocking `flock` on `<package>/.lock` (opened with `O_CLOEXEC`) and holds it for the life of the value. `Studio.open` takes it before it reads or writes, and the studio keeps it in a stored property until it goes away. A scoped caller uses `PackageLock.withLock(package) { ... }`, which releases the lock only after the body returns or throws; the initializer is not public, because Swift can release a local value after its last use, before the save. The CLI `editPackage` runs its read, edit, and save in that body. Under the lock, `Studio.open` and `editPackage` first call `Session.removeTemporaryFiles(in:)`, which deletes the leftover `.session.xml.<UUID>.tmp` files of a crashed save; only `SessionWriter.swift` knows that name. A held lock gives `SessionFileError.locked`; the CLI exits 2 with `Error: <path> is open in Dirigible.` The kernel releases the lock when the process dies. The lock file is never deleted. A volume that does not support `flock` (`ENOTSUP`) opens without a lock. A read-only volume (`EROFS`) opens without a lock too: no process can write the package there.

**Armed tracks.** While `<recording>` exists, `Session.setRoute` and `Session.setLayout` refuse an armed track (`.trackInRecording`), and `History.undo` and `redo` refuse an entry that changes the route or the layout of an armed track. `removeTrack` already refuses one. The rules are in `DirigibleCore`, so every front end gets them.

**Warning mark.** The "warning mark" of 0004 is `driftCorrected="false"` on the capture. The UI derives it. The schema does not change.

**Module shape for the first capture run.** `DirigibleAudio` has `Capture/` (`InputDevice`, `InputRecord`, `Sidecar`, `SegmentWriter`, `DeviceWriter`), `Finalize/` (`RateChoice`, `finalizeTake`), and `Studio/` (`Studio`). There is no `Recorder` and no ring in this run. `DeviceWriter` takes `InputRecord` values; the capture-live run fills them from the ring and decides where the IOProc lives. `DirigibleAudio` does not depend on `Atomics` until the ring exists (0005). `DirigibleCLI` depends on `DirigibleAudio` for `dirigible take finalize`.

**Studio.** `pendingTake` is derived from `session.recording` while the transport is idle. It is not stored. The transport has `idle`, `recording(take:)`, and `finalizing(take:)`; `playing` comes with the player. The states x events table is in the run design.

## Consequences

- 0004 names change to the stems above. 0004 gets an amended line that links here.
- 0002 gets an amended line: no `Recorder` yet, and `DirigibleCLI` depends on `DirigibleAudio`.
- `SessionFileError` gets a case, and the CLI message switch gets its line.
- 0004 changes: a fault of one segment no longer keeps the take pending. 0004 gets an amended line.
- 0003 changes: a clip over 4 GiB is RF64, not RIFF. Readers that know only RIFF cannot open it; `AVAudioFile` can. 0003 gets an amended line.
- 0011 gets exit code 3 for `take finalize`.
- A segment that finalize cannot place stays in `Capture/`, and every open lists it until the user deals with it. A later command places one unplaced stem through the same per-segment finalize (for example `dirigible capture place <package> <stem>`); it is in the backlog.
- Every package gets a `.lock` file at its first open.
- A user clip ID equal to a stem leaves that segment unplaced. The `take<n>` prefix and the take number rule make this unlikely: only a clip added while the take is pending can collide.
- A package on a volume without `flock` keeps the 0011 race.

## Alternatives considered

- **Names from a sanitized track ID.** Readable in Finder. Rejected: a percent-encoded ID can pass the 255-byte name limit, and a `-` in the ID breaks the parse.
- **JSON Lines for the sidecar.** Readable with `cat`. Rejected: a host time in nanoseconds passes 2^53 after 104 days of uptime, and readers that keep JSON numbers as doubles (JavaScript, `jq` 1.6) change it. The fixed binary records need no number text.
- **Checkpoints in a CAF chunk.** Rejected: the data chunk of size -1 must be the last chunk while the take runs.
- **A PID lock file made with `O_EXCL`.** Rejected: a crash leaves it, and a stale-lock check can guess wrong.
- **`fcntl` record locks.** Rejected: a process loses them when it closes any descriptor of the file, and two holders in one process do not exclude each other.
- **A `Recorder` actor now.** Rejected for this run: without IOProcs it forwards `stop` and `recover` to the writers and to finalize, and it splits the recovery order between two types.
- **Every finalize fault keeps the take pending (0004 as written).** Rejected: a fault that recurs blocks the take and its tracks forever.
- **Keep `<recording>` while a segment is unplaced.** Rejected for the same reason.
- **A new `<unplaced>` element in `session.xml`.** Rejected: 0003 raises the version for each new element with user data, and the CAF files already hold the fact.
- **Split a clip over 4 GiB into parts.** Rejected: a fourth ID part changes the stem pattern, and RF64 needs one file type.
- **Leave a clip over 4 GiB unplaced.** Rejected: a long recording day reaches 4.1 h.
- **BW64 (the default of `AVAudioFile` over 4 GiB).** Rejected: more readers know RF64.
