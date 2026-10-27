import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Reduce Noise in the session window (decision 0054, criteria C13 and C14). The tracks
/// t1 (no role), t2 (dialogue), t3 (music), and t4 (effects) each hold the clip c<n> of 3 s of the
/// noise file `f1`.
@Suite(.serialized) @MainActor struct ReduceNoiseWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The writes run off the main actor.
    @concurrent nonisolated static func rolesPackage(in folder: URL) async throws -> URL {
        let url = try await timelinePackage(in: folder, tracks: 4, seconds: 3, noise: true)
        var session = try Session(contentsOf: url)
        try session.setRole(.dialogue, tracks: ["t2"])
        try session.setRole(.music, tracks: ["t3"])
        try session.setRole(.effects, tracks: ["t4"])
        try session.write(to: url)
        return url
    }

    func open() async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window, _) = try await openLanes(app, try await Self.rolesPackage(in: folder.url))
        studio.environment.playerOutput = .offline
        return (model, studio, window)
    }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    func fileOf(_ clip: ClipID, _ studio: Studio) -> FileID? { studio.session.clip(clip)?.clip.file }

    /// C13: the item is on with an idle studio and a selection that holds a clip on a track with no
    /// role or the dialogue role. Control: an empty selection, a range or a clip set with only music
    /// and effects clips, a range past the clips, a take, and an import run turn it off.
    @Test func menuStateForEachStartState() async throws {
        let (model, studio, _) = try await open()
        let cases: [(String, Selection, Bool)] = [
            ("no selection", .none, false), ("a click on a clip with no role", set("c1"), true),
            ("a dialogue clip", set("c2"), true), ("a music clip", set("c3"), false),
            ("an effects clip", set("c4"), false), ("music and effects clips", set("c3", "c4"), false),
            ("a mixed set", set("c1", "c3"), true),
            ("a range on a track with a clip", .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])), true),
            ("a range on the music track", .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t3"])), false),
            ("a range past the clips", .range(Marks(inPoint: 2_000_000, outPoint: 2_000_010, tracks: ["t1"])), false),
            ("a track", .range(Marks(tracks: ["t2"])), true),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(.reduceNoise) == on, "\(name)")
        }

        model.timeline.selection = set("c1")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.reduceNoise), "a take")
        studio.transport = .importing(ImportRun(name: "x", kind: .file, flags: ImportFlags()))
        #expect(!model.isOn(.reduceNoise), "an import run")
        studio.transport = .idle
        #expect(model.isOn(.reduceNoise), "after the run")
        await model.close()
    }

    /// C13: a selection with no clip, or with music clips only, beeps and changes nothing.
    @Test func noClipBeeps() async throws {
        let (model, studio, _) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session
        for selection in [Selection.none, set("c3", "c4")] {
            model.timeline.selection = selection
            model.run(.reduceNoise)
        }
        #expect(beeps == 2 && model.importJob == nil && studio.session == before, "beeps \(beeps)")
        await model.close()
    }

    /// C13 and C14: a dialogue clip and a music clip. Only the dialogue clip moves to a new file; the
    /// banner counts 1 clip and 12 dB, and one undo and one redo swap the clip back and forth.
    @Test func mixedSelectionKeepsMusic() async throws {
        let (model, studio, _) = try await open()
        let before = studio.session
        model.timeline.selection = set("c2", "c3")

        model.run(.reduceNoise)
        await until("the render ends") { model.importJob == nil }

        let (file, music) = (fileOf("c2", studio), fileOf("c3", studio))
        #expect(
            file != "f1" && music == "f1", "dialogue \(String(describing: file)), music \(String(describing: music))")
        #expect(model.alert == nil)
        let report = model.denoiseReport
        #expect(report?.clips == 1 && report?.decibels == 12, "\(String(describing: report))")
        await until("the banner shows") { model.shown.banners.contains { $0.key.hasPrefix("denoiseReport") } }
        let banner = try #require(model.shown.banners.first { $0.key.hasPrefix("denoiseReport") })
        #expect(banner.kind == .info && banner.announcement == .medium)
        let after = studio.session
        try studio.undo()
        #expect(studio.session == before, "one undo step")
        try studio.redo()
        #expect(studio.session == after, "redo")
        await model.close()
    }

    /// C14: the result banner text in English and Spanish, with the one clip form, and the cancel
    /// text.
    @Test func resultBanner() throws {
        let tables = try ["en", "es"].map { try stringsTable($0) }
        func text(_ clips: Int, _ table: [String: String]) -> String {
            L10n.denoiseResult(clips: clips, decibels: 12) { table[$0.rawValue] ?? $0.rawValue }
        }
        #expect(text(3, tables[0]) == "Reduced noise in 3 clips by 12 dB.")
        #expect(text(1, tables[0]) == "Reduced noise in 1 clip by 12 dB.")
        #expect(text(3, tables[1]) == "Ruido reducido en 3 clips, 12 dB.")
        #expect(text(1, tables[1]) == "Ruido reducido en 1 clip, 12 dB.")
        #expect(tables[0][L10n.denoiseCanceled.rawValue] == "Noise reduction canceled. No clip changed.")
        #expect(tables[1][L10n.denoiseCanceled.rawValue] == "Reducción de ruido cancelada. Ningún clip cambió.")
    }

    /// C14: the banner Cancel changes no clip, adds no file and no undo step, shows no alert, and
    /// VoiceOver reads the cancel text once.
    @Test func cancelChangesNoClip() async throws {
        let (model, studio, _) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        let hold = BlockHold()
        defer { hold.release() }
        studio.environment.importStep = { hold.step() }
        let before = studio.session
        model.timeline.selection = set("c1")

        model.run(.reduceNoise)
        await until("the render holds") { hold.held }
        model.cancelImport()
        hold.release()
        await until("the render ends") { model.importJob == nil }

        let clips = studio.url.appending(path: clipsFolderName)
        #expect(studio.session == before && !studio.canUndo && model.alert == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path) == ["f1.wav"], "a new file stays")
        #expect(heard == [L10n.denoiseCanceled.text], "\(heard)")
        #expect(model.denoiseReport == nil)
        await model.close()
    }

    /// C13: a right-click on a clip with no role shows the item, on; on a music clip it shows none.
    @Test func theLaneMenuShowsTheItem() async throws {
        let (model, studio) = try await timelineModel(try await Self.rolesPackage(in: folder.url), app: app)
        let (window, view) = standaloneLanes(model, studio)
        func item(y: Double) throws -> NSMenuItem? {
            let menu = try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: 120, y: y), in: view)))
            return menu.items.first { $0.title == L10n.menuToolsReduceNoise.text }
        }
        #expect(try item(y: 10)?.isEnabled == true, "a clip with no role")
        #expect(try item(y: 210) == nil, "a music clip")
        window.close()
        await model.close()
    }

    /// C10 and C14: each render error shows its key, a full disk the space text, a transcript that
    /// did not load the text that names it, and another session refusal the session text.
    @Test func eachRenderErrorShowsItsKey() {
        let cases: [(ClipRenderError, String)] = [
            (.space(needed: 2, free: 1), L10n.errorDenoiseSpace.text),
            (.write(file: "Clips/f1 NR.wav", errno: ENOSPC), L10n.errorDenoiseSpace.text),
            (.write(file: "Clips/f1 NR.wav", errno: EIO), L10n.errorDenoiseWrite.format(Int(EIO))),
            (.sourceUnreadable(file: "f1.wav", errno: EIO), L10n.errorDenoiseUnreadable.format("f1.wav", Int(EIO))),
            (.sourceMissing(file: "f1.wav"), L10n.errorDenoiseMissing.format("f1.wav")),
            (.notDownloaded(file: "f1.wav"), L10n.errorDenoiseNotDownloaded.format("f1.wav")),
            (.trackRole(clip: "c1", role: .music), L10n.errorDenoiseTrackRole.text),
            (.mixedTreatments(clips: ["a", "b"]), L10n.errorDenoiseMixed.text),
            (.effectUnavailable(status: -3000), L10n.errorDenoiseUnavailable.format(-3000)),
            (.engine(status: -10868), L10n.errorDenoiseEngine.format(-10868)),
            (.session(.transcriptNotLoaded([TranscriptID(1)])), L10n.errorTranscriptUnloaded.text),
            (.session(.unknownClip("c1")), L10n.errorSessionOther.text),
        ]
        for (error, text) in cases {
            #expect(L10n.message(for: .clipRender(error)) == text, "\(error)")
        }
        #expect(L10n.message(for: .clipRenderYielded) == L10n.errorDenoiseYielded.text)
    }
}
