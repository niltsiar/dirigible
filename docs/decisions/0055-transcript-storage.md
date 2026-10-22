# 0055. Transcripts: words anchored to audio files, stored in a write-once file per transcript

- Status: accepted
- Date: 2026-10-13
- Accepted: 2026-10-14, after plan gates 1 and 2 of run `2026-10-13-transcript-1` and its save bench.
- Changed: 2026-10-14, by the user decision A10 of run `2026-10-13-transcript-1`: the words move from `session.xml` to a write-once file per transcript in `Transcripts/`.
- Amended: 2026-10-23. `TranscriptFile` also reads SRT (see 0061).
- Amends: 0003 (the `<transcripts>` element), 0024 (version 8 and its formats row), 0042 (an excerpt carries the words of its files), 0047 (a removed file takes its words), 0011 (the `transcript` commands), 0041 (three tools), 0051 (the `cut-from-transcript` recipe).

## Context

F27 (R7, R10) and a tester request (2026-10-13): an agent edits a podcast with an external transcript. Whisper JSON gives word times in 0.01 s steps; WebVTT gives cues. Final Cut Pro and Premiere attach a transcript to the source media, so the words follow each clip edit. Hindenburg selects whole words and cuts audio from text. Premiere ripples the sequence on a text delete (`.scratchpads/research/transcript-1/findings.md`).

The session has five holders that a new datum must fit: the atomic save of `session.xml`, the backups (only `session.xml` bytes, 0043), the undo snapshots of whole `Session` values, the prune of 0047 through `Session.removeFile`, and the paste of 0042, which makes new `AudioFile` records and keeps the rule "a record of one ID never changes in a session". A probe (run folder `probe/xml-size`) measured 27 000 words (3 h): one XML element per word costs about 0.85 s per autosave with the read-back of `checkedData`; one text node per file costs about 0.14 s. The user decided on 2026-10-14 (A10) that the words go in a file of their own: `session.xml` does not hold the audio, so it does not hold the words either.

## Decision

**Model.** A transcript (`TranscriptID`, a number from 1 that the session gives) holds words. A word (`WordID`: the transcript and a number that never changes) has one anchor per audio file: a file frame range and a text. The timeline range of a word is computed: a word shows under each clip, on any track, whose file range (`clip.offset ..< clip.offset + clip.length`, not the crossfade handles) holds the word midpoint. Its timeline range is clamped to that clip. A `WordOccurrence` (the word, the file start frame of its anchor, and the clip; text `<transcript>.<number>.<file start>@<clip id>`) names one place on the timeline; a duplicated clip shows its words twice, as two occurrences. An occurrence is valid until an edit removes it; a stale one (also one whose anchor now starts at another frame, after a replace that gave the transcript number again) is refused, never moved to another word. The file start check guards a replace; it does not guard every reuse of a number (a replace with the same start frames names the same audio).

**Limit.** The words follow only the clips of the files of the import track. A region of an import file that the track uses twice shows the words of its first use, also when other tracks differ there. A clip edit on one other track does not move them; the guide and the agent manual say: edit all tracks together. Anchors under every track of a mix transcript need no format change (the store is per file) and are later work.

**Import.** `TranscriptFile` (DirigibleCore, Foundation only) reads the format from the content (`WEBVTT` after an optional BOM is WebVTT, `{` or `[` after white space is JSON, else SRT), from a file, stdin, or the `text` argument of the tool. It parses Whisper JSON (`segments[].words[]` with `word` and optional `start` and `end`; a segment with no words is one unit; a top-level `words` array) WebVTT (one unit per cue, tags removed), and SRT (one unit per cue, tags removed; see 0061). `Session.importTranscript(_:name:track:at:)` first drops each unit with no usable time (none, as WhisperX leaves an unaligned word; end before start; negative; not finite; past `Frames.limit`) and counts it; the file is refused only when no usable unit is left. It maps each usable unit: its number is its index among the usable units, from 1; frame = round(seconds x session rate) + at; the clip of `track` under the midpoint gives the file and the file frames; a unit with no clip is skipped and counted, and its number is used up. A unit over file audio that an earlier clip of the import already gave (a duplicated region) adds no anchor and is counted, so each word anchors once and shows under both clips. A text import is at most 256 KiB, below the line limit of the app server; a path and stdin have no cap of their own. A text or stdin import is named `transcript`, or the optional `name`. For each file that it anchors, the import first drops the old anchors whose midpoint is inside the span of the new anchors in that file. The import takes its new ID before that drop, so a re-import never gives the ID of a transcript that it empties. Limit: the ID is the largest ID plus 1, and `session.xml` keeps no counter, so an undo of an import, or a `removeFile` that empties the transcript with the largest ID, lets a later import take that ID again. A stale token still cannot name a new word at another place: it also holds the file start frame and the clip ID.

**Cut.** `Session.cutWords(_:)` sorts the shown words of all tracks by start. A run is a sequence of the named words with no other shown word of any track between them, and in one transcript with a next number that is the same or one more (so a word skipped for no clip breaks a run; the occurrences of one word at one timeline start, as after split stereo, count as one step). Limit: the ripple delete merges touching ranges, so a skipped unit splits a cut only when frames separate its neighbours; with no frame between them, no audio of another place is there. Each run is one range from its first start to its largest end. One call of the multi-range `rippleDelete(ranges, on:)` with the list of all tracks cuts all tracks (an empty list changes nothing): one edit, one undo step. The cut gives the merged ranges that it removed. A word with no length stays matchable text; a cut drops its empty range, and words with no audio throw `nothingToCut` and change nothing.

**Storage.** `session.xml` version 8 has one reference per transcript, after `<episode>`, only when a transcript exists (0024 P6):

```xml
<transcripts>
  <transcript id="1" name="episode.json" file="<UUID>"/>
</transcripts>
```

The words are in `Transcripts/<file>.xml`, format version 1:

```xml
<transcript xmlns="https://github.com/niltsiar/dirigible/transcript" version="1">
  <words file="take1-host">12 288000 308160 Welcome
13 312000 324000 to</words>
</transcript>
```

One `<words>` element per file ID, sorted by file ID, one line per anchor (`number start end text`, split at the first three spaces), in the order of `Anchors`. The anchor list type owns the order: its only init sorts. The text has no line break and no control character (`checkText`).

The file name is the text of a new UUID. The `Transcript` value makes a new one when its words change, and keeps it when an edit assigns the same words, so each change gives a new file, and a file never changes after its first write. A save writes each named file that has no file of 1 byte or more on disk before the atomic replace of `session.xml`: a temporary file in `Transcripts/`, a full flush, a plain rename, and a flush of the folder. The rename does not use `RENAME_EXCL`, which exFAT does not support (0016, 0019): the name is new, and the write runs under the package lock. `session.xml` keeps each transcript, loaded or not, in one store: a transcript whose file did not load has no words. An autosave with no change of the words writes no transcript file. A crash before the replace leaves an orphan file, and the old `session.xml` names only files that are on disk.

**Open.** The open reads and decodes each file. A file ID that is not in the pool is dropped (a prune while the transcript did not load). A transcript whose file is missing, does not parse, has a newer version, or breaks a rule of the import does not load. The session still opens (the missing-media rule of 0003). The reference stays, and each save writes it again. `transcript words` reports each such transcript. `transcript cut` refuses with `transcriptNotLoaded`, which names each transcript that did not load and says to import it again: a hidden word cannot break a run, so a cut could join across the speech of another speaker. An import takes its new ID first, then drops each transcript that is not loaded and reports it, so a new import clears the state. The open builds each loaded transcript with the name of its reference, so an open and a save with no edit keep the file. A load that drops every word of a transcript removes it. A paste never carries a transcript that did not load.

**Other edits.** `removeFile` drops the anchors of its file and a transcript with no anchor left. The next save writes the pruned words to a new file. The old file stays while a holder names it. Remove Unused Files (0047) lists each file in `Transcripts/` that no holder names: `session.xml` on disk, the session in memory, each readable backup, and the undo and redo entries. It takes only `<canonical UUID>.xml` regular files that stay in `Transcripts/`. A missing `Transcripts/` folder gives no item; another read error stops the scan, as for `Clips/`. The clipboard holds the words in memory, not a file name, so it is not a holder. A paste across packages carries the words in the excerpt; the save of the target writes them to a new file in the target package. A paste across packages carries the anchors of each file in the excerpt, re-keyed to the new records and scaled with the rate rule of `Excerpt.resampled`; a paste adds the anchors of each new file that no transcript anchors; each source transcript gets a new `TranscriptID` in the target and keeps its name, so a paste never merges two transcripts. Each edit that makes a new file from an old one copies the anchors of the source span to the new file with the same `WordID`, as it copies `capture`. No such edit is on main when this record lands. Split stereo and render add the copy in their own runs, each with a test that the words stay and a test `copyKeepsOneAnchorPerFile`.

**Surface (0011, 0041).** `dirigible transcript import <package> <file or -> --track <id> [--at <frame>] [--name <name>]` (`-` reads stdin), `dirigible transcript words <package> [--from <frame> --to <frame>] [--match <text>] [--track <id>] [--limit <n>] [--json]` (one row per word: occurrence, start, end, track, and text, with a tab between them; default limit 200, then a line with the count of the rest), `dirigible transcript cut <package> <occurrence>...`. Tools `transcript_import` (exactly one of `path` and `text`, `text` at most 256 KiB; optional `name`), `transcript_words`, `transcript_cut`, with the same texts.

### Persisted-format refusals

`session.xml`:

| The reader refuses | Error | The type or edit that makes it impossible | Test (edit, save, read) |
|---|---|---|---|
| `<transcripts>` in a file of version 7 or lower | `invalidValue(transcripts, version)` | `fileVersion` returns 8 when a transcript exists, loaded or not | `transcriptsInVersion7AreRefused`, `aTranscriptWritesVersion8` |
| A transcript `id` that is not an integer of 1 or more, or two of one ID (refused by the insert of the reader, once per reference) | `invalidValue` / `duplicateID` | `TranscriptID` has no public init; the session gives max + 1 over its one store, loaded or not | `importNumbersTranscriptsFromOne`, `numbersAndIDsAreChecked` |
| A `file` that is not a canonical UUID text | `invalidValue(transcript, file)` | `TranscriptFileName` is made only from a new `UUID` or from a checked text | `aFileNameWithAPathIsRefused` |

`Transcripts/<file>.xml`: the transcript does not load, the session opens, and the commands report it.

| The file has | Result | The type or edit that makes it impossible | Test |
|---|---|---|---|
| No file, or a read error | not loaded | a save writes each named file before `session.xml`; a 0-byte file at the name is written again | `aMissingTranscriptFileIsReported`, `anEmptyFileAtTheNameIsWrittenAgain` |
| Another root, namespace, or a version above 1 | not loaded | a format change also raises the `session.xml` version (0024 P7) | `aNewerTranscriptFileIsNotLoaded` |
| A malformed line, a number below 1, end before start, an end past the file length, two `<words>` of one file, two anchors of one number in one file, an empty text, a control character, or no `<words>` | not loaded | the writer makes each line from typed values; the import and the paste checks (`checkWords`) | `malformedLineIsNotLoaded`, `aWordPastTheFileEndIsNotLoaded`, `aWordAtTheFileEndLoads`, `oneWordsElementPerFile`, `aTranscriptWithNoWordsIsNotLoaded` |
| A `<words>` of a file that is not in the pool | the words of that file are dropped; the rest loads | `removeFile` drops the anchors of a loaded transcript | `aTranscriptOfARemovedFileStillLoads` |

The three bump tests of 0024: a version 8 file reads; a session with no transcript writes version 7 or lower; a reader with `newest: 7` refuses version 8 with `unsupportedVersion`.

## Consequences

- Undo needs no new holder: each value in the history holds its words, and a file that it names stays until Remove Unused Files finds no holder.
- An autosave of a session with a 27 000-word transcript writes only the reference. A change of the words makes a new name, and its first save encodes, checks, and writes about 0.9 MB once. At 3 h, optimized p90 (`TranscriptSaveBenchmark`, budgets 5 ms and 300 ms): the undo compare of an edit 0.009 ms, an autosave 47 ms, the first save after a change of the words 220 ms, and an open 103 ms. A backup grows by one line per transcript.
- A version 7 build refuses a session with a transcript (0024 P3).
- Split stereo shows the words on both new tracks. A word cut on one track ripples all tracks.
- Later parsers (SRT, Podcasting 2.0 JSON, whisper.cpp) give a `TranscriptFile` and need no storage change. Speakers and text corrections need a format change.

## Alternatives considered

- **The words inline in `session.xml` version 8** (the first accepted form of this record, before A10). It costs about 0.17 s per autosave at 3 h, and each backup holds a copy of the words. The user refused it: `session.xml` does not hold the audio, so it does not hold the words.
- **A file name that is the SHA-256 of the bytes.** It gives a damage check, but DirigibleCore imports only Foundation (0002), and the `didSet` would encode and hash about 0.9 MB at each Copy. Limit of the UUID name: a damaged file that still parses loads, as a damaged `session.xml` or WAV does.
- **A JSON file.** A second parser of the same data.
- **A refusal of the session when a transcript file is missing.** It locks the user out of the audio for a file that a new import makes again (the import drops the transcript that did not load).
- **A sidecar per audio file, no version change** (candidate C). An old build opens the session, but an import is not an undo step, a backup does not keep old words, and each open hashes each file to refuse an orphan.
- **One XML element per word.** About 0.85 s per autosave at 3 h.
- **A field of `AudioFile`.** It breaks the record equality of 0042.
- **A word ID that is an index.** A prune or a copy changes it.
