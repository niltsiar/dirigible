import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The ripple items of the Edit menu (decision 0037, criteria C2, C6, C8, C9, and C10) on a real
/// Studio. Tracks t1 to t3 each have clip c<n> of file f1, split at 48 000 and 96 000, so each
/// track has c<n> at 0..<48 000, c<n>@48000 at 48 000..<96 000, and c<n>@96000 to 2 880 000.
@Suite(.serialized) @MainActor struct RippleWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let url = try await timelinePackage(in: folder.url, tracks: 3, seconds: 60)
        // The split goes in the file, so the window opens with no undo entry.
        var session = try Session(contentsOf: url)
        _ = try session.splitClips(at: [48_000, 96_000], on: session.tracks.map(\.id))
        try session.write(to: url)
        let opened = try await openLanes(app, url)
        #expect(opened.2.makeFirstResponder(opened.3.lanes))
        return opened
    }

    func starts(_ studio: Studio, _ track: TrackID) -> [Frames] {
        studio.session.track(track).map { $0.clips.map(\.start) } ?? []
    }

    /// C2: the Marks of the range of c1@48000 on t1. Control: the scope of the Marks tracks moves
    /// only t1.
    @Test func aRangeRippleDeleteKeepsEveryTrackInSync() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])

        model.run(.deleteCloseGap)

        for track in ["t1", "t2", "t3"] as [TrackID] {
            #expect(starts(studio, track) == [0, 48_000], "\(track): the clip after R starts 48 000 earlier")
        }
        #expect(model.timeline.marks == Marks(), "the Marks clear")
        await until("the playhead goes to R.start") { studio.playhead == 48_000 }
        await model.close()
    }

    /// C6: each ripple is one undo entry. Control: a loop of single edits makes two entries.
    @Test func eachRippleIsOneUndoEntry() async throws {
        let (model, studio, _, _) = try await open()
        let commands: [TimelineCommand] = [
            .cut, .deleteCloseGap, .cutSelectedTracks, .deleteCloseGapSelectedTracks, .insert,
        ]
        for command in commands {
            model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"])
            if command == .insert { model.run(.copy) }
            let before = studio.session
            model.run(command)
            #expect(studio.session != before, "\(command) changes the session")
            model.undo()
            #expect(studio.session == before, "\(command): one undo gives the old session")
        }
        await model.close()
    }

    /// C8: Shift-Backspace from the lanes ripples the selection. No selection: nothing.
    @Test func shiftBackspaceRipplesFromTheLanes() async throws {
        let (model, studio, window, _) = try await open()
        model.timeline.marks = Marks()
        let before = studio.session
        app.timeline(.deleteCloseGap, event: try cgKey(51, .maskShift), in: window)
        #expect(studio.session == before && !studio.canUndo, "no selection: nothing")

        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t2"])
        app.timeline(.deleteCloseGap, event: try cgKey(51, .maskShift), in: window)

        #expect(starts(studio, "t1") == [0, 48_000] && starts(studio, "t2") == [0, 48_000])
        await model.close()
    }

    /// C8: a focused track name field gets Shift-Backspace, and the session does not change.
    /// Control: an item that does not forward its key ripples.
    @Test func shiftBackspaceGoesToAFocusedField() async throws {
        let (model, studio, window, _) = try await open()
        let marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        model.timeline.marks = marks
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let session = studio.session
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)

        app.timeline(.deleteCloseGap, event: event, in: window)

        #expect(editor.string == "T", "the field deletes one character")
        #expect(studio.session == session && model.timeline.marks == marks)
        await model.close()
    }

    /// C9: Insert moves every track right by the clipboard length at the playhead and pastes on
    /// the paste targets. Control: a plain paste overwrites the material at the playhead.
    @Test func insertPushesEveryTrackAndPastes() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        await studio.perform(.seek(.frame(60_000)))

        model.run(.insert)

        let t1 = studio.session.track("t1").map { $0.clips.map(\.range) } ?? []
        #expect(t1 == [0..<48_000, 48_000..<60_000, 60_000..<108_000, 108_000..<144_000, 144_000..<2_928_000])
        let t2 = studio.session.track("t2").map { $0.clips.map(\.range) } ?? []
        #expect(t2 == [0..<48_000, 48_000..<60_000, 108_000..<144_000, 144_000..<2_928_000], "silence on t2")
        #expect(model.timeline.marks == Marks(inPoint: 60_000, outPoint: 108_000, tracks: ["t1"]))
        await model.close()
    }

    /// C9, probe K5: Command-I is not a field key, so Insert runs with a focused track name field,
    /// and the field text stays.
    @Test func insertRunsWithAFocusedField() async throws {
        let (model, studio, window, _) = try await open()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        model.run(.copy)
        let editor = try await focusName(in: window)
        let text = editor.string
        let before = studio.session

        app.timeline(.insert, event: commandKey("i", code: 34, in: window), in: window)

        #expect(studio.session != before, "Insert ran")
        #expect(editor.string == text, "the field text stays")
        await model.close()
    }

    /// C9: with no clipboard, Insert does nothing and makes no undo entry.
    @Test func insertWithNoClipboardDoesNothing() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        model.run(.insert)
        #expect(studio.session == before && !studio.canUndo && model.alert == nil)
        await model.close()
    }

    /// C10: a twin ripples only the selected tracks. Control: the all-tracks scope moves t2.
    @Test func aTwinLeavesTheOtherTracks() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        let before = studio.session

        model.run(.cutSelectedTracks)

        #expect(starts(studio, "t1") == [0, 48_000])
        #expect(studio.session.track("t2") == before.track("t2") && studio.session.track("t3") == before.track("t3"))
        #expect(model.clipboard?.lanes.map(\.source) == ["t1"])
        model.undo()
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        model.run(.deleteCloseGapSelectedTracks)
        #expect(starts(studio, "t1") == [0, 48_000] && studio.session.track("t2") == before.track("t2"))
        await model.close()
    }
}
