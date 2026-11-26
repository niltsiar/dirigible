import AVFoundation
import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Level Over Time and Remove Level Over Time in the session window. The tracks t1 (no role), t2 (dialogue), t3 (music), and t4
/// (effects) each hold the clip c<n> of 3 s of the file `f1`, which has four levels
/// (`ReduceNoiseWindowTests.rolesPackage`).
@Suite(.serialized) @MainActor struct LevelOverTimeWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open() async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await ReduceNoiseWindowTests.rolesPackage(in: folder.url)
        let (model, studio, window, _) = try await openLanes(app, package)
        return (model, studio, window)
    }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    /// Two clips of `f1` (t1, t2) and a silent clip `s` of 3 s on its own file (t3).
    @concurrent nonisolated static func silentPackage(in folder: URL) async throws -> URL {
        let url = try await timelinePackage(in: folder, tracks: 2, seconds: 3, noise: true)
        var session = try Session(contentsOf: url)
        let frames = 48_000 * 3
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let writer = try ClipWriter(
            url: url.appending(path: "\(clipsFolderName)/f2.wav"), file: "f2.wav", format: format)
        try writer.write(buffer)
        try writer.close()
        try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: Frames(frames)))
        try session.addTrack("t3", name: "T3", layout: .mono)
        try session.place(Clip(id: "s", file: "f2", start: 0, offset: 0, length: Frames(frames)), on: "t3")
        try session.write(to: url)
        return url
    }

    func ride(_ clip: ClipID, _ studio: Studio) -> GainEnvelope { studio.session.clip(clip)?.clip.ride ?? .empty }

    func levelOverTime(_ model: SessionWindow, _ selection: Selection) async {
        model.timeline.selection = selection
        await model.levelOverTime()
    }

    /// The item is on with an idle studio, no dialog, and a selection that holds a clip of any
    /// track role. Controls: an empty selection, a range past the clips, a take, an import run, and
    /// a sheet turn it off. A selection of music clips only is on (fail: the noise role filter).
    @Test func menuStateForEachStartState() async throws {
        let (model, studio, _) = try await open()
        let cases: [(String, Selection, Bool)] = [
            ("no selection", .none, false), ("a click on a clip with no role", set("c1"), true),
            ("a dialogue clip", set("c2"), true), ("a music clip only", set("c3"), true),
            ("music and effects clips", set("c3", "c4"), true),
            ("a range on a track with a clip", .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])), true),
            ("a range past the clips", .range(Marks(inPoint: 2_000_000, outPoint: 2_000_010, tracks: ["t1"])), false),
            ("a track", .range(Marks(tracks: ["t2"])), true),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(.levelOverTime) == on, "\(name)")
        }

        model.timeline.selection = set("c1")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.levelOverTime), "a take")
        studio.transport = .importing(ImportRun(name: "x", kind: .file, flags: ImportFlags()))
        #expect(!model.isOn(.levelOverTime), "an import run")
        studio.transport = .idle
        #expect(model.isOn(.levelOverTime), "after the run")
        model.denoiseDraft = DenoiseDraft(clips: ["c1"], in: studio.session, defaults: nil, region: nil)
        #expect(!model.isOn(.levelOverTime), "a sheet shows")
        await model.close()
    }

    /// A selection with no clip beeps and starts nothing; a selection of music clips only
    /// rides, and a clip on a track with no role rides too.
    @Test func noClipBeeps() async throws {
        let (model, studio, _) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session
        model.timeline.selection = .none
        model.run(.levelOverTime)
        await until("the beep") { beeps == 1 }
        #expect(studio.transport == .idle && studio.session == before, "beeps \(beeps)")
        await levelOverTime(model, set("c3", "c4"))
        #expect(beeps == 1 && model.alert == nil && studio.session != before, "beeps \(beeps)")
        #expect(!ride("c3", studio).isEmpty && !ride("c4", studio).isEmpty && ride("c1", studio).isEmpty)
        await model.close()
    }

    /// The command `.levelOverTime` with a key event runs while the focus is in a track name field
    /// (the key is no typing key), and only the selected clip gets a ride.
    @Test func levelOverTimeRunsWithTheFocusInATrackNameField() async throws {
        _ = NSApplication.shared
        let chord = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                context: nil, characters: "L", charactersIgnoringModifiers: "L", isARepeat: false, keyCode: 37))
        let (model, studio, window) = try await open()
        _ = try await focusName(in: window)
        model.timeline.selection = set("c2")
        app.timeline(.levelOverTime, event: chord, in: window)
        await until("the ride ends") { !ride("c2", studio).isEmpty && studio.transport == .idle }
        #expect(ride("c1", studio).isEmpty)
        await model.close()
    }

    /// C9 (g): a Level Over Time that rides clips shows no banner, because the line of each clip shows
    /// the ride. VoiceOver hears the count of the leveled clips once.
    @Test func levelOverTimeShowsNoBannerAndIsAnnounced() async throws {
        let (model, studio, _) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        await levelOverTime(model, set("c1", "c2"))

        let texts = (-6...6).map { L10n.rideDone(RideResult(leveled: 2, unmeasured: 0, gain: $0)) }
        #expect(heard.count == 1 && texts.contains(heard[0]), "VoiceOver hears the result once: \(heard)")
        let banners = ChromeState.reportBanners(model, studio)
        #expect(!banners.contains { $0.key.hasPrefix("rideReport") }, "each clip got a level: \(banners)")
        await model.close()
    }

    /// One Level Over Time on two clips is one undo step; a second run with no change gives the same
    /// rides and no undo entry.
    @Test func undoRedoAndSecondRun() async throws {
        let (model, studio, _) = try await open()
        let before = studio.session

        await levelOverTime(model, set("c1", "c2"))

        let first = studio.session
        #expect(model.alert == nil && !ride("c1", studio).isEmpty && !ride("c2", studio).isEmpty)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo step")
        try studio.redo()
        #expect(studio.session == first, "redo")

        await levelOverTime(model, set("c1", "c2"))

        #expect(studio.session == first && model.alert == nil, "the second run gives the same rides")
        try studio.undo()
        #expect(studio.session == before, "the second run made no undo entry")
        await model.close()
    }

    /// The announcement and the banner text of the counts, in English and Spanish. The announcement
    /// has the leveled clips and the gain with its sign; the banner has the unmeasured clips only.
    @Test func resultBanner() throws {
        let tables = try ["en", "es"].map { try stringsTable($0) }
        func text(_ result: RideResult, _ table: [String: String]) -> String {
            L10n.rideResult(result) { table[$0.rawValue] ?? $0.rawValue }
        }
        func done(_ result: RideResult, _ table: [String: String]) -> String {
            L10n.rideDone(result) { table[$0.rawValue] ?? $0.rawValue }
        }
        #expect(
            done(RideResult(leveled: 3, unmeasured: 0, gain: 4), tables[0]) == "Leveled 3 clips over time, up to +4 dB."
        )
        #expect(
            done(RideResult(leveled: 1, unmeasured: 0, gain: -2), tables[0]) == "Leveled 1 clip over time, up to -2 dB."
        )
        #expect(
            done(RideResult(leveled: 2, unmeasured: 1, gain: 5), tables[0]) == "Leveled 2 clips over time, up to +5 dB."
        )
        #expect(text(RideResult(leveled: 2, unmeasured: 1, gain: 5), tables[0]) == "1 clip has no level to measure.")
        #expect(text(RideResult(leveled: 3, unmeasured: 0, gain: 4), tables[0]) == "", "no warning, no banner")
        #expect(done(RideResult(leveled: 0, unmeasured: 2, gain: 0), tables[0]) == "", "nothing leveled")
        #expect(text(RideResult(leveled: 0, unmeasured: 2, gain: 0), tables[0]) == "2 clips have no level to measure.")
        #expect(text(RideResult(leveled: 0, unmeasured: 1, gain: 0), tables[0]) == "1 clip has no level to measure.")
        #expect(
            done(RideResult(leveled: 2, unmeasured: 1, gain: 5), tables[1])
                == "Nivelados 2 clips en el tiempo, hasta +5 dB.")
        #expect(
            text(RideResult(leveled: 2, unmeasured: 1, gain: 5), tables[1]) == "1 clip no tiene nivel que medir.")
        #expect(tables[0][L10n.rideCanceled.rawValue] == "Level Over Time canceled. No clip changed.")
        #expect(tables[1][L10n.rideCanceled.rawValue] == "Nivelación en el tiempo cancelada. Ningún clip cambió.")
    }

    /// A largest gain that rounds to 0 dB has no "up to" part. The
    /// sentence has no "+0 dB". Control: 1 dB keeps it.
    @Test func zeroGainHasNoUpTo() throws {
        let table = try stringsTable("en")
        func text(_ result: RideResult) -> String { L10n.rideDone(result) { table[$0.rawValue] ?? $0.rawValue } }
        #expect(text(RideResult(leveled: 2, unmeasured: 0, gain: 0)) == "Leveled 2 clips over time.")
        #expect(text(RideResult(leveled: 1, unmeasured: 1, gain: 0)) == "Leveled 1 clip over time.")
        #expect(text(RideResult(leveled: 1, unmeasured: 0, gain: 1)) == "Leveled 1 clip over time, up to +1 dB.")
        #expect(RideResult(RideReport(leveled: ["c1"], unmeasured: [], largestGain: Gain(dB: 0.4)!)).gain == 0)
        #expect(RideResult(RideReport(leveled: ["c1"], unmeasured: [], largestGain: Gain(dB: -2.6)!)).gain == -3)
    }

    /// C9 (g), near input: one silent clip and two speech clips give a warning banner with the
    /// sentence for one unmeasured clip, and VoiceOver hears "Leveled 2 clips". A silent clip alone
    /// gives the banner, no "Leveled" sentence, and no undo entry.
    @Test func resultBannerFromARun() async throws {
        let (model, studio, _, _) = try await openLanes(app, try await Self.silentPackage(in: folder.url))
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }

        await levelOverTime(model, set("c1", "c2", "s"))

        let result = try #require(model.rideReport?.result)
        #expect(result.leveled == 2 && result.unmeasured == 1, "\(result)")
        #expect(ride("s", studio).isEmpty, "the silent clip has no ride")
        await until("the banner shows") { model.shown.banners.contains { $0.key == "rideReport.1" } }
        let banner = try #require(model.shown.banners.first { $0.key == "rideReport.1" })
        #expect(banner.kind == .warning && banner.text == L10n.rideUnmeasuredOne.text, "\(banner.text)")
        #expect(heard.contains(L10n.rideDone(RideResult(leveled: 2, unmeasured: 1, gain: result.gain))), "\(heard)")

        let session = studio.session
        await levelOverTime(model, set("s"))

        #expect(studio.session == session && model.alert == nil, "a silent clip alone writes nothing")
        #expect(model.rideReport?.result == RideResult(leveled: 0, unmeasured: 1, gain: 0))
        await until("the second banner shows") { model.shown.banners.contains { $0.key == "rideReport.2" } }
        let second = try #require(model.shown.banners.first { $0.key == "rideReport.2" })
        #expect(second.text == L10n.rideUnmeasuredOne.text, "\(second.text)")
        await model.close()
    }

    /// The banner Cancel changes no clip, adds no undo step, shows no alert, and VoiceOver
    /// reads the Level Over Time cancel text once.
    @Test func cancelNamesTheCommand() async throws {
        let (model, studio, _) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        let hold = BlockHold()
        defer { hold.release() }
        studio.environment.loudnessBlock = { hold.step() }
        let before = studio.session
        model.timeline.selection = set("c1")

        let run = Task { await model.levelOverTime() }
        await until("the ride holds") { hold.held }
        #expect(studio.transport == .riding)
        model.cancelReadJob()
        hold.release()
        await run.value

        #expect(studio.session == before && !studio.canUndo && model.alert == nil)
        #expect(heard == [L10n.rideCanceled.text], "\(heard)")
        #expect(model.rideReport == nil)
        await model.close()
    }

    /// The banner of the `.riding` transport and each error alert name Level Over Time.
    /// Fail: "Leveling clips" in the banner, or the general session text in an alert.
    @Test func runTextsNameTheCommand() throws {
        for language in ["en", "es"] {
            let table = try stringsTable(language)
            #expect(table[L10n.takeRiding.rawValue] != table[L10n.takeLeveling.rawValue], "\(language)")
        }
        let english = try stringsTable("en")
        #expect(english[L10n.takeRiding.rawValue] == "Leveling over time")
        let rows: [(String, L10n)] = [
            ("5", .errorRideRead), ("missing", .errorRideMissing), ("short", .errorRideShort),
            ("unreadable", .errorRideUnreadable),
        ]
        let messages = [
            L10n.message(for: .rideRead(5)), L10n.message(for: .rideFault("f1", .missing)),
            L10n.message(for: .rideFault("f1", .short(100))), L10n.message(for: .rideFault("f1", .unreadable)),
        ]
        for (message, row) in zip(messages, rows) {
            #expect(message == row.1.text, "\(row.0)")
            #expect(message != L10n.errorSessionOther.text)
            #expect(english[row.1.rawValue]?.contains("Leveling over time") == true, "\(row.0)")
        }
        #expect(english[L10n.errorRideRead.rawValue]?.contains("%lld") == true)
        for row in rows.dropFirst() { #expect(english[row.1.rawValue]?.contains("%@") == true) }
    }
}
