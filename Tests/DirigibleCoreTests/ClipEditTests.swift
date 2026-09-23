import DirigibleCore
import Testing

/// Clip edits with literal frames. A file "f1" of 100 000 frames, a mono track "t1".
struct ClipEditTests {
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 100_000))
        try session.addFile(AudioFile(id: "s1", path: "s.wav", layout: .stereo, length: 100_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
    }

    func clip(_ id: ClipID, start: Frames, offset: Frames = 0, length: Frames) -> Clip {
        Clip(id: id, file: "f1", start: start, offset: offset, length: length)
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    @Test mutating func placeOnAnEmptyTrack() throws {
        try session.place(clip("c1", start: 1_000, length: 50_000), on: "t1")
        #expect(lane("t1") == [clip("c1", start: 1_000, length: 50_000)])
        #expect(session.clip("c1")?.track == "t1")
    }

    @Test mutating func placeKeepsTheClipsSortedByStart() throws {
        try session.place(clip("c2", start: 60_000, length: 10_000), on: "t1")
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        #expect(lane("t1").map(\.id) == ["c1", "c2"])
    }

    @Test mutating func placeOverTheMiddleOfAClipSplitsIt() throws {
        try session.place(clip("c1", start: 0, length: 90_000), on: "t1")
        try session.place(clip("c2", start: 30_000, offset: 0, length: 20_000), on: "t1")
        #expect(
            lane("t1") == [
                clip("c1", start: 0, length: 30_000),
                clip("c2", start: 30_000, length: 20_000),
                clip("c1@50000", start: 50_000, offset: 50_000, length: 40_000),
            ])
    }

    @Test mutating func placeOverTheEdgesTrimsTheClipsUnder() throws {
        try session.place(clip("a", start: 0, length: 40_000), on: "t1")
        try session.place(clip("b", start: 50_000, length: 40_000), on: "t1")
        try session.place(clip("c", start: 30_000, offset: 0, length: 30_000), on: "t1")
        #expect(
            lane("t1") == [
                clip("a", start: 0, length: 30_000),
                clip("c", start: 30_000, length: 30_000),
                clip("b", start: 60_000, offset: 10_000, length: 30_000),
            ])
    }

    @Test mutating func placeOverAWholeClipRemovesIt() throws {
        try session.place(clip("a", start: 10_000, length: 10_000), on: "t1")
        try session.place(clip("b", start: 0, length: 50_000), on: "t1")
        #expect(lane("t1") == [clip("b", start: 0, length: 50_000)])
    }

    @Test mutating func placeOfAnEqualClipChangesNothing() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        let before = session
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        #expect(session == before)
        #expect(throws: SessionError.duplicateID("c1")) {
            try session.place(clip("c1", start: 20_000, length: 10_000), on: "t2")
        }
    }

    @Test mutating func placeRefusesAClipThatDoesNotFit() throws {
        let before = session
        #expect(throws: SessionError.clipOutsideFile("c1")) {
            try session.place(clip("c1", start: 0, offset: 60_000, length: 50_000), on: "t1")
        }
        #expect(throws: SessionError.clipOutsideFile("c1")) {
            try session.place(clip("c1", start: 0, length: 0), on: "t1")
        }
        #expect(throws: SessionError.clipOutsideFile("c1")) {
            try session.place(clip("c1", start: 0, offset: Frames(.max - 10), length: Frames(.max - 10)), on: "t1")
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.place(clip("c1", start: -1, length: 10), on: "t1")
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.place(clip("c1", start: Frames(.max - 5), length: 10), on: "t1")
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.place(clip("c1", start: 0, offset: -1, length: 10), on: "t1")
        }
        #expect(throws: SessionError.unknownFile("f9")) {
            try session.place(Clip(id: "c1", file: "f9", start: 0, offset: 0, length: 10), on: "t1")
        }
        #expect(throws: SessionError.layoutMismatch("t1", .file("s1"))) {
            try session.place(Clip(id: "c1", file: "s1", start: 0, offset: 0, length: 10), on: "t1")
        }
        #expect(session == before)
    }

    @Test mutating func clearLeavesAGap() throws {
        try session.place(clip("c1", start: 0, length: 90_000), on: "t1")
        try session.clear(30_000..<50_000, on: "t1")
        #expect(
            lane("t1") == [
                clip("c1", start: 0, length: 30_000),
                clip("c1@50000", start: 50_000, offset: 50_000, length: 40_000),
            ])
    }

    @Test mutating func splitReturnsTheRightHalf() throws {
        try session.place(clip("c1", start: 10_000, offset: 5_000, length: 50_000), on: "t1")
        let right = try session.split("c1", at: 30_000)
        #expect(right == "c1@30000")
        #expect(
            lane("t1") == [
                clip("c1", start: 10_000, offset: 5_000, length: 20_000),
                clip("c1@30000", start: 30_000, offset: 25_000, length: 30_000),
            ])
        #expect(throws: SessionError.frameOutsideClip("c1", 10_000)) { try session.split("c1", at: 10_000) }
        #expect(throws: SessionError.frameOutsideClip("c1", 30_000)) { try session.split("c1", at: 30_000) }
        #expect(throws: SessionError.unknownClip("c9")) { try session.split("c9", at: 1) }
    }

    @Test mutating func splitTakesTheFirstFreeDerivedID() throws {
        try session.place(clip("c1", start: 0, length: 60_000), on: "t1")
        try session.split("c1", at: 30_000)
        try session.move("c1@30000", to: "t2", start: 0)
        try session.trim("c1", to: 0..<60_000)
        #expect(try session.split("c1", at: 30_000) == "c1@30000-2")
        #expect(throws: SessionError.duplicateID("c1@30000")) {
            try session.split("c1", at: 10_000, rightID: "c1@30000")
        }
    }

    @Test mutating func placeTakesTheFirstFreeDerivedID() throws {
        try session.place(clip("c1", start: 0, length: 60_000), on: "t1")
        try session.place(clip("p1", start: 20_000, length: 10_000), on: "t1")
        try session.move("c1@30000", to: "t2", start: 0)
        try session.clear(20_000..<30_000, on: "t1")
        try session.trim("c1", to: 0..<60_000)
        try session.place(clip("p2", start: 20_000, length: 10_000), on: "t1")
        #expect(lane("t1").map(\.id) == ["c1", "p2", "c1@30000-2"])
    }

    @Test mutating func aSplitNeverTakesTheIDOfThePlacedClip() throws {
        try session.place(clip("a", start: 0, length: 3_000), on: "t1")
        try session.place(clip("a@100", start: 100, length: 50), on: "t1")
        #expect(lane("t1").map(\.id) == ["a", "a@100", "a@150"])

        try session.place(clip("b", start: 10_000, length: 3_000), on: "t2")
        try session.split("b", at: 11_000)
        try session.move("b@11000", to: "t1", start: 20_000)
        try session.trim("b", to: 10_000..<13_000)
        try session.trim("b@11000", to: 20_000..<20_500)
        try session.move("b@11000", to: "t2", start: 10_500)
        #expect(lane("t2").map(\.id) == ["b", "b@11000", "b@11000-2"])
    }

    @Test mutating func moveBeyondTheFrameLimitChangesNothing() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        let before = session
        #expect(throws: SessionError.frameOutOfRange) { try session.move("c1", to: "t2", start: Frames.limit + 1) }
        #expect(session == before)
    }

    @Test mutating func moveToAnotherTrackOverwritesThere() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        try session.place(clip("c2", start: 0, length: 30_000), on: "t2")
        try session.move("c1", to: "t2", start: 10_000)
        #expect(lane("t1").isEmpty)
        #expect(
            lane("t2") == [
                clip("c2", start: 0, length: 10_000),
                clip("c1", start: 10_000, length: 10_000),
                clip("c2@20000", start: 20_000, offset: 20_000, length: 10_000),
            ])
    }

    @Test mutating func moveOnTheSameTrackCanOverlapItsOldPlace() throws {
        try session.place(clip("c1", start: 0, length: 10_000), on: "t1")
        try session.move("c1", to: "t1", start: 5_000)
        #expect(lane("t1") == [clip("c1", start: 5_000, length: 10_000)])
    }

    @Test mutating func trimMovesTheEdgesInsideTheFile() throws {
        try session.place(clip("c1", start: 10_000, offset: 5_000, length: 20_000), on: "t1")
        try session.trim("c1", to: 5_000..<40_000)
        #expect(lane("t1") == [clip("c1", start: 5_000, offset: 0, length: 35_000)])
        #expect(throws: SessionError.clipOutsideFile("c1")) { try session.trim("c1", to: 4_999..<40_000) }
        #expect(throws: SessionError.clipOutsideFile("c1")) { try session.trim("c1", to: 5_000..<105_001) }
        #expect(throws: SessionError.clipOutsideFile("c1")) { try session.trim("c1", to: 5_000..<5_000) }
    }

    @Test mutating func trimRefusesToGrowIntoANeighbor() throws {
        try session.place(clip("a", start: 0, length: 10_000), on: "t1")
        try session.place(clip("b", start: 20_000, offset: 20_000, length: 10_000), on: "t1")
        let before = session
        #expect(throws: SessionError.overlap("b", "a")) { try session.trim("b", to: 5_000..<30_000) }
        #expect(session == before)
    }

    @Test mutating func aTrackWithClipsKeepsItsLayout() throws {
        try session.place(clip("c1", start: 0, length: 10), on: "t1")
        #expect(throws: SessionError.layoutMismatch("t1", .trackHasClips)) {
            try session.setLayout(.stereo, route: nil, track: "t1")
        }
    }

    @Test mutating func aFileWithClipsStaysInThePool() throws {
        try session.place(clip("c1", start: 0, length: 10), on: "t1")
        #expect(throws: SessionError.fileInUse("f1")) { try session.removeFile("f1") }
    }

    @Test mutating func clipGainChanges() throws {
        try session.place(clip("c1", start: 0, length: 10), on: "t1")
        try session.setGain(Gain(dB: 4)!, clip: "c1")
        #expect(lane("t1").first?.gain == Gain(dB: 4))
        #expect(throws: SessionError.unknownClip("c9")) { try session.setGain(.zero, clip: "c9") }
    }
}
