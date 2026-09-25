# 0002. Module map: two libraries and a thin app

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. The app target is `DirigibleApp`, so its binary does not clash with the `dirigible` command (see 0011). The bundle executable is still `Dirigible`.
- Amended: 2026-09-24. The command-line front end adds the targets `DirigibleCLI` and `DirigibleCLITests` (see 0011).
- Amended: 2026-09-24. The first capture run has no `Recorder`: `DeviceWriter`, `finalizeTake`, and `Studio` hold its work. It adds `DirigibleAudioTests`. `DirigibleCLI` depends on `DirigibleAudio` for `take finalize` (see 0012).
- Amended: 2026-09-24. There is no `Recorder`. `DeviceWriter` is the recorder of one device, and its `DeviceInput` holds one appearance of the device: the IOProc and the ring. Each IOProc is a static C function (see 0013).
- Amended: 2026-09-24. The Imports cells list the packages (swift-atomics, swift-argument-parser), IOKit in `DirigibleAudio`, and AVFoundation and `DirigibleAudio` in `DirigibleCLI` (see 0013).
- Amended: 2026-09-24. `DirigibleApp` depends on `DirigibleAudio`, because the window calls `Studio`. `DirigibleTests` depends on `DirigibleApp`, `DirigibleAudio`, and `DirigibleCore`, so the string test and the window tests can use `@testable import DirigibleApp` (see 0014).
- Amended: 2026-09-24. The `Player` is an actor, not `@MainActor`, so the engine start and the file reads run off the main actor. `Render/` holds the `Player`, `MixReader`, and the media check (see 0016).
- Amended: 2026-09-25. `DirigibleApp/Timeline/` holds the timeline view. `Render/Peaks.swift` and `Render/PeakFile.swift` compute the peaks and keep the cache file. `Studio/Studio+Peaks.swift` loads the peaks off the main actor (see 0017).
- Amended: 2026-09-25. `Render/Export.swift`, `Render/ExportFile.swift`, and `Render/FileMove.swift` hold the export writer; `Render/RenderMix.swift` goes. `Studio/Studio+Export.swift` runs the export job (see 0019).

## Context

Decision 0001 makes layers SwiftPM targets, so the compiler enforces the dependency direction, and leaves the target names to the first planning run. The rules in `AGENTS.md`: the domain imports only Foundation, UI depends on the domain, the app target is thin, and nothing on a real-time audio thread allocates, locks, logs, or awaits. The research fixes the mechanisms: one IOProc per device (0004), an SPSC ring with swift-atomics (0005), our own XML file (0003), export through AVAudioFile (0007), our own loudness meter with Accelerate (0008).

Two designs were compared: few targets, and one target for each capability (capture, session I/O, render, playback, DSP, and a facade).

## Decision

| Target | Owns | Imports | First release |
|---|---|---|---|
| `DirigibleCore` | `Session`, `Track`, `Clip`, `AudioFile`, capture timing, `Marker`, `Frames`, `ChannelLayout`, track routes, edits and their invariants, snapshot undo (`History`), session XML read and atomic write, take alignment and auto-level math | Foundation | 1 |
| `DirigibleAudio` | Device list, `DeviceWriter` (IOProcs, rings, CAF segments), finalize, recovery, `Player` (AVAudioEngine), `exportMix`, waveform peaks. Later: headphone check, loudness meter, process taps, noise reduction. `Studio`, the `@MainActor` facade that the app calls | Foundation, CoreAudio, AudioToolbox, AVFoundation, Accelerate, IOKit (the sleep assertion), `Atomics` (swift-atomics, 0005), `DirigibleCore` | 1 |
| `CLame` | libmp3lame with the decoder off (0007) | none | 2 |
| `DirigibleApp` (executable) | SwiftUI views, menus and key equivalents, the timeline view, `.lproj` strings (0010), wiring | SwiftUI, AppKit, both libraries | 1 |
| `DirigibleCLI` (executable, product `dirigible`) | Argument parsing, the read-edit-save step, error text, the text and JSON views of a session. No logic that the app needs | Foundation, AVFoundation (the microphone access request), `ArgumentParser` (swift-argument-parser), `DirigibleCore`, `DirigibleAudio` | CLI run |

Dependencies go one way: `DirigibleApp` to `DirigibleAudio` to `DirigibleCore`, and `DirigibleApp` to `DirigibleCore`. `DirigibleCLI` depends on `DirigibleCore` and `DirigibleAudio` (0012). `DirigibleCore` depends on no target.

Test targets: `DirigibleCoreTests`, `DirigibleAudioTests`, `DirigibleCLITests` (runs the `dirigible` binary), and `DirigibleTests` (bundle, localization, import rule).

Rules that come with the map:

- **Import-rule test.** SwiftPM cannot stop a target from importing a system framework. A test in `DirigibleTests` reads every file in `Sources/DirigibleCore` and fails on any `import` other than Foundation.
- **Studio is in the library.** "Stop, finalize, add the take as one undo step, save" is logic. Integration tests drive it through `Studio`. The app only maps views and menu commands to `Studio` calls.
- **Snapshot undo.** `History` keeps `Session` values. `edit { }` records one entry; an edit that changes nothing records none. There is no command protocol with inverse commands.
- **Actors.** `Studio`, `Player`, and the views are `@MainActor`. Each device writer has its own serial dispatch queue. Each IOProc and listener is a static C function that captures nothing and gets a client-data pointer (0013). Finalize, export, and peak calculation run off the main actor.
- **Library code has no UI text.** Errors are enums. The app maps each case to a `.lproj` key.
- **Folders inside `DirigibleAudio`.** `Capture/`, `Render/`, `DSP/`, and `Studio/`. The 400-line file rule applies.

## Consequences

- `Package.swift` gets the targets with their first code in the Release 1 runs, not in this run.
- One large audio target compiles slower than several small ones. In exchange, capture, render, and DSP have no public seams between them.
- `DirigibleCore` does file I/O (`Session.write`). In exchange, the file format and the model invariants are in one place.
- A reviewer checks the real-time rules in `Capture/`. The compiler cannot, because the IOProc code and the writer code are in one target.

## Alternatives considered

- **One target for each capability** (nine targets). Rejected. Each seam becomes a public API with one consumer. Every audio target imports the same frameworks, so the compiler enforces nothing more than the two-library map does.
- **A separate session I/O target.** Rejected. It has one consumer, and the format changes together with the model. `XMLDocument` is in Foundation, so the Foundation-only rule holds without it.
- **The observable document model in the app target.** Rejected. The record-stop-save flow is logic, and the thin-app rule in `AGENTS.md` puts logic in a library that integration tests drive.
- **A `DirigibleUI` library for views.** Deferred. Add it when a view needs tests or previews.
