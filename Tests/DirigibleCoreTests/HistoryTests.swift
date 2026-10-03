import DirigibleCore
import Testing

struct HistoryTests {
    var history = History(Session(sampleRate: 48_000))

    @Test mutating func anEditRecordsOneEntry() throws {
        try history.edit { session in
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
        }
        #expect(history.session.tracks.map(\.id) == ["t1", "t2"])
        #expect(history.canUndo)

        try history.undo()
        #expect(history.session == Session(sampleRate: 48_000))
        #expect(!history.canUndo)
    }

    /// Run 9a code gate 1: the export report banner goes at the first session change, so the
    /// revision counts each recorded edit, undo, and redo, and no edit that changes nothing.
    @Test mutating func theRevisionCountsEachChange() throws {
        #expect(history.revision == 0)
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        history.edit { _ in }
        #expect(history.revision == 1, "after an edit and an edit that changes nothing")
        try history.undo()
        try history.redo()
        #expect(history.revision == 3, "after an undo and a redo")
    }

    @Test mutating func anEditThatChangesNothingRecordsNothing() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        try history.undo()
        try history.edit { try $0.setMarker(Marker(id: "m1", name: "A", position: 0, kind: .marker)) }
        try history.undo()
        #expect(history.canRedo)

        history.edit { _ in }
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    @Test mutating func aThrowingEditRecordsNothingAndChangesNothing() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        let before = history.session
        #expect(throws: SessionError.duplicateID("t1")) {
            try history.edit { session in
                try session.renameTrack("t1", to: "Changed")
                try session.addTrack("t1", name: "Again", layout: .mono)
            }
        }
        #expect(history.session == before)
        try history.undo()
        #expect(!history.canUndo)
    }

    @Test mutating func undoAndRedoRestoreTheExactValues() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        let first = history.session
        try history.edit { try $0.renameTrack("t1", to: "Anna") }
        let second = history.session

        try history.undo()
        #expect(history.session == first)
        try history.redo()
        #expect(history.session == second)
        #expect(!history.canRedo)
    }

    @Test mutating func aNewEditClearsRedo() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        try history.undo()
        try history.edit { try $0.addTrack("t2", name: "Guest", layout: .mono) }
        #expect(!history.canRedo)
        try history.redo()
        #expect(history.session.tracks.map(\.id) == ["t2"])
    }

    @Test mutating func undoAndRedoKeepTheRecording() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        let take = Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: ["t1"])
        try history.edit { try $0.setRecording(take) }
        try history.edit { try $0.renameTrack("t1", to: "Anna") }
        try history.edit { try $0.setRecording(nil) }

        try history.undo()
        #expect(history.session.recording == nil)
        #expect(history.session.track("t1")?.name == "Host")
        try history.redo()
        #expect(history.session.recording == nil)
        #expect(history.session.track("t1")?.name == "Anna")
    }

    @Test mutating func anEditOfOnlyTheRecordingRecordsNothing() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        try history.undo()
        let take = Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: [])
        try history.edit { try $0.setRecording(take) }
        #expect(history.session.recording == take)
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    @Test mutating func undoRefusesToRemoveAnArmedTrack() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        let take = Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: ["t1"])
        try history.edit { try $0.setRecording(take) }
        let before = history

        #expect(throws: SessionError.trackInRecording("t1")) { try history.undo() }
        #expect(history == before)
    }

    @Test mutating func undoAndRedoRefuseAnotherRouteOrLayoutOnAnArmedTrack() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        try history.edit { try $0.setRoute(Route.device(uid: "usb-1", channels: .mono(1)), track: "t1") }
        try history.edit { try $0.setLayout(.stereo, route: nil, track: "t1") }
        try history.undo()
        // The undo entry has no route on t1, and the redo entry has the stereo layout.
        let take = Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: ["t1"])
        try history.edit { try $0.setRecording(take) }
        let before = history

        #expect(throws: SessionError.trackInRecording("t1")) { try history.undo() }
        #expect(throws: SessionError.trackInRecording("t1")) { try history.redo() }
        #expect(history == before)
    }

    @Test mutating func undoAndRedoWithNoEntryChangeNothing() throws {
        let before = history
        try history.undo()
        try history.redo()
        #expect(history == before)
    }
}
