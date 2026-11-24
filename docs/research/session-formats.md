# Session file formats

Date: 2026-09-23

## Scope

This document answers the open question "What is the XML schema of a session?" in `docs/requirements/brief.md`. It covers R5 (a session saves an XML file that describes the tracks and the clips) and R6 (each clip is a WAV or FLAC file in its own folder).

The user guidance: use our own format, because it can follow our features, unless a strong open format already fits. Check the open formats first. An open format can still be an import or export target.

For each format, this document records:

- What the format is and what it models: tracks, clips, source offsets, gain, fades, envelopes, markers, per-clip effects, and capture timing (host time and sample time per device).
- The encoding (XML or not), the license, and the tooling for Swift.
- The fit as the native session file (R5), and the fit as an import or export target.

Claims that this research did not confirm in a primary source have the mark "(unconfirmed)".

## AES31-3 (Audio Decision List, ADL)

- **What it is.** An AES standard for project interchange between DAWs, first published in 1999. AES31-2 sets the audio files (Broadcast WAV). AES31-3 sets the edit list, the ADL.
- **Encoding.** Plain ASCII text in the Edit Decision Markup Language (EDML). Sections use XML-style tags (`<VERSION>`, `<PROJECT>`, `<SOURCE_INDEX>`, `<EVENT_LIST>`). The keywords inside a section are in parentheses. It is not well-formed XML. An event line looks like `(Entry) 0001 (Cut) F "tr01.wav" 1 1 00.00.00.00|0000 00.00.01.00|0000 00.01.00.00|1152` (BBC aes31-adl-composer).
- **What it models.** A source index (file references), events that put a source range on a track at a timeline position, fades, and simple gain and pan automation. Time is timecode plus a sample count, so it is sample-accurate within 24 hours. No per-clip effects. No capture timing per device.
- **AES31-4 (2024).** An XML implementation of the ADL (AES Standards blog). The standard text is behind the AES paywall. Its element names were not checked (unconfirmed).
- **Tooling.** No Swift library. The text grammar is small, so a writer is a few hundred lines. Steinberg WaveLab reads and writes it ("retaining time positions of events, fades"). SADiE and Pyramix read it (unconfirmed for Pyramix).
- **Fit for R5.** Poor. It is not XML (AES31-3), and AES31-4 is paywalled. It has no place for capture timing, effects, or app state. We cannot extend a standard.
- **Fit as export target.** Good. It is audio-first, sample-accurate, and carries fades and gain. Broadcast DAWs import it.

## OpenTimelineIO (OTIO)

- **What it is.** An editorial timeline interchange format and library from the Academy Software Foundation. License Apache-2.0. The main repo is active (last push 2026-09-22).
- **Encoding.** JSON (`.otio`), not XML. `.otioz` and `.otiod` bundle the media.
- **What it models.** `Timeline` > `Stack` > `Track` (`kind` Video or Audio) > `Clip`, `Gap`, `Transition`. A clip has a `source_range` (start and duration as `RationalTime`, value and rate) and one or more `media_references` (`ExternalReference` with `target_url` and `available_range`). `Marker` has `marked_range`, `color`, `comment`. `Effect` has only `effect_name` and `enabled`. The only schema effects are `LinearTimeWarp` and `FreezeFrame`. There is no schema for audio gain, fades, or envelopes. Every object has a free `metadata` dictionary.
- **Timing.** `RationalTime` with rate 48000 is sample-accurate. Capture timing fits only in `metadata`.
- **Tooling.** C++ core with Python bindings. Swift bindings exist (`OpenTimelineIO/OpenTimelineIO-Swift-Bindings`, Apache-2.0, SwiftPM with a hybrid C++ build, last push 2026-03-10). The project says: use the library, do not write your own parser. Adapters to AAF, FCP XML, and CMX 3600 EDL are now separate Python plugins.
- **Fit for R5.** Poor. It is JSON, not XML. Gain, fades, and envelopes would go into untyped `metadata`. A C++ dependency needs a decision record for a format that does not model our audio features.
- **Fit as export target.** Fair. It is good for video and NLE pipelines. Most podcast DAWs do not read it (unconfirmed).

## AAF (Advanced Authoring Format)

- **What it is.** A post-production interchange format from the AAF Association, now AMWA. Specs MS-01 (data model), MS-02 and MS-03 (Structured Storage mapping), AS-01 (Edit Protocol).
- **Encoding.** Binary Microsoft Structured Storage. The SDK also has an XML stored format, but tools rarely use it (unconfirmed).
- **What it models.** Nearly everything: mobs (composition, master, source), tracks, source clips with offsets, fades, gain and pan automation, effects, markers (comments), embedded or linked essence.
- **Tooling.** The AAF SDK is a large C++ library under an open-source license (AAF SDK Public Source License). No Swift wrapper. Pro Tools and Media Composer use AAF as the main interchange. Logic Pro and DaVinci Resolve import it (unconfirmed for Logic Pro).
- **Fit for R5.** None. It is binary, very complex, and needs a large C++ dependency.
- **Fit as export target.** Good for Pro Tools users, but costly. Consider it only when a user asks for Pro Tools handoff.

## FCPXML (Final Cut Pro XML)

- **What it is.** Apple's interchange format for Final Cut Pro. It has a DTD for each version (1.10 and later on developer.apple.com). A `.fcpxmld` bundle is also possible.
- **Encoding.** XML with a public DTD. Time is rational seconds, for example `1001/30000s`.
- **What it models.** `resources` (`format`, `asset`, `effect`), `library` > `event` > `project` > `sequence` > `spine`. Clips are `asset-clip`, `clip`, `audio`, with `offset`, `start`, `duration`, and `lane`. Audio has `adjust-volume` with `param`, `fadeIn`, `fadeOut`, and `keyframeAnimation`. It also has `audio-channel-source`, `filter-audio`, `marker`, `chapter-marker`, and roles.
- **Tooling.** No Apple parser library. Foundation `XMLDocument` can read and write it and validate against the DTD.
- **Fit for R5.** Poor. It is video-first: a sequence needs a video `format`, and the spine, lanes, and connected clips do not match a track-based audio editor. The schema belongs to Apple and changes with each Final Cut Pro release.
- **Fit as export target.** Fair. It is useful for users who finish a video podcast in Final Cut Pro. It maps tracks to lanes and roles.

## Hindenburg session (.nhsx)

- **What it is.** The session file of Hindenburg (PRO, Journalist). It is the model for R5. Hindenburg does not publish the format. The best reference is a reverse-engineered field guide with measured renders against Hindenburg PRO 2.05.2718 (`ollisulopuisto/podcast`, `docs/hindenburg-nhsx-format.md`).
- **Encoding.** Plain UTF-8 XML. Some exports have an XML namespace and some do not, so parse by local name.
- **Real structure** (from the field guide):

```xml
<Session Version="Hindenburg PRO 2.05.2718" Samplerate="48000" Time="01:51.157">
  <AudioPool Path="h-test Files" Location="/Users/USER/Downloads">
    <File Id="1" Name="A1_level_m20.wav" Duration="05.000" Leq="-">
      <MetaData OriginalPath="/Users/USER/Downloads/test_signals/file_a_laws/A1_level_m20.wav"/>
    </File>
  </AudioPool>
  <Tracks>
    <Track Name="A4" Pan="-0.25">
      <Region Ref="4" Name="A4_pan_0.625" Start="30.200" Length="05.000"/>
    </Track>
  </Tracks>
  <Clipboard><Group/><Group/><Group/><Group/></Clipboard>
  <Markers><Marker Id="1" Name="Sisään" Time="01:02.500"/></Markers>
</Session>
```

- **What it models.** An audio pool of files (`AudioPool/@Path` is relative to the session file). Tracks with `Volume` (dB), `Pan`, and `Muted`. Regions with `Ref`, `Start`, `Length`, `Offset` (position in the source file), `Gain` (dB), `ClipGain`, `Muted`, and `FadeIn`/`FadeOut` attributes. `<Fade Start Length Gain>` children in a region are raised-cosine ramps to a level, which is how Hindenburg stores the volume envelope. Markers have `Id`, `Name`, `Time`, and optional `Type="Chapter"` and `URL` (eteubert/podcast-chapter-parser-hindenburg). Words of a transcription can be in a file.
- **Weak points.** Times are decimal-second strings in three shapes (`05.000`, `MM:SS.mmm`, `HH:MM:SS.mmm`), so positions are not sample-exact. Zero values are left out. Two gain spellings and two fade spellings exist. There is no capture timing per device. Effects and automation were not seen in real files.
- **Tooling.** Python and JavaScript parsers on GitHub. No Swift parser.
- **Fit for R5.** Do not copy it. It is closed, it is not sample-exact, and it changes without notice. Its shape (pool of files, tracks, regions with offset, markers) is a good model for our own format.
- **Fit as import target.** Good for later. Users who move from Hindenburg can open old sessions. Treat it as best effort.

## Audacity project (.aup3)

- **What it is.** The project file of Audacity 3.
- **Encoding.** An SQLite 3 database. The project document is binary XML in a blob in the `project` table (and the `autosave` table). The audio is in the `sampleblocks` table, not in separate files. `audacity/audacity-project-tools` extracts the XML as text.
- **Fit for R5.** None. It breaks R6 (clips in their own folder as WAV or FLAC), and the XML is binary.
- **Fit as import target.** Low. Only if users ask.

## REAPER project (.rpp)

- **What it is.** The project file of REAPER. Cockos does not publish a spec. ReaTeam keeps community state-chunk docs.
- **Encoding.** Plain text chunks in `<TAG ... >` blocks with space-separated tokens. It is not XML.
- **What it models.** `ITEM` with `POSITION` and `LENGTH` (seconds), `SOFFS` (slip offset in the source), `VOLPAN`, `FADEIN`/`FADEOUT`, `<SOURCE WAVE FILE "...">`, take envelopes, FX chains. Times are floating-point seconds.
- **Fit for R5.** None. It is not XML and not documented by the vendor.
- **Fit as export target.** Low. REAPER users can import AES31 (unconfirmed) or plain files.

## Comparison

| Format | Encoding | Tracks, clips, offsets | Gain, fades, envelopes | Markers | Effects | Capture timing | Swift tooling | R5 native | Import or export |
|---|---|---|---|---|---|---|---|---|---|
| AES31-3 ADL | EDML text | Yes, sample-accurate | Gain, fades, simple automation | Yes (unconfirmed) | No | No | None, small writer | No | Export: good |
| AES31-4 | XML | Yes (unconfirmed) | Yes (unconfirmed) | Unconfirmed | No (unconfirmed) | No | None | No, paywalled | Watch |
| OTIO | JSON | Yes, rational time | Only in `metadata` | Yes | Name only | Only in `metadata` | C++ Swift bindings | No | Export: fair |
| AAF | Binary | Yes | Yes | Yes | Yes | No | C++ SDK only | No | Export: costly |
| FCPXML | XML + DTD | Spine and lanes | Yes | Yes, chapters | Yes | No | `XMLDocument` | No | Export: fair |
| Hindenburg .nhsx | XML | Yes, decimal seconds | Yes | Yes, chapters | Not seen | No | None | Model only | Import: later |
| Audacity .aup3 | SQLite, binary XML | Yes | Yes | Labels | Yes | No | None | No | Low |
| REAPER .rpp | Text chunks | Yes, float seconds | Yes | Yes | Yes | No | None | No | Low |

No open format stores capture timing per device (host time and sample time). No open XML format fits a track-based audio editor without video concepts or a paywall.

## Recommendation

Use our own XML format for the native session file. No open format is strong enough to replace it. We own the schema, so it follows our features, starting with capture timing.

### File layout

- `<Name>.dirigible` is the session XML file. The file extension is a proposal.
- `<Name> Clips/` is the clips folder, next to the session file. It holds the WAV or FLAC files (R6).
- A clip refers to a file by a path relative to the clips folder. Never store absolute paths, so the user can move the session folder.

Update 2026-09-23: decision 0003 makes the session a document package, `<Name>.dirigible/`, with `session.xml` and `Clips/` inside. Finder then moves the XML and its clips as one item.

### Rules for Release 1

- All positions and lengths are integer sample frames at the session sample rate. No decimal seconds, so the file is lossless and exact.
- A file in the pool has the session sample rate. Import converts other rates.
- Gain is in dB as a decimal number. Zero values are written, not left out.
- A `<file>` element holds the audio file. A `<capture>` child holds the timing of the device that recorded it. An imported file has no `<capture>` element.
- Host time is in nanoseconds (convert from `mach_absolute_time` ticks at capture). It is valid only inside one boot, and that is enough to align the tracks of one take.
- `measuredSampleRate` is the rate that the app measured over the take (sample-time delta divided by host-time delta). The track alignment design uses it to correct drift.
- Save atomically: write the full document to a temporary file and replace the old file (`Data.write(to:options: .atomic)`).

### Example

```xml
<?xml version="1.0" encoding="UTF-8"?>
<session xmlns="https://github.com/niltsiar/dirigible/session" version="1"
         sampleRate="48000" clipsFolder="Episode 12 Clips">
  <files>
    <file id="f1" path="Host 001.flac" channels="1" length="2880000">
      <capture deviceUID="BuiltInMicrophoneDevice" deviceName="MacBook Pro Microphone"
               hostTimeNanos="815224377120000" sampleTime="0"
               nominalSampleRate="48000" measuredSampleRate="48000.412"/>
    </file>
    <file id="f2" path="Guest 001.flac" channels="1" length="2879500">
      <capture deviceUID="AppleUSBAudioEngine:Shure:MV7:1" deviceName="Shure MV7"
               hostTimeNanos="815224391870000" sampleTime="512"
               nominalSampleRate="48000" measuredSampleRate="47999.087"/>
    </file>
    <file id="f3" path="Intro music.wav" channels="2" length="720000"/>
  </files>
  <tracks>
    <track id="t1" name="Host" gain="0.0">
      <clip id="c1" file="f1" start="0" offset="0" length="1440000" gain="0.0"/>
      <clip id="c2" file="f1" start="1488000" offset="1536000" length="1344000" gain="-1.5"/>
    </track>
    <track id="t2" name="Guest" gain="0.0">
      <clip id="c3" file="f2" start="708" offset="0" length="2879500" gain="2.0"/>
    </track>
    <track id="t3" name="Music" gain="-6.0">
      <clip id="c4" file="f3" start="0" offset="0" length="720000" gain="0.0"/>
    </track>
  </tracks>
  <markers>
    <marker id="m1" name="Intro" position="0" kind="chapter"/>
    <marker id="m2" name="Guest joins" position="1488000" kind="marker"/>
  </markers>
</session>
```

### Versioning

- `version` is an integer. Release 1 wrote `version="1"`. State on 2026-11-24: the writer writes version 21 (`binSessionVersion` in `Sources/DirigibleCore/SessionWriter.swift`; decisions 0003 and 0024 hold the versions).
- The reader opens every version that it knows. It refuses a higher version with a clear error. It does not open the file read-write.
- Increase the version for each new element or attribute that carries user data. Reason: an old app that skips an unknown element and then saves the file deletes that data. This is data loss.
- The version must allow these additions later:
  - Fades on a clip: `<fade kind="in|out" length="..." curve="..."/>`.
  - Gain envelopes on a clip or a track: `<envelope>` with `<point position="..." gain="..."/>`.
  - Per-clip and per-track effects (noise reduction R8, auto-level R9): `<effect type="..." enabled="...">` with parameters.
  - Track pan, mute, and solo. Clip names, colors, and mute.
  - Chapter metadata (title, URL, artwork) on markers.
  - Loudness analysis per file (the Hindenburg `Leq` role).

### XML in Foundation

- `XMLParser` (SAX) is in Foundation on all Apple platforms. `XMLDocument` and `XMLElement` (DOM, XPath, DTD validation) are in Foundation on macOS only. Dirigible runs only on macOS, so both are available.
- Use `XMLDocument` to write (it escapes text and attributes) and `XMLDocument` or `XMLParser` to read. The session model stays in the domain module. Parse the XML into domain types at the boundary, in its own target, so the domain module keeps its Foundation-only imports.

Update 2026-09-23: decision 0002 keeps the XML code in `DirigibleCore`, next to the model, because `XMLDocument` is Foundation. Decision 0003 adds attributes that the example below does not show: track `layout` and route, one `<capture id>` per device segment, `resampledFromRate`, `driftCorrected`, and the `<recording>` element.
- No third-party dependency is necessary.

### Open formats as targets

- State on 2026-11-24: this order never landed. AES31-3 export is deferred (F67 is Later in `docs/requirements/features.md`).
- **Export first: AES31-3 ADL.** It is the audio-first, sample-accurate DAW standard with fades and gain, and a writer is small plain text with no dependency.
- Export later: FCPXML for video podcasts in Final Cut Pro, then OTIO if a user needs an NLE pipeline.
- Import later: Hindenburg `.nhsx`, best effort, for users who move from Hindenburg.
- Skip for now: AAF (needs a large C++ SDK), `.aup3`, `.rpp`.

## Sources

- AES31, Wikipedia: https://en.wikipedia.org/wiki/AES31
- AES31-4-2024 XML Implementation of Audio Edit Decision Lists, AES Standards blog: http://www.aes.org/standards/blog/2024/9/aes31-4-2024-xml-implementation-of-audio
- AES31-3 standard listing: https://www.intertekinform.com/en-gb/standards/aes-31-3-2008-r2013--34087_saig_aes_aes_76776/
- BBC aes31-adl-composer (ADL writer and examples): https://github.com/bbc/aes31-adl-composer
- Steinberg WaveLab, AES-31 export and import: https://archive.steinberg.help/wavelab_pro/v10/en/wavelab/topics/audio_montage/audio_montage_aes_31_export_import_c.html
- OTIO file format specification: https://opentimelineio.readthedocs.io/en/latest/tutorials/otio-file-format-specification.html
- OTIO serialized schema: https://opentimelineio.readthedocs.io/en/latest/tutorials/otio-serialized-schema.html
- OTIO repository: https://github.com/AcademySoftwareFoundation/OpenTimelineIO
- OTIO Swift bindings: https://github.com/OpenTimelineIO/OpenTimelineIO-Swift-Bindings
- AAF, Wikipedia: https://en.wikipedia.org/wiki/Advanced_Authoring_Format
- AMWA AAF Edit Protocol (AS-01): https://static.amwa.tv/as-01-aaf-edit-protocol-spec.pdf
- AMWA AAF Stored Format (MS-02): https://static.amwa.tv/ms-02-aaf-stored-format-spec.pdf
- AAF SDK: https://aaf.sourceforge.net/
- FCPXML reference, Apple: https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference
- FCPXML 1.8 DTD (copy in CommandPost): https://github.com/CommandPost/CommandPost/blob/develop/src/extensions/cp/apple/fcpxml/dtd/FCPXMLv1_8.dtd
- Hindenburg .nhsx field guide: https://github.com/ollisulopuisto/podcast/blob/main/docs/hindenburg-nhsx-format.md
- Hindenburg chapter parser (marker sample): https://github.com/eteubert/podcast-chapter-parser-hindenburg
- Audacity project tools (.aup3 structure): https://github.com/audacity/audacity-project-tools
- REAPER state chunk definitions, ReaTeam: https://github.com/ReaTeam/Doc
- REAPER RPP parser, Python: https://github.com/Perlence/rpp
