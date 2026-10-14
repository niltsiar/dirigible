# 0055. Transcripts: words anchored to audio files, stored in session.xml version 8

- Status: accepted
- Date: 2026-10-13
- Accepted: 2026-10-14, after plan gates 1 and 2 of run `2026-10-13-transcript-1` and its save bench.
- Amends: 0003 (the `<transcripts>` element), 0024 (version 8 and its formats row), 0042 (an excerpt carries the words of its files), 0047 (a removed file takes its words), 0011 (the `transcript` commands), 0041 (three tools), 0051 (the `cut-from-transcript` recipe).

## Context

F27 (R7, R10) and a tester request (2026-10-13): an agent edits a podcast with an external transcript. Whisper JSON gives word times in 0.01 s steps; WebVTT gives cues. Final Cut Pro and Premiere attach a transcript to the source media, so the words follow each clip edit. Hindenburg selects whole words and cuts audio from text. Premiere ripples the sequence on a text delete (`.scratchpads/research/transcript-1/findings.md`).

The session has five holders that a new datum must fit: the atomic save of `session.xml`, the backups (only `session.xml` bytes, 0043), the undo snapshots of whole `Session` values, the prune of 0047 through `Session.removeFile`, and the paste of 0042, which makes new `AudioFile` records and keeps the rule "a record of one ID never changes in a session". A probe (run folder `probe/xml-size`) measured 27 000 words (3 h): one XML element per word costs about 0.85 s per autosave with the read-back of `checkedData`; one text node per file costs about 0.14 s.

## Decision

**Model.** A transcript (`TranscriptID`, a number from 1 that the session gives) holds words. A word (`WordID`: the transcript and a number that never changes) has one anchor per audio file: a file frame range and a text. The timeline range of a word is computed: a word shows under each clip, on any track, whose file range (`clip.offset ..< clip.offset + clip.length`, not the crossfade handles) holds the word midpoint. Its timeline range is clamped to that clip. A `WordOccurrence` (the word, the file start frame of its anchor, and the clip; text `<transcript>.<number>.<file start>@<clip id>`) names one place on the timeline; a duplicated clip shows its words twice, as two occurrences. An occurrence is valid until an edit removes it; a stale one (also one whose anchor now starts at another frame, after a replace that gave the transcript number again) is refused, never moved to another word. The file start check guards a replace; it does not guard every reuse of a number (a replace with the same start frames names the same audio).

**Limit.** The words follow only the clips of the files of the import track. A clip edit on one other track does not move them; the guide and the agent manual say: edit all tracks together. Anchors under every track of a mix transcript need no format change (the store is per file) and are later work.

**Import.** `TranscriptFile` (DirigibleCore, Foundation only) reads the format from the content (`WEBVTT` after an optional BOM, else JSON), from a file, stdin, or the `text` argument of the tool. It parses Whisper JSON (`segments[].words[]` with `word` and optional `start` and `end`; a segment with no words is one unit; a top-level `words` array) and WebVTT (one unit per cue, tags removed). `Session.importTranscript(_:name:track:at:)` first drops each unit with no usable time (none, as WhisperX leaves an unaligned word; end before start; negative; not finite; past `Frames.limit`) and counts it; the file is refused only when no usable unit is left. It maps each usable unit: its number is its index among the usable units, from 1; frame = round(seconds x session rate) + at; the clip of `track` under the midpoint gives the file and the file frames; a unit with no clip is skipped and counted, and its number is used up. A text import is at most 256 KiB, below the line limit of the app server; a path and stdin have no cap of their own. A text or stdin import is named `transcript`, or the optional `name`. For each file that it anchors, the import first drops the old anchors whose midpoint is inside the span of the new anchors in that file.

**Cut.** `Session.cutWords(_:)` sorts the shown words of all tracks by start. A run is a sequence of the named words with no other shown word of any track between them, and in one transcript with a next number that is the same or one more (so a word skipped for no clip breaks a run; the occurrences of one word at one timeline start, as after split stereo, count as one step). Limit: the ripple delete merges touching ranges, so a skipped unit splits a cut only when frames separate its neighbours; with no frame between them, no audio of another place is there. Each run is one range from its first start to its largest end. One call of the multi-range `rippleDelete(ranges, on:)` with the list of all tracks cuts all tracks (an empty list changes nothing): one edit, one undo step.

**Storage.** `session.xml` version 8, after `<episode>`, only when a transcript exists (0024 P6):

```xml
<transcripts>
  <transcript id="1" name="episode.json">
    <words file="take1-host">12 288000 308160 Welcome
13 312000 324000 to</words>
  </transcript>
</transcripts>
```

One `<words>` element per file, one line per anchor (`number start end text`, split at the first three spaces), sorted by transcript ID, file ID, midpoint, and number. The anchor list type owns the order: its only init sorts, and each edit makes a new list through it. The text has no line break and no control character (`checkText`).

**Other edits.** `removeFile` drops the anchors of its file and a transcript with no anchor left, so the prune and its undo-entry strip need no new code. A paste across packages carries the anchors of each file in the excerpt, re-keyed to the new records and scaled with the rate rule of `Excerpt.resampled`; a paste adds the anchors of each new file that no transcript anchors; each source transcript gets a new `TranscriptID` in the target and keeps its name, so a paste never merges two transcripts. Each edit that makes a new file from an old one copies the anchors of the source span to the new file with the same `WordID`, as it copies `capture`. No such edit is on main when this record lands. Split stereo and render add the copy in their own runs, each with a test that the words stay and a test `copyKeepsOneAnchorPerFile`.

**Surface (0011, 0041).** `dirigible transcript import <package> <file or -> --track <id> [--at <frame>] [--name <name>]` (`-` reads stdin), `dirigible transcript words <package> [--from <frame> --to <frame>] [--match <text>] [--track <id>] [--limit <n>] [--json]` (one row per word: occurrence, start, end, track, and text, with a tab between them; default limit 200, then a line with the count of the rest), `dirigible transcript cut <package> <occurrence>...`. Tools `transcript_import` (exactly one of `path` and `text`, `text` at most 256 KiB; optional `name`), `transcript_words`, `transcript_cut`, with the same texts.

### Persisted-format refusals

| The reader refuses | Error | The type or edit that makes it impossible | Test (edit, save, read) |
|---|---|---|---|
| `<transcripts>` in a file of version 7 or lower | `invalidValue(transcripts, version)` | `fileVersion` returns 8 when a transcript exists | `transcriptsInVersion7AreRefused`, `aTranscriptWritesVersion8` |
| A transcript `id` that is not an integer of 1 or more, or two of one ID | `invalidValue` / `duplicateID` | `TranscriptID` has no public init; the session gives max + 1; the store is a dictionary | `importNumbersTranscriptsFromOne`, `numbersAndIDsAreChecked` |
| A `<words>` element of a file that is not in the pool | `unknownFile` | import anchors only clip files; `removeFile` drops the anchors; paste and the anchor copy add only anchors of added files | `unknownFileIsRefused`, `pruneDropsTheWordsOfARemovedFile` |
| Two `<words>` elements of one file in one transcript | `duplicateID` | the store is `[FileID: Anchors]` | `oneWordsElementPerFile` |
| A line with fewer than four fields, or a field that is not an integer | `invalidValue(words, line)` | the writer makes each line from typed values | `malformedLineIsRefused` (read only) |
| start below 0, end below start, or end past the file length | `wordOutsideFile` | import clamps to the clip file range; the copy intersects with the span; the paste scale clamps to the new length | `aWordPastTheFileEndIsRefused`, `aWordAtTheFileEndReads` |
| Two anchors of one number in one file | `duplicateID` | import numbers from 1 in order; the copy goes to a new file | `numbersAndIDsAreChecked`; `copyKeepsOneAnchorPerFile` comes with the first copy |
| A number below 1, an empty text, or a text with a control character or a line break | `invalidValue` / `invalidText` | `TranscriptFile` trims, folds white space to one space, and drops empty units | `aTabInAWordBecomesOneSpace`, `ampersandAndTabRoundTrip`, `numbersAndIDsAreChecked` |

The three bump tests of 0024: a version 8 file reads; a session with no transcript writes version 7 or lower; a reader with `newest: 7` refuses version 8 with `unsupportedVersion`.

## Consequences

- Save, backups, undo, the prune, and the undo of an import in the app need no new holder.
- With 27 000 words (3 h), the undo compare of an edit takes 0.014 ms at p90, and `checkedData` with the write takes 173 ms at p90, off the main actor (`TranscriptSaveBenchmark`, optimized; budgets 5 ms and 300 ms). Each backup grows by about 0.9 MB at 3 h.
- A version 7 build refuses a session with a transcript (0024 P3).
- Split stereo shows the words on both new tracks. A word cut on one track ripples all tracks.
- Later parsers (SRT, Podcasting 2.0 JSON, whisper.cpp) give a `TranscriptFile` and need no storage change. Speakers and text corrections need a format change.

## Alternatives considered

- **A reference in `session.xml` and the words in a write-once file in `Transcripts/`** (candidate B). An autosave writes only the reference. It adds a second format, a crash order in two save paths, a load state for a missing file, and orphan files. It is the upgrade path if the autosave cost shows.
- **A sidecar per audio file, no version change** (candidate C). An old build opens the session, but an import is not an undo step, a backup does not keep old words, and each open hashes each file to refuse an orphan.
- **One XML element per word.** About 0.85 s per autosave at 3 h.
- **A field of `AudioFile`.** It breaks the record equality of 0042.
- **A word ID that is an index.** A prune or a copy changes it.
