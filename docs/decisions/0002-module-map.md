# 0002. Module map: three libraries and a thin app

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
- Amended: 2026-10-05, run `2026-10-05-file-import`. `DirigibleAudio` has the folder `Import/` for the file import, and `Finalize/ClipConversion.swift` is the one conversion of finalize and import (see 0040).
- Amended: 2026-09-25. `Render/Export.swift`, `Render/ExportFile.swift`, and `Render/FileMove.swift` hold the export writer; `Render/RenderMix.swift` goes. `Studio/Studio+Export.swift` runs the export job (see 0019).
- Amended: 2026-09-26. The library target `DirigibleTimeline` holds the timeline selection (`Marks`, `TimelineScale`), the lane and ruler geometry, and the gesture model. It imports Foundation and depends on `DirigibleCore`. `DirigibleApp` depends on it. `DirigibleTimelineTests` tests it (see 0020).
- Amended: 2026-10-03. The body states the map after the amendments above.
- Amended: 2026-10-03, player-executor run. The `Player` runs on its own serial dispatch queue, with its own refill tick (see 0016).
- Amended: 2026-10-03, run 8a. `DirigibleAudio/DSP/` holds the BS.1770 loudness meter and `clipLoudness`. The K-weighting is a hand-written Double biquad, not Accelerate (see 0008).
- Amended: 2026-10-03, run 8b. `DirigibleAudio/DSP/AutoLevel.swift` holds `autoLevel` with the meter. `Studio/Studio+Level.swift` holds Cmd-L, and `Studio/Studio+Transport.swift` holds the `Transport` enum (see 0031).
- Amended: 2026-10-03, run 9a. `DirigibleAudio/DSP/` also holds the true-peak meter (`TruePeak.swift`), the export limiter (`Limiter.swift`), and the dither (`Dither.swift`) (see 0032).
- Amended: 2026-10-03, run 9b. `DirigibleAudio/DSP/LiveLoudness.swift` holds the live meter, `Render/PlayerLoudness.swift` its Player queue, and `Render/Player+Offline.swift` the offline test pulls. `DirigibleApp/LoudnessStrip.swift` holds the strip (see 0033).
- Amended: 2026-10-03, MP3 run. `CLame` holds the libmp3lame encoder of LAME 4.0, with C warnings as errors. `DirigibleAudio` depends on it (see 0034).
- Amended: 2026-10-07, run 2026-10-07-mcp-cli. `DirigibleCLI` also holds the MCP server and its tool table, in files with no ArgumentParser import. Release 3 moves them into a library target that the app imports (see 0041).
- Amended: 2026-10-10, run `2026-10-10-agents-md-restructure`. **Folders** lists every folder with its purpose, and says how to find a type with no file of its own. `AGENTS.md` points here.
- Amended: 2026-10-12, run `2026-10-12-mcp-in-app`. The library target `DirigibleMCP` holds the MCP server, its tool table, and the shared edit and error text code of the CLI, so the app can import them. `DirigibleCLI` depends on it. The import-rule test covers it (see 0046).
- Amended: 2026-10-12, run `2026-10-12-mcp-in-app`. `DirigibleMCP` also holds the app server (`AgentServer`, `AgentListener`), the live executor, and the bridge client (`AgentBridge`). `DirigibleMCPTests` tests them over a real socket (see 0046).
- Amended: 2026-10-13, run `2026-10-12-mcp-in-app`. `DirigibleApp` and `DirigibleTests` depend on `DirigibleMCP`: the app owns one `AgentServer` (see 0046).

## Context

Decision 0001 makes layers SwiftPM targets, so the compiler enforces the dependency direction, and leaves the target names to the first planning run. The rules in `CODING_STANDARDS.md`: the domain imports only Foundation, UI depends on the domain, and the app target is thin. The rule in `AGENTS.md`: nothing on a real-time audio thread allocates, locks, logs, or awaits. The research fixes the mechanisms: one IOProc per device (0004), an SPSC ring with swift-atomics (0005), our own XML file (0003), export through AVAudioFile (0007), our own loudness meter with Accelerate (0008).

Two designs were compared: few targets, and one target for each capability (capture, session I/O, render, playback, DSP, and a facade).

## Decision

| Target | Owns | Imports | First release |
|---|---|---|---|
| `DirigibleCore` | `Session`, `Track`, `Clip`, `AudioFile`, capture timing, `Marker`, `Frames`, `ChannelLayout`, track routes, edits and their invariants, snapshot undo (`History`), session XML read and atomic write, take alignment and auto-level math | Foundation | 1 |
| `DirigibleAudio` | Device list, `DeviceWriter` (IOProcs, rings, CAF segments), finalize, recovery, `Player` (AVAudioEngine), `exportMix`, waveform peaks. Later: headphone check, loudness meter, process taps, noise reduction. `Studio`, the `@MainActor` facade that the app calls | Foundation, CoreAudio, AudioToolbox, AVFoundation, Accelerate, IOKit (the sleep assertion), `Atomics` (swift-atomics, 0005), `DirigibleCore` | 1 |
| `DirigibleTimeline` | The timeline selection (`Marks`, `TimelineScale`), the lane and ruler geometry, the gesture model (0020) | Foundation, `DirigibleCore` | 1 |
| `CLame` | libmp3lame of LAME 4.0 with no decoder, C warnings as errors (0007, 0034) | none | 2 |
| `DirigibleApp` (executable) | SwiftUI views, menus and key equivalents, the timeline view, `.lproj` strings (0010), wiring | SwiftUI, AppKit, the four libraries | 1 |
| `DirigibleMCP` | The MCP server and its tool table (0041, 0046), the app server and the live executor, the bridge client, the locked read-edit-save step, the argument rules, the error text, the text and JSON views of a session, and the marker, episode, paste, and backup work of the CLI and the tools | Foundation, Observation, os (the logger), `DirigibleCore`, `DirigibleAudio` | 3 |
| `DirigibleCLI` (executable, product `dirigible`) | Argument parsing, the exit codes, the commands, and the stdin loop of `dirigible mcp`. No logic that the app needs | Foundation, AVFoundation (the microphone access request), `ArgumentParser` (swift-argument-parser), `DirigibleCore`, `DirigibleAudio`, `DirigibleMCP` | CLI run |

Dependencies go one way: `DirigibleApp` to `DirigibleAudio` to `DirigibleCore`, `DirigibleAudio` to `CLame`, `DirigibleApp` to `DirigibleTimeline` to `DirigibleCore`, and `DirigibleApp` to `DirigibleCore`. `DirigibleMCP` depends on `DirigibleCore` and `DirigibleAudio`. `DirigibleCLI` depends on `DirigibleCore`, `DirigibleAudio` (0012), and `DirigibleMCP` (0046). `DirigibleCore` depends on no target.

Test targets: `DirigibleCoreTests`, `DirigibleAudioTests`, `DirigibleCLITests` (runs the `dirigible` binary), `DirigibleTimelineTests`, `DirigibleMCPTests` (the app server, the live tools, and the bridge, over a real socket), and `DirigibleTests` (bundle, localization, import rule).

Rules that come with the map:

- **Import-rule test.** SwiftPM cannot stop a target from importing a system framework. A test in `DirigibleTests` reads every file in `Sources/DirigibleCore` and fails on any `import` other than Foundation. It also fails when `DirigibleTimeline` imports more than Foundation and `DirigibleCore` (0020), and when `DirigibleMCP` imports more than Foundation, Observation, os, `DirigibleCore`, and `DirigibleAudio` (0046).
- **Studio is in the library.** "Stop, finalize, add the take as one undo step, save" is logic. Integration tests drive it through `Studio`. The app only maps views and menu commands to `Studio` calls.
- **Snapshot undo.** `History` keeps `Session` values. `edit { }` records one entry; an edit that changes nothing records none. There is no command protocol with inverse commands.
- **Actors.** `Studio` and the views are `@MainActor`. The `Player` is an actor on its own serial dispatch queue, with its own refill tick (0016). Each device writer has its own serial dispatch queue. Each IOProc and listener is a static C function that captures nothing and gets a client-data pointer (0013). Finalize, export, and peak calculation run off the main actor.
- **Library code has no UI text.** Errors are enums. The app maps each case to a `.lproj` key.
- **Folders.** Inside `DirigibleAudio`: `Capture/` (the device list, the HAL calls, the device inputs and writers, the ring, the segments and sidecars, the app taps), `DSP/` (the loudness meters, the true peak, auto-level, the limiter, the dither), `Finalize/` (segments to clip files, the clip conversion, the rate choice, the take anchor), `Import/` (the file import and the clipboard paste), `Listen/` (the record monitor of 0044: the `Listener`, the listen ring, the output unit, the speaker guard, the loopback set), `Render/` (the `Player`, the mix reader, the export writer, the MP3 file, the peaks and their cache), and `Studio/` (the `@MainActor` facade that the app calls, with a `Studio+<job>.swift` file for most jobs). `DirigibleApp/Timeline/` holds the timeline view: the lanes, the ruler, and the track headers. The other Swift targets have no subfolders. A type with no file of its own name is in the file of its owner (for example `DeviceInput` in `Capture/HAL.swift`): find it with grep. The 400-line file rule applies.

## Consequences

- `Package.swift` gets the targets with their first code in the Release 1 runs, not in this run.
- One large audio target compiles slower than several small ones. In exchange, capture, render, and DSP have no public seams between them.
- `DirigibleCore` does file I/O (`Session.write`). In exchange, the file format and the model invariants are in one place.
- A reviewer checks the real-time rules in `Capture/`. The compiler cannot, because the IOProc code and the writer code are in one target.

## Alternatives considered

- **One target for each capability** (nine targets). Rejected. Each seam becomes a public API with one consumer. Every audio target imports the same frameworks, so the compiler enforces nothing more than the two-library map does.
- **A separate session I/O target.** Rejected. It has one consumer, and the format changes together with the model. `XMLDocument` is in Foundation, so the Foundation-only rule holds without it.
- **The observable document model in the app target.** Rejected. The record-stop-save flow is logic, and the thin-app rule in `CODING_STANDARDS.md` puts logic in a library that integration tests drive.
- **A `DirigibleUI` library for views.** Deferred. Add it when a view needs tests or previews.
