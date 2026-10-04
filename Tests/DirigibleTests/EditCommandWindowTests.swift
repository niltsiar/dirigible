import AppKit
import DirigibleCore
import DirigibleTimeline
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

    /// Decision 0037 (C7): Cut closes the gap on every track. Control: the Release 1 clear keeps
    /// the gap on t2 (0..<48 000 and 96 000..<2 880 000).
    @Test func cutPutsTheExcerptOnTheClipboardAndClosesTheGap() async throws {
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
        for track in ["t1", "t2", "t3"] as [TrackID] {
            #expect(Array(studio.session.track(track)!.clips).map(\.range) == [0..<48_000, 48_000..<2_832_000])
        }
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

    /// Too few tracks under the first selected track: nothing changes, and the alert gives the
    /// track count of the copy (code gate 1 item 4). A source track that an edit removed: nothing
    /// changes, and no alert shows. Controls: a paste on every selected track with no count check
    /// pastes one lane on t3; a nil for too few tracks shows no alert.
    @Test func pasteWithTooFewTracksChangesNothing() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"])
        model.run(.copy)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t3"])
        var before = studio.session
        model.run(.paste)
        #expect(studio.session == before && !studio.canUndo)
        #expect(model.alert == .error(.session(.trackCount(2))))

        model.alert = nil
        try studio.edit { s throws(SessionError) in try s.removeTrack("t1") }
        model.timeline.marks = Marks()
        before = studio.session
        model.run(.paste)
        #expect(studio.session == before && model.alert == nil)
        await model.close()
    }

    /// An Undo removes the pool file that the clipboard names: Paste does nothing and shows no
    /// alert (code gate 1 item 3). Controls: no file check shows the `.unknownFile` alert; a file
    /// check that refuses a present file fails the other paste tests.
    @Test func pasteOfAFileThatAnUndoRemovedDoesNothing() async throws {
        let (model, studio, _, _) = try await open()
        try studio.edit { s throws(SessionError) in
            try s.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
            try s.place(Clip(id: "x", file: "f2", start: 0, offset: 0, length: 48_000), on: "t1")
        }
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        model.undo()
        #expect(studio.session.files["f2"] == nil)
        let before = studio.session

        model.run(.paste)

        #expect(studio.session == before && !studio.canUndo)
        #expect(model.alert == nil)
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

    /// Fades C22 (decision 0035): Command-F on a whole clip is one undo entry, with the lanes or the
    /// track name field focused (probe K1: the field ignores Command-F). A range with no clip edge
    /// makes no entry.
    @Test func fadeIsOneUndoEntry() async throws {
        let (model, studio, window, _) = try await open()
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])

        app.timeline(.fade, event: commandKey("f", code: 3, in: window), in: window)

        #expect(studio.session.clip("c1")?.clip.fades == Fades(fadeIn: 24_000, fadeOut: 24_000))
        #expect(studio.session.clip("c2")?.clip.fades == .zero, "t2 is not selected")
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "one entry, and Undo restores the fades")

        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 192_000, tracks: ["t1"])
        app.timeline(.fade, event: commandKey("f", code: 3, in: window), in: window)
        #expect(studio.session == before && !studio.canUndo, "no clip edge: no entry")

        let editor = try await focusName(in: window)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])
        app.timeline(.fade, event: commandKey("f", code: 3, in: window), in: window)
        #expect(studio.session.clip("c1")?.clip.fades == Fades(fadeIn: 24_000, fadeOut: 24_000), "field focused")
        #expect(window.firstResponder === editor && studio.canUndo)
        await model.close()
    }

    /// C10 (run 11c-2): Command-F at a butt join makes the crossfade, and with Select All the free
    /// fades too, in one undo entry, with the lanes or the track name field focused. t1 has c1 at
    /// 0 ..< 96,000 and b at 96,000 ..< 144,000 with frames from 192,000 of f1, so the join has
    /// handles and is not seamless. A take: `EditTakeTests.editsDoNothingDuringATake`.
    @Test func crossfadeIsOneUndoEntry() async throws {
        let (model, studio, window, _) = try await open()
        try studio.edit { s throws(SessionError) in
            try s.clear(96_000..<2_880_000, on: "t1")
            try s.place(Clip(id: "b", file: "f1", start: 96_000, offset: 192_000, length: 48_000), on: "t1")
        }
        let before = studio.session
        func crossfades(_ id: ClipID) -> Crossfades? { studio.session.clip(id)?.clip.crossfades }

        model.timeline.marks = Marks(inPoint: 95_000, outPoint: 97_500, tracks: ["t1"])
        app.timeline(.fade, event: commandKey("f", code: 3, in: window), in: window)
        #expect(
            crossfades("c1") == Crossfades(start: 0, end: 2_000) && crossfades("b") == Crossfades(start: 2_000, end: 0))
        model.undo()
        #expect(studio.session == before, "one entry")

        model.timeline.marks = Marks(inPoint: 0, outPoint: 144_000, tracks: ["t1"])
        app.timeline(.fade, event: commandKey("f", code: 3, in: window), in: window)
        #expect(crossfades("c1") == Crossfades(start: 0, end: 960))
        #expect(studio.session.clip("c1")?.clip.fades == Fades(fadeIn: 24_000, fadeOut: 0))
        #expect(studio.session.clip("b")?.clip.fades == Fades(fadeIn: 0, fadeOut: 24_000))
        model.undo()
        #expect(studio.session == before, "the crossfade and the fades are one entry")

        let editor = try await focusName(in: window)
        model.timeline.marks = Marks(inPoint: 95_000, outPoint: 97_500, tracks: ["t1"])
        app.timeline(.fade, event: commandKey("f", code: 3, in: window), in: window)
        #expect(crossfades("c1") == Crossfades(start: 0, end: 2_000), "field focused")
        #expect(window.firstResponder === editor)
        await model.close()
    }
}
