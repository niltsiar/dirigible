# 0071. Raw capture removal after finalize

- Status: accepted
- Date: 2026-11-03
- Amends: 0004 (Finalize at stop: a CAF goes after its WAV passes the gate; Disk and sleep: the reason of the 7 bytes), 0012 (sidecar record kind 3; a WAV-backed unplaced segment), 0021 (a placement from the WAV), 0047 (Remove Unused Files keeps the WAV of a removed CAF).

## Context

0004 keeps every raw CAF until a hardware drift check confirms the fit, so each take uses 7 bytes per sample and channel for ever. A tester package has `Capture/` 3.0 GB beside `Clips/` 2.3 GB. The tester asked for less disk use.

The drift fit of 26 tester segments in three packages (run `2026-11-03-caf-removal`): the WAV error against the host clock is 0.861 ms or less at each checkpoint. The worst case is a 67 min take of a USB microphone. Its error is a smooth bow from a rate wander of about ±0.8 ppm, so a linear fit over a longer take can pass the 1 ms criterion of 0004. A call tap on a virtual device has an error of 0.000 ms.

0043 and 0021 say that a revert or an undo of a take shows its segments as unplaced, and that a placement makes the WAV again from the CAF. `ClipConversion` scales a source with a peak over full scale and gives the level back as the clip gain, which an undo or a revert drops. The sidecar reader of 0012 keeps the checkpoints up to the first record that is not a checkpoint.

## Decision

**Gate.** A segment loses its CAF only when every clause holds, computed at the removal:

- A clip of the saved session uses the pool file of the segment, at the path `<stem>.wav`, and the segment is not in the pending take. The saved session is the session on the disk: the studio checks the clause only when no save waits and the session revision is the revision of the last session that a write saved.
- G1 frames: the WAV frames on disk equal the pool file length. With a source rate equal to the session rate, they equal the CAF frames. Else the difference from `CAF frames x session rate / source rate` is less than 1 frame.
- G2 rate choice: the capture has `driftCorrected` true, the sidecar reads and has a usable fit, and `RateChoice` of the sidecar and the CAF frames gives the `resampledFromRate` of the capture, or no resample.
- G3 alignment: at each checkpoint, `|file frame / source rate - (host time - first host time)|` is 1 ms or less.

The gate is per track, against the host clock. The clap check of 0004 asks for two devices within 1 ms of each other; two tracks that each pass G3 can be up to 2 ms apart. The removal does not change the alignment of a WAV: it removes only the source of a later fit.

A segment that fails a clause keeps its CAF. `dirigible info` writes one `raw <stem> kept: <clause>` line for it, and one `raw <stem> kept: not removed yet` line for a placed segment that passes the gate and still has its CAF (a stopped job, or a removal fault in the journal). `info --json` and `session_info` have `rawKept` with the same entries.

**Finalize record.** Sidecar record kind 3, after the last checkpoint: the CAF frames (Int64), the source rate (Float64), and the conversion gain in dB (Float64). The reader uses the last valid kind-3 record. A reader of an older build stops at it and keeps every checkpoint, so the sidecar version stays 1. The finalize appends the record after the rename of each WAV that it converts, with the gain of `ClipConversion` before the level of 0031, and with no flush. A segment with no valid record (a take of an older build, a record that a crash lost, an append fault) gets its gain from the sweep. When the WAV peak is at code 8388604 or less, the gain is 0 dB and the sweep reads no CAF: a rescaled WAV has its peak at code 8388605 or 8388606. Else one converter pass of the CAF, with no writer, gives the peak after the sample-rate converter: over 1.0 with a WAV at code 8388605 or 8388606, the gain of `ClipConversion` for that peak; over 1.0 with a WAV at code 8388607 or 8388608 (full scale, also a sample at -1.0: a saturated WAV of a build before the clip gain), 0 dB; else 0 dB. Each code is a magnitude.

**Order.** Each append first truncates the sidecar to the end of its last valid record (a crash can leave a torn record, and the reader drops all records after it). After the save that names the WAV (0003 durable write), under the package lock: for a segment with no valid record, flush the WAV and `Clips/`, then append and flush the record; else flush the sidecar. Decode the sidecar again, and go on only when its finalize record has the CAF frames of the CAF header and the source rate of `RateChoice`, and, after a sweep append, the gain that the sweep wrote. Unlink the CAF, then flush `Capture/`. So after a crash at any instant, the session names the WAV, or the CAF has frames, or both. A removal fault keeps the CAF, never fails a stop, an open, or an edit, and writes one `raw` line to the journal (0059): the journal of the studio, or for a locked CLI or MCP edit a `-cli-<pid>.tsv` journal that the CLI process starts at the first fault of the edit.

**Callers.** A background job of the studio after each open and after each take or placement outcome with no error. It reads off the main actor. It unlinks only in a turn of the write chain of the studio in which no save waits and the session revision is the revision of the last saved session, after the gate again on the session of that turn; else the CAF stays for the next sweep. A hold stops the job while any studio starts or records a take, or while its studio settles: the job does not start, reads no block, and asks for no turn (0019: capture comes first). A take start sets the hold, then awaits the job of each studio before it takes its own turn of the write chain. No code awaits the job inside a turn of the write chain, because the job waits for a turn of its own chain. `settle()` awaits the job, outside a turn, before the lock goes. `editPackageCore`, after the pending-take refusal, removes only the segments with a valid finalize record and reads no audio. `dirigible take finalize` awaits the job. A package that opens with no lock (0012) has no removal.

**What stays.** The sidecar, the take anchor (0061), each WAV, a CAF of the pending take, and a CAF of an unplaced segment.

**WAV-backed unplaced segment.** A stem WAV in `Clips/` whose sidecar has a finalize record and whose CAF is gone, and that no pool file refers to, is an unplaced segment (0012, 0021). Its placement reads no CAF and converts nothing: the capture comes from the sidecar header and the record, the clip gets the gain of the record, and the WAV stays as it is. It blocks a ripple as a CAF segment does (0037). Remove Unused Files never lists a stem WAV whose CAF is gone and whose sidecar has a finalize record as a stray WAV, and never moves it to the Trash (0047): the app, `dirigible file prune`, and `file_prune` give that set to the scan. An unused pool entry at the path of such a WAV, that no holder keeps (0047, 0057), is a take entry: the prune drops the entry and keeps the file, which then becomes a WAV-backed unplaced segment that the banner lists. A holder keeps the entry and the file, as for every other pool file. The placement needs no free space for a conversion.

**Disk.** The record time keeps 7 bytes per sample and channel: both files exist from the start of the take until the removal.

## Consequences

- A take that passes the gate uses 3 bytes per sample and channel after the removal. The three tester packages free 4,568,082,080 bytes.
- Two hardware clocks can be up to 2 ms apart after a removal, because each segment is 1 ms or less against the host clock. The 0004 hardware check with two USB devices stays a manual check (backlog 1530). A piecewise fit can reduce the bow (backlog 1531).
- A take whose CAF is gone cannot get the piecewise fit of backlog 1531: the fit reads the CAF.
- The first open of an older package reads each WAV once, and each CAF whose WAV peak is near full scale, in the background.
- An edit during the sweep keeps the CAF: the turn checks the gate again on the saved session. A segment whose CAF is gone, and whose clips an edit after the removal deletes, keeps its WAV under an unused pool entry, and it is not an unplaced segment while that entry exists. Undo in the same window brings the clips back. After a close and an open, a backup that names the clip keeps it for a revert; with no holder, Remove Unused Files drops the entry and keeps the WAV, and Place puts the segment back. This is the path of a CAF-backed segment today: first the prune, then Place.
- A take in one studio holds the sweep of every other studio. A held job runs again at the next open, take end, or placement of its own studio, so its CAFs stay until then.
- An older build lists the WAV of a removed take that a later undo made unplaced as a stray WAV. Its Remove Unused Files moves that WAV to the Trash, not out of the disk.
- 0222 (FLAC archive) can rely on this: a placed segment that passed the gate has only its WAV; a kept CAF is float32 and stays; a WAV-backed unplaced segment is a stem WAV and its sidecar.

## Alternatives considered

- **Remove the sidecar too.** Rejected: a placement after a revert or an undo needs the header, the checkpoints, and the record. A sidecar is 133 KB for 67 min of stereo.
- **Remove at the open and the close only.** Rejected: the space comes back only at the next open, and a record day keeps 7 bytes per sample for each take.
- **A `raw="removed"` attribute in `session.xml`.** Rejected: 0003 raises the version for each new element, and an undo or a revert removes the capture with the attribute.
- **Keep the CAF while a backup lacks the take.** Rejected: the backup before the take always lacks it.
- **A gain chunk in each WAV.** Rejected: it changes the clip file that 0222 converts.
- **A pairwise check of the tracks of a take.** Deferred: each tester take has one hardware clock. Backlog 1530 runs it first.
