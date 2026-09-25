import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criteria 15, 16, and 19: Cut, Copy, Paste, and Delete on a real Studio. Tracks
/// t1 to t3 each have a clip of file f1 at 0..<2 880 000 (60 s).
@Suite(.serialized) @MainActor struct EditCommandWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open(_ name: String = "a") async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let folder = self.folder.url.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let opened = try await openLanes(app, try await timelinePackage(in: folder, tracks: 3, seconds: 60))
        #expect(opened.2.makeFirstResponder(opened.3.lanes))
        return opened
    }

    func clip(_ id: ClipID, _ range: Range<Frames>) -> Clip {
        Clip(
            id: id, file: "f1", start: range.lowerBound, offset: range.lowerBound,
            length: range.upperBound - range.lowerBound)
    }

    /// Backspace with the lanes focused, through the item action. Controls: a Delete on every track
    /// cuts t2; a Backspace forward with the lanes focused clears nothing.
    @Test func deleteClearsTheSelectedTracksOnly() async throws {
        let (model, studio, window, _) = try await open()
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])

        app.timeline(.delete, event: try cgKey(51), in: window)

        #expect(
            Array(studio.session.track("t1")!.clips) == [clip("c1", 0..<48_000), clip("c1@96000", 96_000..<2_880_000)])
        #expect(studio.session.track("t2") == before.track("t2") && studio.session.track("t3") == before.track("t3"))
        #expect(model.clipboard == nil)
        model.undo()
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    @Test func cutPutsTheExcerptOnTheClipboardAndClears() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"])

        model.run(.cut)

        #expect(model.clipboard?.length == 48_000)
        #expect(model.clipboard?.lanes.map(\.source) == ["t1", "t2"])
        #expect(
            model.clipboard?.lanes.map(\.clips) == [
                [Clip(id: "c1", file: "f1", start: 0, offset: 48_000, length: 48_000)],
                [Clip(id: "c2", file: "f1", start: 0, offset: 48_000, length: 48_000)],
            ])
        #expect(Array(studio.session.track("t2")!.clips).map(\.range) == [0..<48_000, 96_000..<2_880_000])
        await model.close()
    }

    /// Control: a Copy that clears the range changes the session and writes it.
    @Test func copyMakesNoEntryAndNoWrite() async throws {
        let (model, studio, _, _) = try await open()
        let saves = SaveCounter(studio)
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t3"])

        model.run(.copy)

        #expect(model.clipboard?.lanes.map(\.source) == ["t3"])
        #expect(studio.session == before && !studio.canUndo)
        await studio.settle()
        #expect(saves.writes == 0)
        await model.close()
    }

    @Test func noSelectionDoesNothing() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        for marks in [
            Marks(), Marks(inPoint: 0, outPoint: nil, tracks: ["t1"]), Marks(inPoint: 0, outPoint: 1_000, tracks: []),
        ] {
            model.timeline.marks = marks
            model.run(.cut)
            model.run(.copy)
            model.run(.delete)
        }
        #expect(studio.session == before && model.clipboard == nil && model.alert == nil)
        await model.close()
    }

    /// Two lanes go to the first selected track and the track under it, at the playhead. The
    /// pasted range is the new selection. Control: a paste at the in point, or on the source
    /// tracks, puts other clips.
    @Test func pasteGoesToThePlayheadOnTheSelectedTracks() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"])
        model.run(.copy)
        await studio.perform(.seek(.frame(240_000)))
        model.timeline.marks = Marks(inPoint: 0, outPoint: 1_000, tracks: ["t2"])
        let before = studio.session

        model.run(.paste)

        #expect(Array(studio.session.track("t1")!.clips) == Array(before.track("t1")!.clips))
        #expect(
            Array(studio.session.track("t2")!.clips) == [
                clip("c2", 0..<240_000), Clip(id: "c1@240000", file: "f1", start: 240_000, offset: 0, length: 48_000),
                clip("c2@288000", 288_000..<2_880_000),
            ])
        #expect(Array(studio.session.track("t3")!.clips).map(\.id) == ["c3", "c2@240000", "c3@288000"])
        #expect(model.timeline.marks == Marks(inPoint: 240_000, outPoint: 288_000, tracks: ["t2", "t3"]))
        model.undo()
        #expect(studio.session == before)
        await model.close()
    }

    @Test func pasteWithNoSelectedTrackGoesToTheSourceTracks() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t3"])
        model.run(.copy)
        await studio.perform(.seek(.frame(96_000)))
        model.timeline.marks = Marks()

        model.run(.paste)

        #expect(Array(studio.session.track("t3")!.clips).map(\.id) == ["c3", "c3@96000", "c3@144000"])
        #expect(model.timeline.marks == Marks(inPoint: 96_000, outPoint: 144_000, tracks: ["t3"]))
        await model.close()
    }

    /// Too few tracks under the first selected track, and a source track that an edit removed.
    /// Control: a paste on every selected track with no count check pastes one lane on t3.
    @Test func pasteWithTooFewTracksDoesNothing() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"])
        model.run(.copy)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t3"])
        var before = studio.session
        model.run(.paste)
        #expect(studio.session == before && !studio.canUndo)

        try studio.edit { s throws(SessionError) in try s.removeTrack("t1") }
        model.timeline.marks = Marks()
        before = studio.session
        model.run(.paste)
        #expect(studio.session == before && model.alert == nil)
        await model.close()
    }

    /// Criterion 19. Control: a clipboard on the general pasteboard changes its count.
    @Test func theClipboardIsPerWindowAndLeavesThePasteboard() async throws {
        let count = NSPasteboard.general.changeCount
        let (first, _, _, _) = try await open("a")
        let (second, other, _, _) = try await open("b")
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        first.run(.cut)
        let before = other.session

        second.run(.paste)

        #expect(first.clipboard != nil && second.clipboard == nil)
        #expect(other.session == before)
        #expect(NSPasteboard.general.changeCount == count)
        let url = first.url
        await first.close()
        #expect(app.windows[url] == nil)
        await second.close()
    }
}
