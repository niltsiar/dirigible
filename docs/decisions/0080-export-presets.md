# 0080. Export presets: named export options in session.xml, two built-in presets in code, and one export job for several presets

- Status: accepted
- Date: 2026-10-28
- Amends: 0003 (the `<exportPresets>` element), 0024 (a new `session.xml` version), 0019 (one export job writes one file for each preset), 0002 (the stored export values move to `DirigibleCore`), 0011 (`dirigible preset set`, `dirigible preset remove`, `dirigible export --preset`), 0041 (the tools `preset_set` and `preset_remove`, and the `preset` argument of `export`). Depends on: 0067 (the set job of chapter export) and 0078 (the item loop `exportItems`), both on main.

In this file, "..." in a menu item stands for U+2026 (a write hook refuses the character); the strings use U+2026.

## Context

F57 (R11, Release 7 item 2) asks for export presets: several targets in one step. The reference apps (`docs/research/presets-templates.md`):

- Hindenburg: named export formats for each file format (finding 1); 1-Click Publish uploads to each check-marked account in one action (finding 2); PRO exports "to any LUFS standard or even multiple standards at once" (finding 4). Hindenburg advises a WAV master and an MP3 for distribution: "MP3, 128 kbps, 44.1 kHz, mono, targeting -16 LUFS" (finding 5).
- Logic Pro bounces to several formats in one step, with one file name and each extension (findings 9, 10).
- Final Cut Pro: a bundle of destinations writes one file for each destination (finding 15); a destination can be a `.fcpxdest` file (finding 17).

Facts of the code (main 3cd282667):

- `ExportOptions` (`DirigibleAudio/Render/ExportTypes.swift`) holds `ExportFormat`, `ChannelLayout`, `ExportRate`, `LoudnessTarget?`, and `introTitle`. `ExportFormat` has `.floatCAF`, the format of `dirigible render`, which the app does not offer. `LoudnessTarget.integrated(for:)` returns `LUFS`, a type of `DirigibleAudio/DSP/`.
- The app keeps the last export options in UserDefaults keys `export.*` (`ExportSettings`). The CLI cannot read them.
- `session.xml` is version 19 (`driftSessionVersion`, `SessionWriter.swift:68`; `Session.fileVersion`).
- 0057 moved the stored render values to `DirigibleCore` "because the session reader parses them", and kept the DSP extensions in `DirigibleAudio`.
- 0067 (accepted) makes one `ExportJob` hold a set of files, with the target check before the first write, the stop result (`written`, `remaining`), and the progress of the file in hand (`ExportPartsProgress`). 0078 (accepted) moved its loop to the internal item loop of `Render/ExportSet.swift`, which the parts and the stems call:

```swift
struct ExportItem: Sendable { let session: Session; let source: ExportSource; let options: ExportOptions; let url: URL }
struct ExportItemsStop: Sendable { let error: ExportError; let written: [ExportResult]; let remaining: [URL] }
enum ExportItemsError: Error { case exists([URL]); case stopped(ExportItemsStop) }
func exportItems(
    _ items: [ExportItem], replacing: [URL: ConfirmedFile], package: () throws(SessionFileError) -> URL,
    progress: (_ fraction: Double, _ index: Int) -> Void, isCancelled: () -> Bool
) throws(ExportItemsError) -> [ExportResult]
```

Rubric: (R1) CLI parity: the CLI, the tools, and the app reach the same presets, with no hidden machine state; (R2) a show sets its targets once (the templates of 0079 carry them); (R3) the smallest format change; (R4) a set export has the take, close, and cancel rules of one export (0019) and refuses before the first file; (R5) no change to `exportMix`.

## Decision

**Stored values in DirigibleCore (amends 0002).** `ExportFormat`, `BitDepth`, `BitRate`, `ExportRate`, and `LoudnessTarget` move from `Render/ExportTypes.swift` to `DirigibleCore/ExportValues.swift`, with no change of case or raw value. `ExportRate.hertz(session:)` and `LoudnessTarget.integrated(for:)` stay in `DirigibleAudio` as extensions. `ExportOptions` stays in `DirigibleAudio`.

**The preset (DirigibleCore, `ExportPreset.swift`).**

```swift
/// The export options of a preset. `.floatCAF` is refused.
public struct PresetOptions: Hashable, Sendable {
    public let format: ExportFormat
    public let layout: ChannelLayout
    public let rate: ExportRate
    public let loudness: LoudnessTarget?
    public init(format: ExportFormat, layout: ChannelLayout, rate: ExportRate,
                loudness: LoudnessTarget?) throws(SessionError)   // .invalidPreset for .floatCAF
}

/// 1 to 64 Unicode scalars that the session can store (0003), with no space at either end and no
/// control character. It keeps the exact text, and `==` compares the exact text, so a case-only
/// rename changes the session.
public struct PresetName: Hashable, Sendable {
    public let text: String
    public init(_ text: String) throws(SessionError)
    /// `text.folding(options: .caseInsensitive, locale: nil)`: the one key of the collision
    /// rule and of the lookup.
    public var key: String { get }
}

/// A built-in preset: its own ID kind, a constant of the code, never stored in a file.
public enum BuiltInPreset: String, CaseIterable, Hashable, Sendable {
    case master, podcast              // the stored ID: the CLI and tool token
    public var options: PresetOptions { get }
    // The app shows a localized display name: "Master (WAV)", "Podcast (MP3)" (0010). A file
    // name, the CLI, and the tools use the ID.
}

/// A preset of the list: a built-in or a session preset.
public enum PresetRef: Hashable, Sendable {
    case builtIn(BuiltInPreset)
    case session(PresetName)
}

public struct ExportPreset: Hashable, Sendable {
    public let name: PresetName
    public let options: PresetOptions
}

extension Session {
    /// In the order that the user sees. Empty by default.
    public private(set) var exportPresets: [ExportPreset]
    /// Adds the preset, or puts it in the place of `replacing` (a rename keeps the place). On an
    /// add (`replacing` nil) or a rename (the key of the name differs from the key of
    /// `replacing`), throws `.presetNameTaken` when the key of the name equals the key of another
    /// entry of `allExportPresets` (a built-in ID included). An edit under its own key has no
    /// collision check, so a preset that a later built-in shadows can change its options.
    public mutating func setExportPreset(_ preset: ExportPreset, replacing: PresetName? = nil) throws(SessionError)
    public mutating func removeExportPreset(_ name: PresetName) throws(SessionError)
    /// The built-in presets, then the session presets: the list of the app, the CLI, and the tools.
    public var allExportPresets: [(ref: PresetRef, options: PresetOptions)] { get }
    /// The first preset whose key equals the key of `text`, in list order, with the session
    /// presets before the built-ins.
    public func exportPreset(named text: String) -> (ref: PresetRef, options: PresetOptions)?
}
```

- One collision rule, at edit time only: an add or a rename refuses a key of another entry of `allExportPresets`. The reader never refuses a name: a stored name that equals the ID of a built-in that a later build adds reads back, and two stored names of one key (a hand edit, or a fold of another build) read back in their order. The lookup takes the first match, with the session presets first, so a stored name keeps its meaning and the user keeps the preset that the user made. `docs/guide.md` says that a session preset with the name of a built-in hides that built-in from `--preset`.
- The collision rule compares the keys of session names and built-in IDs, not display texts. A session preset can show the display text of a built-in, for example a preset named "Master (WAV)" in a session that a user of another language opens.
- The built-in master preset is a pass-through: WAV 24-bit, stereo, the session rate, loudness Off, so the file has the samples of the mix (Hindenburg: "a high-quality WAV file as your master", finding 5).
- The built-in podcast preset keeps the rule of 0008: a mono export is 3 LU lower, so its target is -19 LUFS, not the -16 LUFS of Hindenburg (finding 5). MP3 128 kbit/s, mono, 44.1 kHz.
- A built-in preset is a constant, so a new session holds no preset and keeps its version (0024 P6).

**File (amends 0003 and 0024).** From version 20 (`presetSessionVersion`, a `package let` in `SessionWriter.swift` as the other versions), `<session>` can hold `<exportPresets>` after `<transcripts>`, with one `<preset name format bits bitRate channels rate loudness/>` for each preset, in list order. `format` is `wav`, `flac`, `aac`, or `mp3`; `bits` only with `wav` and `flac`; `bitRate` only with `aac` and `mp3`; `channels` is `mono` or `stereo`; `rate` is `session`, `44100`, or `48000`; `loudness` is a `LoudnessTarget` raw value or absent (Off). A session with no preset writes no element. The reader refuses an element in a file of a lower version and each value outside its list. Each of these refusals is a fixed rule that a later build does not widen. The reader never refuses a name: not because of a built-in, and not because of another stored name of one key. The reader applies only two name rules: the name is not empty, and the session can store each scalar. The length, space, and control rules of `PresetName` apply only to an edit, so a name that one build writes reads back in each build. The edit limit counts Unicode scalars, not characters, because the character count of a combining sequence depends on the Unicode tables of the OS. A template (0079) copies the presets, because the template rule removes only the episode data.

**The set export (amends 0019; depends on 0067).** One export writes one file for each chosen preset, over one source (range and tracks), in one `ExportJob`. It calls `exportItems` of 0078 unchanged with one item for each preset; `exportParts` and `exportStems` call the same loop. So the take, close, and cancel rules, the stop result, and the progress of the file in hand are the 0067 rules (R4). Each file is measured and normalized by itself (0032). Before the first file, the set refuses: two targets with one name after the character rule (`fileNameText`) and the byte cut of 0067 (compared with case and Unicode normalization folded), an item at a target that the user did not confirm (the target check of `exportItems`), and a rate that a format does not take (`ExportPresetsError.rateNotSupported(PresetRef, Int)`, 0019, 0034). The loop has no duplicate check and no rate check, so the preset wrapper runs both before it calls the loop. `presetTargets` runs the duplicate check. `exportPresets`, which has the session rate, runs the rate check of each preset; the rate check of `exportMix` (`Export.swift:60-63`) becomes one internal function that both call.

- The stop contract: a preset set keeps its finished files, as 0067 parts do, because each file is its own deliverable. A stop or a failure in file k leaves files 1 to k-1 on disk and no file k. The 0067 types (`ExportPartsError` with `.exists`, `.noPoint`, and `.stopped(ExportPartsStop)`; `ExportedPart`) and `StudioError.exportParts` do not change. The internal loop returns the results of the written items and the remaining URLs (`ExportItemsStop`), and each caller wraps them in its own types, as `exportParts` does (`ExportParts.swift:122-138`). The progress of the file in hand is an `ExportPartsProgress` from the item index of the loop, so `Studio.exportFile` serves parts and presets. A preset set has `ExportedPreset` (`PresetRef`, URL, `ExportResult`), `ExportPresetsStop` (`error`, `written: [ExportedPreset]`, `remaining: [URL]`), and `ExportPresetsError` (`.exists([URL])`, `.duplicateTargets([URL])`, `.rateNotSupported(PresetRef, Int)`, `.stopped(ExportPresetsStop)`), with the new case `StudioError.exportPresets(ExportPresetsError)`. The four exhaustive switches (`L10n+Messages.swift`, `ErrorText.swift`, `CaptureCommands.swift` `refusedCode`, `Studio+TakeLog.swift`) get the case and a text for each `ExportPresetsError` case, and `LiveExport.swift` and `SessionWindow+ExportSet.swift` handle it beside `.exportParts`.
- File names: with one file for each extension, `<prefix>.<ext>` (Logic, finding 10; "prefix" is the 0078 term). When two chosen presets share an extension, each file of the set is `<prefix>-<preset name>.<ext>`, with the character rule and the byte cut of 0067 on the preset name. The name function is in DirigibleCore beside `fileNameText`, which is internal to DirigibleCore, and takes the byte limit as an argument, as `Session.stemPlan`. For a built-in, the name is its fixed, non-localized ID (`<prefix>-master.wav`), so the app in each language and the CLI give one file name.
- A set with chapter split (0067) is a later item: `--preset` with `--split` exits 64.

**CLI and tools (amends 0011, 0041).**

- `dirigible preset set <package> <name> --format wav|flac|aac|mp3 [--bits 16|24] [--bitrate <kbit/s>] [--mono] [--rate 44100|48000] [--loudness podcast|speech|ebu|atsc] [--rename <old>]` and `dirigible preset remove <package> <name>`. Tools `preset_set` and `preset_remove`. A value outside its list exits 64; an unknown preset exits 1. `preset set` of a name that the session already stores replaces that preset under its own name (`replacing:` set, so no collision check), also when a built-in has the same key; the CLI and the tools then give the library result of E3. Only an add of a new name, or a rename with `--rename`, whose key another entry of `allExportPresets` has (a built-in ID included) exits 1. Each exit 1 leaves the package unchanged.
- `dirigible export <package> --preset <name> [--preset <name>]... --out <folder>/<prefix>`: one file for each preset, one stdout line for each file: its path, and with a loudness target a tab and the loudness line, as `--split`. `--preset` takes a session preset name or a built-in ID, through `Session.exportPreset(named:)`. `--preset` with `--bits`, `--bitrate`, `--mono`, `--rate`, `--loudness`, or `--split`, or an `--out` with an audio extension, exits 64. The `export` tool takes `preset`, the option name of the command (0041). Before any file, the set exits 2 when two presets give one file name, or when a file is at a target and there is no `--replace`.
- `info` and `info --json` (key `exportPresets`) list the session presets.

**App (UI panel ruling of 2026-10-28, `ui-panel.md`).**

- File > Export with Presets... has no key equivalent, because Option-Command-E is Export Chapters. It comes after Export Stems..., before the template group of 0079.
- The order of the item: the menu, then `exportFaults` on the whole-session source (the superset; the sheet range only narrows it), then the one media question `ExportStep.asking(source, faults, .presets)` when a file has a fault, then the preset sheet. The Export answer opens the sheet; Cancel opens no sheet and sets `exportStep` to nil. The `ExportStep` value owns the question and its payload, as for the mix and the stems (0078), so the question comes before any file.
- The sheet holds the check list (built-in presets first, each row with a one-line summary such as "MP3, 128 kbit/s, mono, -19 LUFS"), the range, and a "Choose Folder..." button that opens the 0067 save panel for the folder and the prefix. Export is off with no preset checked, with a caption that says why. A line under the list shows the first file name and the count.
- The buttons +, -, and Edit... change the presets. "+" copies the selected preset. "Edit..." shows a pane inside the same sheet. The Export panel accessory has "Save as Preset...". Each change is one undo step of the session. A built-in cannot change.
- Each row is one VoiceOver element with the name and the summary. The progress sheet shows the preset of the file in hand: the export job keeps the `PresetRef` list of the running set (`Studio.exportPresetRefs`), and the window title of 0079 maps `exportFile.number - 1` to it (the window gives the sheet its title). A set that the `export` tool runs in the window job names its preset too.
- The app keeps the checked presets in the key `export.presets.checked`, keyed by `PresetRef`, so a session preset and a built-in of one key have their own checks. The list has two built-ins and no Broadcast preset.

## Consequences

- A user with no template sets a preset in each session. A template (0079) carries the presets to each new episode, as the Hindenburg default session carries its settings.
- An older build refuses a session with a preset (0024 P3). A session with no preset keeps its version.
- A set of n presets renders the mix n times, plus the loudness passes of each file. A shared render is later item 1266. The two built-in presets take more than 2.5 times the time of one WAV export of the mix (the MP3 encode and its loudness passes), so the app checks only the podcast preset the first time.
- 0002, 0003, 0011, 0019, 0024, and 0041 get an Amended line.

## Alternatives considered

- **A preset file in Application Support** (`Export Presets.xml`, as a `.fcpxdest` file). Rejected: a new file format with its own version (0024), and the CLI output then depends on a file of the Mac, not of the package (R1). A template cannot carry it (R2).
- **UserDefaults of the app** (as `export.*` today). Rejected: the CLI and the tools cannot read it (R1).
- **A Core copy of the export enums** (`PresetFormat`) and a map to `ExportOptions`. Rejected: two enums of one meaning; 0057 moved its stored values in the same way.
- **Built-in presets written into each new session.** Rejected: each new session then has the new version, and an older build refuses it (0024 P6).
- **A callers loop of `Studio.export`, one call for each preset.** Rejected for the reason of 0067: a take start between two files finds no job.
