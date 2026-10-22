import Testing

@testable import DirigibleCore

/// The sync state of each take, and its change (decision 0061).
struct TakeSyncTests {
    /// Probe p1 of run take-sync: take 4 of a tester session at 48 kHz, recorded at playhead 0. The
    /// capture host times and latencies give the origins 3641 and 3347, and both tracks are head
    /// trimmed to the shift -1415798 (29.496 s). Then the tester edits of the walkthrough.
    @Test func theTesterEditsGiveTheReplayStates() throws {
        var fixture = try TakeSession(tracks: 2)
        let takeStart: UInt64 = 1_223_961_550_170_000 - 69_729_167
        for (arm, host, latency, nominal) in [
            (1, 1_223_961_559_550_083 as UInt64, 156, 48_000.0), (2, 1_223_961_550_170_000, 0, 44_100),
        ] {
            let id = "take4-\(arm)-1"
            try fixture.session.addCapture(
                Capture(
                    id: CaptureID(id), deviceUID: "d\(arm)", deviceName: "D\(arm)", hostTimeNanos: host, sampleTime: 0,
                    nominalSampleRate: nominal, measuredSampleRate: nominal, latency: latency))
            try fixture.session.addFile(
                AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: 144_000_000, capture: CaptureID(id))
            )
            fixture.recordings[CaptureID(id)] = Recording(
                take: 4, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1", "t2"])
        }
        #expect(
            fixture.map.origins == [
                "take4-1-1": TakeMap.Origin(take: 4, frame: 3641), "take4-2-1": TakeMap.Origin(take: 4, frame: 3347),
            ])
        for (arm, origin) in [(1, 3641), (2, 3347)] {
            let offset = 1_415_798 - origin
            try fixture.session.place(
                Clip(
                    id: ClipID("take4-\(arm)-1"), file: FileID("take4-\(arm)-1"), start: 0, offset: Frames(offset),
                    length: Frames(144_000_000 - offset)), on: TrackID("t\(arm)"))
        }
        let tracks = fixture.tracks
        var states = [fixture.map.sync]
        func next(_ edit: (inout Session) throws -> Void) throws {
            try edit(&fixture.session)
            states.append(fixture.map.sync)
        }

        try next { try $0.rippleInsert(240_000, at: 0, on: tracks) }
        try next { try $0.rippleInsert(192_000, at: 60_624_000, on: tracks) }
        try next { try $0.rippleInsert(177_600, at: 115_200_000, on: tracks) }
        try next { try $0.rippleDelete(115_200_000..<115_377_600, on: tracks) }
        try next { try $0.rippleDelete(60_624_000..<60_816_000, on: tracks) }
        let last = try #require(fixture.session.track("t2")?.clips.last)
        #expect(last.start == 115_008_000)
        try next { try $0.nudge([last.id], by: 1) }

        let expected: [TakeSync] = [
            .inSync(offset: -1_415_798), .inSync(offset: -1_175_798), .broken(from: 60_816_000, shifts: 2),
            .broken(from: 60_816_000, shifts: 3), .broken(from: 60_816_000, shifts: 2), .inSync(offset: -1_175_798),
            .broken(from: 115_008_001, shifts: 2),
        ]
        #expect(states == expected.map { [4: $0] })
        let changes = zip(states, states.dropFirst()).map { TakeSync.change(from: $0, to: $1) }
        #expect(
            changes == [
                [TakeSync.Change(take: 4, old: expected[0], new: expected[1])],
                [TakeSync.Change(take: 4, old: expected[1], new: expected[2])], [], [],
                [TakeSync.Change(take: 4, old: expected[4], new: expected[5])],
                [TakeSync.Change(take: 4, old: expected[5], new: expected[6])],
            ])
    }

    /// Take 1 trimmed by 30 s at playhead 0, then take 2 recorded at the session end.
    @Test func aTakeAfterATrimLeavesEachTakeInSync() throws {
        var fixture = try TakeSession(tracks: 1)
        let one = try fixture.addTakeFile(take: 1, arm: 1, origin: 0, length: 28_800_000)
        try fixture.session.place(Clip(id: "take1-1-1", file: one, start: 0, offset: 0, length: 28_800_000), on: "t1")
        try fixture.session.rippleDelete(0..<1_440_000, on: ["t1"])
        let before = fixture.map.sync
        let two = try fixture.addTakeFile(take: 2, arm: 1, origin: 0, length: 480_000, playhead: 27_360_000)
        try fixture.session.place(
            Clip(id: "take2-1-1", file: two, start: 27_360_000, offset: 0, length: 480_000), on: "t1")

        let after = fixture.map.sync

        #expect(before == [1: .inSync(offset: -1_440_000)])
        #expect(after == [1: .inSync(offset: -1_440_000), 2: .inSync(offset: 27_360_000)])
        #expect(TakeSync.change(from: before, to: after) == [])
    }

    /// A take in both lists gives its change; a take only in the old list or only in the new list
    /// gives none.
    @Test func aTakeInOneListGivesNoChange() {
        let both = TakeSync.change(
            from: [1: .inSync(offset: 0), 2: .inSync(offset: 5)], to: [2: .inSync(offset: 6)])
        let onlyNew = TakeSync.change(
            from: [2: .broken(from: 10, shifts: 2)], to: [1: .inSync(offset: 0), 2: .broken(from: 10, shifts: 2)])

        #expect(both == [TakeSync.Change(take: 2, old: .inSync(offset: 5), new: .inSync(offset: 6))])
        #expect(onlyNew == [])
    }
}
