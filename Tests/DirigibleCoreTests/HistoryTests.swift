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

    /// Run 14 C7: a revert to a backup keeps the current recording, as an undo does.
    @Test func revertKeepsTheRecording() throws {
        var current = Session(sampleRate: 48_000)
        try current.addTrack("t1", name: "Host", layout: .mono)
        var backup = current
        try backup.renameTrack("t1", to: "Old")
        let take = Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: ["t1"])
        try current.setRecording(take)

        let reverted = try? current.reverted(to: backup)

        #expect(reverted?.recording == take, "the revert keeps the recording")
        #expect(reverted?.track("t1")?.name == "Old")
    }

    /// Run 14 C7: a backup that removes an armed track, or changes its route or layout, throws.
    @Test func revertRefusesToRemoveAnArmedTrack() throws {
        var current = Session(sampleRate: 48_000)
        try current.addTrack("t1", name: "Host", layout: .mono)
        try current.setRoute(Route.device(uid: "usb-1", channels: .mono(1)), track: "t1")
        var removed = current
        try removed.removeTrack("t1")
        var routed = current
        try routed.setRoute(Route.device(uid: "usb-1", channels: .mono(2)), track: "t1")
        var stereo = current
        try stereo.setLayout(.stereo, route: Route.device(uid: "usb-1", channels: .stereo(1, 2)), track: "t1")
        try current.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: ["t1"]))

        for backup in [removed, routed, stereo] {
            #expect(throws: SessionError.trackInRecording("t1"), "the revert refuses a change to an armed track") {
                try current.reverted(to: backup)
            }
        }
    }

    /// Track fader code gate 1 item 1: the reset of a double-click joins the edit of its first
    /// click, so the double-click is one undo step. A result equal to the state before that edit
    /// leaves no entry, and no redo entry stays.
    @Test mutating func anAmendJoinsTheLastEdit() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        try history.edit { try $0.setGain(Gain(dB: -36)!, track: "t1") }
        let revision = history.revision

        try history.amend { try $0.setGain(Gain(dB: 3)!, track: "t1") }
        #expect(history.session.track("t1")?.gain.dB == 3)
        #expect(history.revision == revision + 1, "an amend is a change")
        try history.undo()
        #expect(history.session.track("t1")?.gain == .zero, "one undo gives the state before the joined edit")
        try history.redo()

        try history.amend { try $0.setGain(.zero, track: "t1") }
        #expect(history.session.track("t1")?.gain == .zero)
        #expect(!history.canRedo, "no redo entry")
        try history.undo()
        #expect(history.session.tracks.isEmpty, "the joined edit that changed nothing has no entry")
    }

    /// Code gate 2: an amend of only the recording records nothing, as `edit` does.
    @Test mutating func anAmendOfOnlyTheRecordingRecordsNothing() throws {
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        try history.edit { try $0.setGain(Gain(dB: -36)!, track: "t1") }
        try history.undo()
        let revision = history.revision
        let take = Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 9, armedTracks: [])

        try history.amend { try $0.setRecording(take) }

        #expect(history.session.recording == take)
        #expect(history.revision == revision, "code gate 2: no new revision")
        #expect(history.canRedo, "code gate 2: the redo entry stays")
    }

    /// C11 of run 2026-10-12-mcp-in-app: each entry keeps its agent through undo, redo, and amend.
    @Test mutating func agentFollowsTheEntry() throws {
        let agent = AgentName(title: "Claude Code", clientName: nil)
        try history.edit { try $0.addTrack("t1", name: "Host", layout: .mono) }
        #expect(history.undoAgent == nil, "a user edit has no agent")
        try history.edit(agent: agent) { try $0.renameTrack("t1", to: "Guest") }
        #expect(history.undoAgent == agent)

        try history.undo()
        #expect(history.redoAgent == agent, "the redo entry keeps the agent")
        #expect(history.undoAgent == nil)
        try history.redo()
        #expect(history.undoAgent == agent, "the undo entry keeps the agent after a redo")

        try history.amend { try $0.renameTrack("t1", to: "Co-host") }
        #expect(history.undoAgent == agent, "an amend joins the entry and keeps its agent")
        try history.undo()
        #expect(history.session.track("t1")?.name == "Host")
    }
}
