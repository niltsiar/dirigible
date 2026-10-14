# Dirigible

Dirigible records and edits podcasts. A session holds tracks, clips of audio files, markers, and transcripts.

## Language

### Transcripts

**Transcript**:
The words of an imported Whisper JSON or WebVTT file, with a number that the session gives and a name (decision 0055).
_Avoid_: captions, subtitles

**Transcript file**:
The file in `Transcripts/` that holds the words of a transcript. Its name is a UUID that changes with each change of the words, so a file never changes after its first write (decision 0055).
_Avoid_: sidecar, words file

**Word**:
One unit of a transcript, with a number that never changes and a frame range in each audio file that holds its audio.
_Avoid_: token, segment

**Occurrence**:
One place of a word on the timeline: the word under one clip. A duplicated clip shows its words as two occurrences.
_Avoid_: instance, hit
