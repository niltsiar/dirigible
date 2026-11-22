# 0075. Import Session: one paste of a whole-session excerpt into new tracks, at the source positions plus an offset

- Status: accepted
- Date: 2026-10-28
- Accepted: 2026-11-22, after the plan gates (3 rounds) of run `2026-10-28-import-session`.
- Amends: 0002 (Folders: `Import/` holds the session import), 0011 (CLI parity: `import-session`), 0040 (`ImportRun.Kind.session`), 0042 (a second caller of `pasteClipboard`), 0049 (`import_session` is a long tool with progress and cancel), 0079 (`openChecked` is in `Import/CheckedOpen.swift`, shared with the session import).

## Context

F151 (Release 7 item 4, R7): two people record one conversation apart, on two Macs with no link between the apps. One sends the full package. The editor merges it into the open session. Hindenburg PRO has "Import Session Into Session" and documents only "Import an entire session into current session"; Pro Tools Import Session Data adds new tracks, places them at the original positions or at a mapped start plus an offset, converts another rate, and imports markers as an option (`docs/research/import-session.md`).

Facts that fix the design:

- The package stores host times of one boot (`Capture.hostTimeNanos`, `Recording.takeStartHostTimeNanos`, 0004 Timing) and no wall clock. So the source capture times give no start on the target timeline. The only rough start is the position of each clip on the source timeline. A probe of run `2026-10-28-import-session` found that the mtime of a package file survives `ditto`, zip, and tar, and the birth time does not.
- 0042 makes `pasteClipboard` the one function that copies files between packages: stems, conversion at another rate, one space check, `NewClipFiles`, read-back, renames.
- `Session.excerpt(of:on:)` carries the clips with their gain, fades, crossfades, envelope, ride points, and transcript words, but not the track gain, role, mute, follow flag (0073), voice match (0074), or the markers. A paste into another package copies a file with no drift link (0077).
- A received package is untrusted. `Session(contentsOf:)` refuses a package item that is a link or not of its kind, and a package XML file with a DTD, another encoding, or a nesting over 64 levels (0003 Rules, Amended 2026-11-16). The template copy checks each file that it copies with `openChecked`: an `openat` with no link at any component and no wait, then a regular file (0079). 0003 lets an entry of `Clips/` be a link to a regular file or a folder, and `pasteClipboard` copies the target of such a link (`PasteClipboard.swift`).
- A `PackageLock` open creates `<package>/.lock` (0012).

## Usage sketch

```swift
// DirigibleAudio/Import/SessionImport.swift
public enum SessionImportError: Error, Hashable, Sendable {
    /// `at` outside -2^40...2^40, refused before any read or arithmetic.
    case offsetOutOfRange(Int)
    /// A target session rate outside 8000...384000 Hz.
    case targetSampleRateOutOfRange(Int)
    /// A source rate outside 8000...384000 Hz.
    case sampleRateOutOfRange(Int)
    case sameSession, takeNotFinalized, nothingToImport
    /// The read of the source package fails.
    case source(SessionFileError)
    /// A named source file in Clips/ with a link at a component of its path, or not a regular file.
    case unsafeFile(String)
    case paste(PasteError)
}

public struct SessionImported: Sendable {
    public let session: Session      // the edited copy; the caller saves it
    public let tracks: [TrackID]     // the new tracks, in source order
    public let markers: [MarkerID]
    public let leftOutMarkers: Int   // markers under frame 0 or over 2^40 after the offset
    public let mutedCallTracks: Int  // the new tracks that the .app route rule muted
    public let made: [URL]           // the renamed WAVs; the caller removes them at a cancel before the save (0049)
}

/// Checks `at`, reads `source`, cuts its head for a negative `at`, checks the named files and the
/// marker list, pastes one excerpt of all its tracks into new last tracks at max(0, at), then runs
/// only setters that cannot fail: the names, the track gain, role, mute, follow flag, and voice
/// match. A source track with an .app route imports muted. The checked markers go in before the paste.
/// Never writes session.xml and writes nothing in `source`. Blocks: never on the main actor.
public func importSession(
    from source: URL, into session: Session, in package: URL, identity: PackageID?,
    at: Int, markers: Bool, freeBytes: () -> Int64,
    progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }
) throws(SessionImportError) -> SessionImported

// Callers
// CLI and closed MCP: ImportSessionWork.run(&session, lock:, package:) inside editPackageCore;
//   exit 64 for .offsetOutOfRange; exit 1 for .sameSession, .nothingToImport, and .paste(.session);
//   exit 2 for each other case; a cancel before the save removes `made`.
// App and live MCP: Studio.importSession(_ source: URL, at: Int = 0, markers: Bool, agent: AgentName? = nil, progress:)
//   -> a blockingRun with ImportRun.Kind.session and `made` in its result, one undo entry
//   (History.Name.importSession); a refusal is StudioError.sessionImport(_, source:), and a take in
//   another studio ends the run with StudioError.sessionImportYielded(source:).
```

## Rubric

1. The files go through the one copy function of 0042, with its order and its faults.
2. A refusal changes nothing; nothing can fail after the renames; a cancel before the save leaves no new name in `Clips/`.
3. The source is untrusted: every source read goes through the guarded calls, plus the link check.
4. No `session.xml` change: an older build opens a session after an import.
5. The session stores nothing of the import: no source, no offset, no group of tracks.
6. Small: few new types, no new public mutating `Session` method (`ParityTests`).

## Candidates

- **A. A composition over `pasteClipboard`.** `importSession` builds a whole-session excerpt, calls `pasteClipboard` with `.unselected`, then applies the track settings and the markers to the returned session copy. Rubric: 1 yes (one call), 2 yes (the checks run before the call; after it, only setters that cannot fail), 3 yes with one added check, 4 yes, 5 yes, 6 yes (one function, one error enum, one result type).
- **B. A merge in `DirigibleCore`.** `Session.merge(_ other: Session, at:markers:) -> (Session, copies: [FileID: FileID])` maps the whole other session (tracks with all settings, markers, transcripts), and a separate file pass in `DirigibleAudio` copies the files. Rubric: 1 no (a second copy path next to `pasteClipboard`, against 0042), 2 needs its own order, 3 needs its own checks, 4 yes, 5 yes, 6 no (a new public mutating method needs a command or an exemption, and it repeats the excerpt, map, and rate rules of 0042).

## Decision

Candidate A. Graft from B: the track settings that the excerpt drops (gain, role, mute, follow flag, voice match) come with the import, through the existing `Session` setters, so the new tracks sound and edit as in the source.

- **The source read.** The import reads the source once, through `Session(contentsOf:)`, the guarded read of 0003 Rules. Before the read of `session.xml` and of each transcript file, the import checks the download state of that file (0040) and refuses a file that is not downloaded, because its read can block in the kernel. No other code of the import lists the source `Clips/`. Before `pasteClipboard`, the only other open of a source file is the link check below (read-only, no wait). The import compares the package identities after that read, so a source item that the read refuses gives the read error. The import takes no `PackageLock` of the source, because the lock open creates `.lock` (0012). So the import never writes into the source package.
- **Placement.** The new tracks go after the last track, in source order, with the source name and layout. When a target track or an earlier new track has that name, the new name is the source name plus " (<source session>)". The suffix is the source package name without its extension, with each scalar removed that `isStorableInSession` refuses; with no scalar left, or when the suffix form is itself the name of a target track or an earlier new track, the name is "<source name> (<n>)" with the smallest free n from 2. The import computes the names before `pasteClipboard` and refuses no source because of its package name. Source frame f goes to target frame f + `at` (`at` in target frames, -2^40...2^40). A negative `at` cuts the source at c = round(-at x source rate / target rate) and pastes at 0. No clip after the cut refuses.
- **What comes.** The clips (gain, fades, crossfades, envelope, ride points), the words of the copied files, the track gain, role, mute, follow flag, and voice match. The voice match is a track value of the sound, as the gain is: a paste into existing tracks plays unmatched (0074), but an imported track is a copy of the source track. A source track with an `.app` route imports muted, also when it is heard in the source: a call tap records the voice of the other side (0006), so that track repeats a microphone track of the target late. Not solo, not the input route, not the captures, not the render origins, not the drift links (0077), not the export presets (0080: the target keeps its own), not the episode, not the chapter images. Markers and chapters only on request, with new IDs.
- **Refusals.** An `at` outside -2^40...2^40 (before any read), a target rate outside 8000...384000 Hz (after the offset), a source rate outside 8000...384000 Hz (before any copy; the reader accepts any rate over 0; with both ranges and the 2^40 frame bound no scale step can overflow), the target as source, a source with a take that is not finalized, a source with no clip, a source that does not read (its own `SessionFileError`), a named source file with a link at a component of its path or that is not a regular file, a marker that `setMarker` refuses, and every `PasteError`. Each refusal comes before the first rename.
- **The link check.** `importSession` checks each named source file with `openChecked`, the check of the template copy (0079), which moves to `Import/CheckedOpen.swift` for both callers: an `openat` of `Clips/<path>` from the source package folder with `O_NOFOLLOW_ANY` and `O_NONBLOCK`, then `fstat` gives a regular file. Before each open, the import reads the cancel flag and refuses a file that is not downloaded (0040): an open of a dataless file can block in the kernel. The check sits outside the one copy function of 0042. Later item 1280 moves it into `copyFiles`, so the paste across packages gets it too. The check holds for a source that no other process changes: a hostile process that swaps a checked file for a link or a FIFO before the copy is out of scope, and item 1280 closes that hole.
- **Cancel.** A cancel before the renames throws in `pasteClipboard` (0042). A cancel that the caller sees after the renames and before the save follows 0049: the caller removes `made`. An Undo after the save follows 0042: the WAVs stay as unused files.
- **One-way part: no provenance.** The session stores nothing of the import: no source package, no offset, no group of tracks, and no take origin for an imported file (0061).
- **Surface.** `dirigible import-session <package> <source> [--at <frame>] [--markers]` prints the new track IDs, a line `marker <id>` for each new marker, and a `Left out:` line with the count of the markers that land before frame 0 or after frame 2^40; the tool `import_session` gives the same lines and has progress and cancel (0049); File > Import Session... runs it as one undo step, and its result line names the count of the markers left out. Each requested marker is reported as imported or as left out.

## Consequences

- An import at another rate converts each file once from the source pool WAV. A file that the source finalize resampled gets a second resample, as with a paste today.
- The rough start can be wrong by the time between the two record starts. The user moves the new tracks, or gives `at`.
- A second import of the same package, for example an updated copy from the partner, adds a second set of tracks and files. Nothing marks the first set, so the user removes it by hand.
- No imported clip has a take time in the target (0061).
- An imported voice match keeps the reference name of the source clip (`VoiceMatch.reference`). The name is only shown, and it can equal the name of a clip of the target.

## Alternatives considered

- **Candidate B, a merge in Core.** Rejected: a second copy path against 0042, and a new public mutating method.
- **A stored source group (a package ID on each imported track).** It would mark the tracks of one import and find a repeat import. It is a format change (0024) with no reader in this landing. Rejected for now.
- **A start on the wall clock, from file times** (the mtime of `Capture/take<n>.anchor`). It survives zip and Finder copies (probe), but it is the time of the finalize, not of the record start, and a recovered take writes it hours later. Later item.
- **A stored take-start wall clock** (a format change). It gives a real rough start for packages recorded after it. Later item.
