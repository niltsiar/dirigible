import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit > Replace and Edit > Paste to Fill Selection in the session window (decision 0053). Each
/// package has tracks t1 to t3 with a clip c1 to c3 of 10 s (480,000 frames) from 0.
@Suite(.serialized) @MainActor struct ReplaceFillWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func package(_ name: String) async throws -> URL {
        let folder = self.folder.url.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await timelinePackage(in: folder, tracks: 3, seconds: 10, audio: true)
    }

    func open(_ name: String = "a") async throws -> (SessionWindow, Studio) {
        let (model, studio, _, _) = try await openLanes(app, try await package(name))
        return (model, studio)
    }

    /// A clipboard of `length` frames of t1.
    func copy(_ model: SessionWindow, frames length: Int = 48_000) {
        model.timeline.marks = Marks(inPoint: 0, outPoint: Frames(length), tracks: ["t1"])
        model.run(.copy)
    }

    func run(_ model: SessionWindow, _ command: TimelineCommand) async {
        model.run(command)
        await until("the run ends") { model.importJob == nil }
    }

    /// C16: the items are on with a range on a track, a clipboard, and an idle studio. Control: with
    /// no clipboard, a clip set, a range with no track, no selection, a take, a paste run, or no
    /// session window, each is off. Paste to Fill Selection stays on above the fill limit, and the
    /// fill shows the limit text and changes nothing.
    func menuStates(_ command: TimelineCommand) async throws {
        let (model, studio) = try await open()
        app.key = model
        let range = Marks(inPoint: 96_000, outPoint: 240_000, tracks: ["t2"])
        let set = try #require(ClipSet(["c2"]))
        copy(model)
        let cases: [(String, Selection, Bool)] = [
            ("a range on a track", .range(range), true), ("a clip set", .clips(set), false),
            ("a range with no track", .range(Marks(inPoint: 96_000, outPoint: 240_000)), false),
            ("one point", .range(Marks(inPoint: 96_000, tracks: ["t2"])), false), ("no selection", .none, false),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(command) == on && app.isOn(command) == on, "\(name)")
        }

        model.timeline.selection = .range(range)
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(command), "a take")
        studio.transport = .idle
        model.importJob = ImportJob(visible: false)
        #expect(!model.isOn(command), "a paste run")
        model.importJob = nil
        #expect(model.isOn(command), "after the run")
        app.clipboard = nil
        #expect(!model.isOn(command), "no clipboard")
        app.key = nil
        #expect(!app.isOn(command), "no session window")
        await model.close()
    }

    @Test func replaceMenuStates() async throws { try await menuStates(.replace) }

    @Test func fillMenuStates() async throws {
        try await menuStates(.fill)
        let (model, studio) = try await open("limit")
        copy(model, frames: 100)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 480_000, tracks: ["t2"])
        let before = studio.session

        #expect(model.isOn(.fill), "on above the limit")
        model.run(.fill)

        #expect(model.alert == .error(.session(.fillTooManyClips(needed: 4_800))), "\(String(describing: model.alert))")
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// C17: after a Replace, the selection is the new range and the playhead is at the in point, and
    /// the later audio of all tracks moves. After a fill, the range stays and nothing moves. A
    /// clipboard of another package ends the same way, after its copy.
    @Test func selectionAfterReplaceAndFill() async throws {
        let (model, studio) = try await open()
        copy(model)
        await studio.perform(.seek(.frame(5)))
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 240_000, tracks: ["t2"])

        model.run(.replace)

        #expect(model.timeline.selection == .range(Marks(inPoint: 96_000, outPoint: 144_000, tracks: ["t2"])))
        await until("the playhead is at the in point") { studio.playhead == 96_000 }
        #expect(studio.session.tracks.map { $0.clips.last?.end } == [Frames(384_000), 384_000, 384_000])
        try studio.undo()
        #expect(studio.session.end == 480_000)

        await studio.perform(.seek(.frame(5)))
        let range = Marks(inPoint: 96_000, outPoint: 240_000, tracks: ["t2"])
        model.timeline.marks = range

        model.run(.fill)

        #expect(model.timeline.selection == .range(range) && studio.playhead == 5)
        #expect(studio.session.tracks.map { $0.clips.last?.end } == [Frames(480_000), 480_000, 480_000])
        #expect(studio.session.tracks[1].clips.filter { $0.start >= 96_000 && $0.end <= 240_000 }.count == 3)
        await model.close()

        let (a, _) = try await open("from")
        copy(a)
        let (b, other) = try await open("into")
        b.timeline.marks = Marks(inPoint: 0, outPoint: 96_000, tracks: ["t3"])
        await run(b, .replace)
        #expect(b.timeline.selection == .range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t3"])))
        #expect(other.session.files["f1 2"] != nil && b.alert == nil, "the file came from the other package")
        await a.close()
        await b.close()
    }

    /// C17: one announcement for each edit. A Replace of the same package and a fill of another
    /// package each give the text of their kind once, and a paste run that shows its banner gives
    /// the banner and then the effect, not "Pasted.".
    @Test func announcesTheEffect() async throws {
        let (a, _) = try await open("from")
        copy(a)
        let (model, _) = try await open("into")
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 240_000, tracks: ["t2"])

        await run(model, .replace)
        #expect(heard == [L10n.replaceDone.format(SilenceReview.seconds(48_000, rate: 48_000))], "\(heard)")

        heard = []
        await run(model, .fill)
        #expect(heard == [L10n.fillDone.format(SilenceReview.seconds(144_000, rate: 48_000), 3)], "\(heard)")
        await a.close()
        await model.close()
    }

    /// C17, C20: the numbers of the two texts, with one decimal in the number format of the locale.
    @Test func theTextsHoldTheNumbers() {
        let table: (L10n) -> String = {
            $0 == .replaceDone ? "Replaced %@ seconds" : "Filled %1$@ seconds with %2$lld clips"
        }
        let english = Locale(identifier: "en")
        #expect(
            SessionWindow.replacedText(clipboard: 72_000, rate: 48_000, table: table, locale: english)
                == "Replaced 1.5 seconds")
        #expect(
            SessionWindow.filledText(
                range: 96_000..<240_000, rate: 48_000, clips: 3, table: table, locale: Locale(identifier: "es"))
                == "Filled 3,0 seconds with 3 clips")
    }
}
