# 0053. Split stereo to mono writes two mono files for each run of clips

- Status: accepted
- Date: 2026-10-26
- Accepted: 2026-10-26, after plan gates 1 to 3 of run `2026-10-13-replace-roomtone-split`.
- Amends: 0031 (the Tools menu gets the item Split Stereo to Mono), 0037 (the lane menu gets the item in group 2), 0040 (a split is a blocking run of the import transport), 0049 (`clip_split_stereo` is a sixth long edit tool), 0051 (`clip_split_stereo` is in the tool list only), 0060 (a clip that moves to another file moves its envelope points).
- Reference: `docs/research/hindenburg-edit-tools.md`, `logic-audition-edits.md`, and `audacity-soundcraft.md`.

## Context

Hindenburg PRO is the base behavior. Its Split Stereo makes a left and a right region from one stereo region [HM]. Audition writes `Name_L` and `Name_R` files. Audacity has Split Stereo to Mono.

A clip has no channel field, and a clip file layout must equal its track layout (0003). So a mono clip of one side of a stereo file needs a new mono file, or a new clip field that picks a channel (a session version raise). This is a one-way choice.

## Decision

- **Split stereo writes two mono files for each run.** A run is the clips of one source file whose written spans touch or overlap. The written span of a clip is its span plus a handle of 10 s on each side, or half the crossfade at that edge when it is longer, capped at the file edges (`Session.clipRuns(of:)`, 0056). For each run, the split writes the union of its written spans as two mono 24-bit WAVs in `Clips/`. The stems follow the one stem rule of the new-file batch of import, paste, and render: `<stem> L` and `<stem> R`, and `<stem> L 2` and `<stem> R 2` for a second run of one file. So seamless neighbours share a pair and stay seamless, and a split writes at most the source length for each side. Pro Tools and Final Cut Pro consolidate with handles in the same way.
- **The Core edit is `Session.splitStereo(_:names:)`.** It takes the runs with the stems of their files, and it is a pure session edit that throws before any caller writes a file. It checks that each run is the run that `clipRuns(of:)` gives for its clips, and it throws `.notStereo(ClipID)` for a clip on a mono track. It adds each pair file with `addDerivedFile`, with layout mono. A throw changes nothing.
- **The new clips.** Each source clip gives a left clip and a right clip with the same start, length, gain, and fades. The offset is the old offset minus the start of the run. The clip IDs are `<id> L` and `<id> R`, then ` 2`, ` 3` when taken. The IDs keep `L` and `R` in every language, because an ID is not UI text. A crossfade between two split clips stays on both new tracks, inside the handle (0036). A crossfade whose partner was not split goes, on the new clip and on the clip that stays. The source clips go. The source track and the source file stay.
- **The new tracks.** Two mono tracks go directly under each source track, left first. They copy the gain, mute, solo, and role of the source track, and have no route. The caller gives the name suffixes. The window uses the suffixes of its UI language ("L" and "R" in English, "I" and "D" in Spanish). A split from an agent or a `dirigible` command names the tracks "<name> L" and "<name> R" in every language.
- **The envelope keeps its gain.** The envelope is a function of file frames (0060), and a clip now plays another file. So each new clip takes the points of its source clip with each frame moved by the start of the run, with the edge rule of 0060: a point outside the new file is dropped, and an edge that lost a point beyond it gets a point with the gain of the source function there. At each frame of the pair, the new envelope gives the gain of the source envelope at the same source frame. Heal (0060) then joins two split parts on a new track exactly when it joined the two source clips.
- **The pair files keep the capture.** Each pair file copies the `capture` of its source file, with the transcript words of the run span (`addDerivedFile`). So a take stays placed after Remove Unused Files trashes the source WAV, and `removeCapture` refuses while a pair file names the capture. After a split, `capture` means "the take that recorded the audio of this file", not "the file is the whole segment".
- **No take time.** A pair file has no take origin (0061), so Go to Take Time, `take map`, and a transcript import with `--take` skip a split clip.
- **The pick is typed.** `Side` (`.left`, `.right`) is the channel pick of `ClipConversion`. A stereo input into one channel with a pick takes only that channel; with no pick it folds 0.5 L + 0.5 R (0040).
- **The split is a blocking run.** It uses the import transport (`ImportRun.Kind.split`): `.busy` during a take, the banner after 0.5 s, Cancel, the take yield, and one undo entry. Its order: one space check, the stems of each side, the Core split on a copy of the session, the temporary files, a check that each written length equals its run span, then the renames, one flush of `Clips/`, and one save. So a refusal of the session edit (a transcript that did not load, a mono clip) writes no file. The progress rises with the frames written and reaches 1 only at the end of the last side. A split error has its own type (`SplitError`), so no split text names an import. Undo keeps the WAVs as unused files (0047 holds them while a redo entry names them).

## Consequences

- No session version change. A split keeps `fileVersion`, except when a crossfade whose partner was not split goes. A session after a split opens in each older build that reads its version.
- A split writes the merged spans with their handles: a 10 s clip in the middle of a long file writes 30 s for each side, and a dense edit writes at most the source length for each side. A 2 h clip at 48 kHz writes 2.07 GB and needs that much plus the 1 GB margin of free space.
- Each split writes a new pair, also a split after Undo: no split uses the pair files of an undone split again. So each retry writes its runs again. Remove Unused Files frees the pair files of an undone split when no redo entry and no backup names them (0047).
- A trim can extend a new clip up to the edges of its pair file: at least its 10 s handle, and more for a clip inside a run. A longer extension needs the source clip (Undo).
- A voice that was on one side plays in the center after the split, because a mono clip plays on both channels. A mono export of a one-side voice gets 6 dB louder (0.5 L before, L after). The split changes no gain.
- Each later reader of clip audio (stems, render through an effect, EQ) reads a mono file and needs no channel rule.

## Alternatives considered

- **A channel field on the clip** (`<clip channel="left|right"/>`, version 8). No write and an instant split, but every reader of clip audio must honor the pick (the mix, the peak cache with a new cache version, Auto Level, loudness, and each later DSP reader), and a missed reader plays or measures the wrong voice with no error. Rejected.
- **Write the whole source file once for each side.** It keeps all of the media, but a 10 s clip of a 2 h take writes 2.07 GB. Rejected.
- **One pair for each clip.** Each seamless cut becomes a butt join (0036 then refuses a crossfade there, and Command-F can add a bump), and a dense edit writes more than the whole file. Rejected.
- **Write only the clip span with no handle.** It loses each crossfade at the clip edges (0036 needs media past the edge), which is user work. Rejected.
