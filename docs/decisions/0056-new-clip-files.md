# 0056. New clip files: one batch type for the bytes, one Core call for the record

- Status: proposed
- Date: 2026-10-14
- Amends: 0040 (import renames with `moveNew`, never a replace; import makes `Clips/` when it is missing), 0042 (paste writes through the same batch).

## Context

Import and paste each own a copy of the new-file transaction: the space check, the temp names, the renames, the flush of `Clips/`, and the cleanup. Import replaces a file at the name (`rename(2)`), and paste refuses one (`moveNew`). Render (0054) and split stereo (0053) add two more writers, and each needs unique stems inside one batch. Each file that render or split makes from a run of another file must keep the `capture` of the source and its transcript words (0055); only `DirigibleCore` can reach the words.

## Decision

- **Bytes in `DirigibleAudio`.** `NewClipFiles` (`Finalize/NewClipFiles.swift`, internal, noncopyable) is the one owner of a new WAV in `Clips/`: one space check (`wavFileBytes(frames:channels:)`, 3 bytes for each sample, plus `diskMargin`; a batch of 0 bytes makes no check), `mkdir Clips/` once, the temp names `.<stem>.wav.tmp`, the stem rule of 0040 with the stems of the batch as `taken:`, the renames with `moveNew` in add order, one flush of the `Clips/` folder, and the list of renamed files (`made`). The caller calls `discard()` in a `defer`, which unlinks each temp that is not renamed. No code of the batch deletes a renamed file (0040); a caller that must remove them reads `made`. Each writer flushes its own file before the commit (a copy with `fullFlush`, a conversion in `ClipConversion`), so a file that a session names has its data on disk.
- **Record in `DirigibleCore`.** `ClipRun` (public) and `Session.clipRuns(of:sampleRate:)` (`package`, no layout check) are the run of clips of one file. `Session.addDerivedFile(from:stem:layout:)` (internal) is the one call that adds a file made from a run: it derives the ID, the path, the length (`run.span.count`), and the `capture`, and it copies the transcript anchors whose midpoint is in the span. `repoint` (render) and `splitStereo` call it.
- Each new writer of a `Clips/` file uses both. The finalize of a segment stays out: 0021 lets it run again after a crash between its rename and its save.

## Consequences

- Import never replaces a file in `Clips/`: a race with another file at the name throws a write fault with EEXIST, and that file keeps its bytes.
- A fix to the crash order, the name rule, or the space rule is one edit.
- On exFAT, a crash between the claim and the rename of `moveNew` leaves a 0-byte WAV that no session names, as for paste and export.

## Alternatives considered

- **A scoped function that owns the whole order.** Each caller gets a generic typed-throws body and a mapping closure, and the renamed files only through a callback.
- **The caller builds the `AudioFile` of a derived file.** The length and the capture can then be wrong in each caller.
