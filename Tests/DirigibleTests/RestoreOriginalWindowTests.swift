import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Restore Original Audio in the session window (decision 0057 D6, criterion C6). Track t1
/// has the clip R (+5 dB, 3 s) on "f NR", a 12 dB noise render of f from frame 100 000 with 1 dB
/// added; track t2 has the clip P (3 s) on the plain file g. No WAV is on the disk: a restore reads
/// no audio.
@Suite(.serialized) @MainActor struct RestoreOriginalWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The writes run off the main actor.
    @concurrent nonisolated static func renderedPackage(in folder: URL) async throws -> URL {
        let url = folder.appending(path: "rendered.dirigible")
        try Session.create(at: url, sampleRate: 48_000)
        var session = Session(sampleRate: 48_000)
        let origin = RenderOrigin(
            source: "f", offset: 100_000, treatment: Treatment(.noise(.standard)), addedGain: Gain(dB: 1)!)
        for file in [
            AudioFile(id: "f", path: "f.wav", layout: .mono, length: 1_000_000),
            AudioFile(id: "g", path: "g.wav", layout: .mono, length: 1_000_000),
            AudioFile(id: "f NR", path: "Clips/f NR.wav", layout: .mono, length: 500_000, origin: origin),
        ] {
            try session.addFile(file)
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(
            Clip(id: "R", file: "f NR", start: 0, offset: 10_000, length: 144_000, gain: Gain(dB: 5)!), on: "t1")
        try session.place(Clip(id: "P", file: "g", start: 0, offset: 0, length: 144_000), on: "t2")
        try session.write(to: url)
        return url
    }

    func open() async throws -> (SessionWindow, Studio) {
        let (model, studio, _, _) = try await openLanes(app, try await Self.renderedPackage(in: folder.url))
        return (model, studio)
    }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    /// C6: the item is on with an idle studio and a selection that holds a clip on a rendered file.
    /// Control: no selection, a plain clip, a range on the plain track, a take, and an import turn
    /// it off.
    @Test func menuStateForEachStartState() async throws {
        let (model, studio) = try await open()
        let cases: [(String, Selection, Bool)] = [
            ("no selection", .none, false), ("a plain clip", set("P"), false), ("a rendered clip", set("R"), true),
            ("a rendered and a plain clip", set("R", "P"), true),
            ("a range on the rendered track", .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t1"])), true),
            ("a range on the plain track", .range(Marks(inPoint: 0, outPoint: 1000, tracks: ["t2"])), false),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(.restoreOriginal) == on, "\(name)")
        }

        model.timeline.selection = set("R")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.restoreOriginal), "a take")
        studio.transport = .importing(ImportRun(name: "x", kind: .file, flags: ImportFlags()))
        #expect(!model.isOn(.restoreOriginal), "an import run")
        studio.transport = .idle
        #expect(model.isOn(.restoreOriginal), "after the run")
        await model.close()
    }

    /// C6: the rendered clip moves to its root at the frame that it played, with the added gain
    /// taken off; the plain clip stays. One undo entry: one Undo puts back the rendered file, and
    /// no older entry is left. Redo restores again.
    @Test func restoreMovesTheSelection() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        model.timeline.selection = set("R", "P")

        model.run(.restoreOriginal)

        #expect(
            studio.session.clip("R")?.clip
                == Clip(id: "R", file: "f", start: 0, offset: 110_000, length: 144_000, gain: Gain(dB: 4)!))
        #expect(studio.session.clip("P")?.clip == before.clip("P")?.clip)
        #expect(studio.session.files["f NR"] == before.files["f NR"], "the rendered file stays in the pool")
        let after = studio.session
        try studio.undo()
        #expect(studio.session == before, "Undo puts back the rendered file")
        #expect(!studio.canUndo, "one undo entry")
        try studio.redo()
        #expect(studio.session == after, "redo")
        await model.close()
    }

    /// C6: a selection with no rendered clip beeps and changes nothing.
    @Test func noRenderedClipBeeps() async throws {
        let (model, studio) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session
        for selection in [Selection.none, set("P")] {
            model.timeline.selection = selection
            model.run(.restoreOriginal)
        }
        #expect(beeps == 2 && studio.session == before && !studio.canUndo, "beeps \(beeps)")
        await model.close()
    }

    /// C6: a right-click on the rendered clip shows the item, on, right after Reduce Noise; on the
    /// plain clip of a track with no role it shows Reduce Noise and no Restore item.
    @Test func theLaneMenuShowsTheItem() async throws {
        let (model, studio) = try await timelineModel(try await Self.renderedPackage(in: folder.url), app: app)
        let (window, view) = standaloneLanes(model, studio)
        func titles(y: Double) throws -> [String] {
            let menu = try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: 120, y: y), in: view)))
            return menu.items.map { $0.title + ($0.isEnabled || $0.isSeparatorItem ? "" : " (off)") }
        }
        let restore = L10n.menuToolsRestoreOriginal.text
        let rendered = try titles(y: 10)
        let at = try #require(rendered.firstIndex(of: L10n.menuToolsReduceNoise.text), "\(rendered)")
        #expect(rendered.dropFirst(at + 1).first == L10n.menuToolsRepairSound.text, "\(rendered)")
        #expect(rendered.dropFirst(at + 2).first == restore, "\(rendered)")
        let plain = try titles(y: 110)
        #expect(plain.contains(L10n.menuToolsReduceNoise.text) && !plain.contains(restore), "\(plain)")
        window.close()
        await model.close()
    }
}
