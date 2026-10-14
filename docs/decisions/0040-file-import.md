# 0040. File import: a 24-bit WAV copy at the session rate, a blocking studio operation, one undo entry
- Amended: 2026-10-13, run `2026-10-13-mcp-long-tools` (see 0049), part 2. A cancel after the rename, also during the level, removes the renamed WAV through one helper, `removeMadeFiles`, so `Clips/` stays as it was. The stem rule makes the WAV a new name that `session.xml` does not use. A flush fault, a failed `session.xml` write, and Undo still keep the WAV. The level after the rename reports progress (the conversion maps to 0...0.8, the level to 0.8...1) and stops at a cancel.

- Status: accepted
- Date: 2026-10-05
- Accepted: 2026-10-05, after plan gates 1 and 2 of run `2026-10-05-file-import`.
- Amends: 0012 (`Clips/` also holds imported WAVs), 0019 (a take start and the take disk watcher also end an import), 0031 (an import and its level are one undo entry).
- Amended: 2026-10-08, run `2026-10-08-paste-across-packages` (see 0042). A paste from another package uses the stem rule, the conversion (`convertToWAV`, from `importAudio`), the blocking run of the studio (`blockingRun`, `ImportRun.kind`), and the rule that nothing deletes a renamed WAV. The import banner has Command-period on Cancel, the banner text as the label of its bar, and a VoiceOver announcement at the start.
- Amended: 2026-10-08, run `2026-10-08-file-drop` (13c). A Finder drop on the lanes imports at the frame under the pointer, on the track of the lane under it. A drop below the last lane, in the New Track zone of min(32 pt, half a lane) at the bottom of the lanes in view, or of 2 or more files goes to new tracks; the zone is at most half a lane high, so each lane fully in view keeps at least half its height as a target. Several files import as a chain, one undo entry each. The chain skips a file that is not audio, has more than 2 channels, or is not downloaded, stops at a cancel, a full disk, or another error, and ends with one alert that gives the error text of each file that did not import and the names of the files after a stop. The import and a paste from another package commit the typed names first. The drop cue is layers over the lanes (0022).

## Context

The user imports a WAV, AIFF, FLAC, MP3, or M4A file into a track (F61, part of R7). A reference to a file outside the package can go missing, so the package must hold a copy. `MixReader` opens a pool file only at the session rate and with the channel count of its layout (0016). Finalize already converts a CAF into a 24-bit WAV at the session rate (0012). Hindenburg converts an import to the session rate with no prompt and levels it. Logic and Audition put a menu import on the selected track at the playhead. The sources are in [the file import research](../research/file-import.md).

## Decision

- **Copy.** An import always writes a copy: `Clips/<stem>.wav`, 24-bit PCM at the session rate, through `ClipWriter`, with the A11 second pass for a peak over full scale. `ClipConversion` is the one conversion of finalize and import: one `AVAudioConverter` (quality max, algorithm Normal) when the rates differ. `AVAudioFile` decodes all five formats; no new dependency.
- **Name.** The stem is the file name with no extension, with no leading "." and no character of `/ : ? * < > | " \` (exFAT refuses them) or that `session.xml` cannot store; an empty stem is "Imported". The file ID and the clip ID are the stem. A stem that a file ID, a clip ID, a pool path, a name in `Clips/`, or the stem of a name in `Capture/` uses, in any case, gets " 2", " 3", and so on. So an import never takes the WAV name of a segment that is not finalized. The take-number scan of 0012 keeps take names apart.
- **Layout.** The target track sets the layout: 2 channels into a mono track are 0.5 L + 0.5 R (vDSP), and a mono file goes to both channels of a stereo track. A new track gets the file layout. A file with more than 2 channels refuses.
- **Target.** The app imports at the playhead, on the one selected track, else on a new last track named after the stem. `dirigible import` imports on `--track`, else on a new track, at `--at` (default 0). The clip overwrites the clips under it, as a placement does.
- **Order.** An iCloud or File Provider item whose data is not on this Mac refuses before its first read. Then the source checks, the target checks, the disk check (the WAV bytes and the 1 GB margin, as a placement), the conversion into `.<stem>.wav.tmp`, the flush and the read-back, the session edits on a copy, the rename, the flush of `Clips/`, then `autoLevel(.eachClip)` on the renamed file. A throw before the rename leaves no new file. After the rename, a cancel removes the WAV with `removeMadeFiles` (0049): the stem rule gives a name that `session.xml` does not use. A flush fault, a failed `session.xml` write, or Undo keeps it as an unused file (F87 removes unused files), because a delete there could remove a file that `session.xml` names.
- **Studio.** `Studio.importAudio` is a blocking operation, as a level: the transport is `.importing(ImportRun)` until the end, so a take, an edit, Cmd-L, and a second import throw `.busy`. It also throws `.busy` during a pending take and during `settle()`. The conversion runs on a utility GCD thread. The result is one undo entry for the track, the file, the clip, and the level, then `poolChanged(from:)`, so the peaks of the new file load.
- **Cancel.** The cancel flag of the run is read before each block of 65,536 source frames in each pass, before the read-back, and after the rename, where a cancel skips the level. `Studio` reads it again after the conversion and writes nothing when it is set. Close and Quit (`settle()`) set it before their first `await`. A take start in another window and the take disk watcher on the same volume set the flag, as for an export (0019, capture first), and do not wait for the import thread: a source read can stall (an online-only file). The import then writes nothing and throws `.importYielded`. Close, Quit, and Cancel wait for the thread.
- **Progress.** Pass 1 maps to 0...0.5 and pass 2 to 0.5...1; a one-pass import goes from 0.5 to 1 at its end. So progress never goes down.
- **Interface.** File > Import Audio… (Command-T, as Hindenburg) opens the open panel for one file. The banner row shows the name, a bar, and Cancel. Record, the import item, and the edit items whose key no text field uses (Insert, Cut in Selected Tracks, Fade, Auto Level, Auto Level per Track) are off during an import. The other edit items stay on and do nothing, because a field uses their keys (0018 K1). The new clip is selected after it. Each error alert quotes the file name and says how to fix the problem.

## Consequences

- The session format does not change: an imported file has no `capture` (0003).
- The studio is busy for the conversion time, about 10 to 40 s for a 1 h MP3. The user can cancel.
- An imported clip keeps 24 bits; a float source over full scale keeps its level through the A11 clip gain.
- `AVAudioFile.length` equals the decoded frames also for a VBR MP3 with no Xing tag (probe on macOS 15.7.9), so the import reads to `length`, as finalize does.
- A crash during an import can leave `.<stem>.wav.tmp` in `Clips/`. The next open of the package under its lock (`Studio.open` and the CLI edits) deletes it, unless a pool file names it.

## Alternatives considered

- A background job, as an export: edits go on during the conversion, but the end then needs a merge rule for a target track that an edit removed, and `Studio.swift` a new stored job.
- A reference to the source file: a moved or deleted source is a missing clip.
- `ExtAudioFile` with a client format at the session rate: one call for decode and rate, but a second converter with a different quality and no A11 pass.
- A `Clips/Imported/` folder: no clash with take names, but the lane label then shows the folder.
- Two undo entries, as a take (0031): the clip inspector resets a gain now, so a second entry gives nothing.
