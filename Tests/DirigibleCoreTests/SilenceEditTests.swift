import Foundation
import Testing

@testable import DirigibleCore

/// The silence plan and the silence edit (decision 0066, criteria C9 to C16). The worked fixture
/// of the run analysis: 48 kHz, the mono tracks "host" and "guest", each with one clip from frame
/// 0 (offset 0, 480 000 frames), so a timeline frame equals its file frame before the edit.
/// Silence A is 96 000 ..< 240 000, the speech after it 240 000 ..< 264 000, and silence B
/// 264 000 ..< 312 000. Keep 24 000 frames (500 ms).
struct SilenceEditTests {
    static let silenceA: Range<Frames> = 96_000..<240_000
    static let silenceB: Range<Frames> = 264_000..<312_000
    static let keep = Frames(24_000)

    var session: Session

    init() throws {
        var session = Session(sampleRate: 48_000)
        for (track, file) in [("host", "h"), ("guest", "g")] {
            try session.addTrack(TrackID(track), name: track, layout: .mono)
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 480_000))
            try session.place(
                Clip(id: ClipID(file.uppercased()), file: FileID(file), start: 0, offset: 0, length: 480_000),
                on: TrackID(track))
        }
        self.session = session
    }

    /// The plan of `edits` (range, action) with `keep`.
    static func plan(_ edits: [(Range<Frames>, SilenceEdit.Action)], keep: Frames? = keep) throws -> SilencePlan {
        try SilencePlan(edits.map { SilenceEdit(range: $0.0, action: $0.1) }, keep: keep)
    }

    /// The start, offset, and length of each clip of `track`.
    func clips(_ track: TrackID) -> [[Int]] {
        session.track(track)?.clips.map { [$0.start.count, $0.offset.count, $0.length.count] } ?? []
    }

    func position(_ id: MarkerID) -> Int? { session.markers[id]?.position.count }

    mutating func marker(_ id: MarkerID, at frame: Frames, kind: Marker.Kind = .marker) throws {
        try session.setMarker(Marker(id: id, name: id.rawValue, position: frame, kind: kind))
    }

    /// C9. The cut keeps 12 000 frames at each edge of A. Fail values: a cut at the start of the
    /// silence gives a second clip at offset 216 000; a cut at its end gives the first clip a
    /// length of 120 000.
    @Test mutating func aShortenCutsTheMiddleOfTheSilence() throws {
        let original = session
        let result = try session.editSilences(try Self.plan([(Self.silenceA, .shorten)]), muting: ["host"])
        #expect(result.cuts == [108_000..<228_000])
        #expect(result.removed == 120_000)
        for track in ["host", "guest"] as [TrackID] {
            #expect(
                clips(track) == [[0, 0, 108_000], [108_000, 228_000, 252_000]],
                "the speech at 240 000 starts at 120 000 on \(track)")
        }
        #expect(session.end == 360_000, "the session end moves left by 120 000")
        session = original
        let whole = try session.editSilences(try Self.plan([(Self.silenceA, .shorten)], keep: 0), muting: [])
        #expect(whole.cuts == [96_000..<240_000], "keep 0 cuts the whole silence")
        #expect(clips("host") == [[0, 0, 96_000], [96_000, 240_000, 240_000]])
    }

    /// C10. A mute of B on "host" with a ramp of 480 frames (10 ms at 48 kHz): the envelope is -96 dB
    /// on 264 480 ..< 311 520 and keeps its old gain at 264 000 and 311 999 and outside B. The old
    /// gain is -6 dB, so -102 dB clamps at -96 dB. Fail value: the whole silence as the range puts
    /// the ramp on 263 521 ..< 264 000, so frame 263 999 changes.
    @Test mutating func aMuteEndsItsRampsInsideTheSilence() throws {
        try session.setEnvelope([0: Gain(dB: -6)!], clip: "H")
        let result = try session.editSilences(try Self.plan([(Self.silenceB, .mute)]), muting: ["host"])
        #expect(result.cuts.isEmpty && result.removed == 0 && result.skipped.isEmpty)
        let host = try #require(session.clip("H")?.clip.envelope)
        for frame in [263_999, 264_000, 311_999, 312_000, 100_000] as [Frames] {
            #expect(host.gain(at: frame) == -6, "frame \(frame) keeps its gain")
        }
        for frame in [264_480, 288_000, 311_519] as [Frames] {
            #expect(host.gain(at: frame) == -96, "frame \(frame) is muted at the floor")
        }
        #expect(session.clip("G")?.clip.envelope == .empty, "a track that is not muted keeps its gain")
        #expect(clips("host") == [[0, 0, 480_000]], "a mute cuts nothing")
    }

    /// C11. A mark of B adds one marker at the middle of B, 288 000, and at 168 000 when A is
    /// shortened in the same edit. Fail value: a mark after the ripple stays at 288 000.
    @Test mutating func aMarkLandsWhereTheCutsBeforeItMoveIt() throws {
        try marker("m", at: 100_000)
        let original = session
        let alone = try session.editSilences(try Self.plan([(Self.silenceB, .mark(name: "Silence 1"))]), muting: [])
        let id = try #require(alone.markers.first)
        #expect(alone.markers.count == 1)
        #expect(session.markers[id] == Marker(id: id, name: "Silence 1", position: 288_000, kind: .marker))
        #expect(session.markers.count == 2 && position("m") == 100_000, "no other marker changes")
        session = original
        let both = try session.editSilences(
            try Self.plan([(Self.silenceA, .shorten), (Self.silenceB, .mark(name: "Silence 1"))]), muting: [])
        let moved = try #require(both.markers.first)
        #expect(position(moved) == 168_000, "the mark moves left by the cut of A")
        #expect(session.markers[moved]?.name == "Silence 1" && session.markers[moved]?.kind == .marker)
    }

    /// C12. Rule M moves the markers and the chapters of the fixture.
    @Test mutating func markersAndChaptersFollowTheCuts() throws {
        try marker("kept", at: 100_000)
        try marker("inCut", at: 150_000)
        try marker("chapter", at: 240_000, kind: .chapter)
        try marker("late", at: 400_000)
        let original = session
        try session.editSilences(try Self.plan([(Self.silenceA, .shorten)]), muting: [])
        #expect(
            ["kept", "inCut", "chapter", "late"].map { position(MarkerID($0)) } == [100_000, 108_000, 120_000, 280_000])
        #expect(session.markers["chapter"]?.kind == .chapter, "the chapter keeps its kind")
        session = original
        try session.editSilences(try Self.plan([(Self.silenceA, .shorten), (Self.silenceB, .shorten)]), muting: [])
        #expect(position("late") == 256_000, "a marker after both cuts moves left by 144 000")
    }

    /// C13. The words follow the clips: a word in the kept start of A stays, a word after A shows
    /// 120 000 frames earlier, and a word whose midpoint is in the cut of A no longer shows. Fail
    /// value: a cut at the start of A hides the word at 99 000.
    @Test mutating func wordsFollowTheClipsAfterAShorten() throws {
        session.addWords(
            [
                (1, 50_000..<60_000, "before"), (2, 99_000..<101_000, "kept"), (3, 150_000..<160_000, "cut"),
                (4, 245_000..<255_000, "after"),
            ],
            file: "h")
        try session.editSilences(try Self.plan([(Self.silenceA, .shorten)]), muting: [])
        let shown = session.words(on: ["host"]).map { "\($0.text) \($0.range.lowerBound) \($0.range.upperBound)" }
        #expect(shown == ["before 50000 60000", "kept 99000 101000", "after 125000 135000"])
    }

    /// C14. A duck on "guest" across A: each part keeps the envelope points, so each kept timeline
    /// frame has the gain of its file frame, and at the join the gain steps from the value at file
    /// frame 108 000 (-6 dB) to the value at 228 000 (-7.52 dB).
    @Test mutating func aShortenKeepsTheEnvelopeOfEachKeptFrame() throws {
        try session.setEnvelope([90_000: .zero, 150_000: Gain(dB: -20)!, 250_000: Gain(dB: -4)!], clip: "G")
        let duck = try #require(session.clip("G")?.clip.envelope)
        try session.editSilences(try Self.plan([(Self.silenceA, .shorten)]), muting: [])
        let parts = try #require(session.track("guest")).clips
        #expect(parts.count == 2 && parts.allSatisfy { $0.envelope == duck }, "no cut changes a point")
        func gain(at frame: Frames) -> Double? {
            parts.first { $0.range.contains(frame) }.map { $0.envelope.gain(at: frame - $0.start + $0.offset) }
        }
        let join = (gain(at: 107_999) ?? 0, gain(at: 108_000) ?? 0)
        #expect(abs(join.0 - -6) < 0.001 && abs(join.1 - -7.52) < 0.001, "the gain at the join: \(join)")
        let kept = stride(from: 0, to: 360_000, by: 1_000).allSatisfy { frame in
            let file = frame < 108_000 ? frame : frame + 120_000
            return gain(at: Frames(frame)) == duck.gain(at: Frames(file))
        }
        #expect(kept, "each kept frame has the gain of its file frame")
    }

    /// C15. A Shorten of A, a Mute of B, and a Mark of 400 000 ..< 448 000 change the session in one
    /// call. A mute track that does not exist throws and changes nothing.
    @Test mutating func threeActionsAreOneEditAndAThrowChangesNothing() throws {
        let plan = try Self.plan([
            (Self.silenceA, .shorten), (Self.silenceB, .mute), (400_000..<448_000, .mark(name: "S")),
        ])
        let original = session
        #expect(throws: SessionError.unknownTrack("nope")) { try session.editSilences(plan, muting: ["host", "nope"]) }
        let same = session == original
        #expect(same, "a throw changes nothing")
        let result = try session.editSilences(plan, muting: ["host"])
        #expect(clips("guest") == [[0, 0, 108_000], [108_000, 228_000, 252_000]], "the shorten cuts every track")
        let after = session.track("host")?.clips.first { $0.range.contains(168_000) }
        #expect(after?.envelope.gain(at: 288_000) == -96, "the mute of B keeps its file frames")
        #expect(result.markers.map { position($0) } == [304_000], "the mark moves left by the cut of A")
    }

    /// C16c to C16e. The plan refuses a bound outside 0...2^40 and two ranges that overlap, with the
    /// pair number, and a keep outside 0...2^40. Ranges that touch are accepted. A nil keep is
    /// 500 ms at the rate of the edited session.
    @Test mutating func thePlanRefusesBadRanges() throws {
        #expect(throws: SilencePlan.Refusal.overlap(2)) { try Self.plan([(0..<100, .shorten), (50..<150, .mute)]) }
        #expect(throws: SilencePlan.Refusal.overlap(3)) {
            try Self.plan([(200..<300, .shorten), (0..<100, .shorten), (250..<260, .mark(name: "x"))])
        }
        #expect(try Self.plan([(0..<100, .shorten), (100..<200, .mute)]).edits.count == 2, "touching ranges")
        let over = Frames.limit + 1
        #expect(throws: SilencePlan.Refusal.outOfRange(2)) {
            try Self.plan([(0..<100, .shorten), (200..<over, .mute)])
        }
        #expect(throws: SilencePlan.Refusal.outOfRange(1)) { try Self.plan([(-1..<100, .shorten)]) }
        #expect(try Self.plan([(0..<Frames.limit, .shorten)]).edits.count == 1, "2^40 is a frame")
        for keep in [Frames(0), .limit] { #expect(try Self.plan([], keep: keep).keep == keep) }
        for keep in [Frames(-1), over] {
            #expect(throws: SilencePlan.Refusal.keepOutOfRange) { try Self.plan([(0..<100, .shorten)], keep: keep) }
        }
        let result = try session.editSilences(try Self.plan([(Self.silenceA, .shorten)], keep: nil), muting: [])
        #expect(result.cuts == [108_000..<228_000], "a nil keep is 24 000 frames at 48 kHz")
    }

    /// C16a and C16b. A shorten of `keep + 1` frames cuts 1 frame and one of `keep` frames is skipped;
    /// a mute of 961 frames mutes and one of 960 frames (2 ramps) is skipped. The other pairs apply.
    /// Fail value: a plan that refuses a pair with nothing to change.
    @Test mutating func aPairWithNothingToChangeIsSkipped() throws {
        let original = session
        let shorten = try session.editSilences(
            try Self.plan([
                (96_000..<120_001, .shorten), (264_000..<288_000, .shorten), (400_000..<448_000, .mark(name: "S")),
            ]),
            muting: [])
        #expect(shorten.cuts == [108_000..<108_001] && shorten.removed == 1)
        #expect(shorten.skipped == [2] && shorten.markers.count == 1)
        #expect(clips("host") == [[0, 0, 108_000], [108_000, 108_001, 371_999]], "the skipped pair cuts nothing")
        session = original
        let mute = try session.editSilences(
            try Self.plan([(96_000..<96_961, .mute), (264_000..<264_960, .mute)]), muting: ["host"])
        #expect(mute.skipped == [2] && mute.cuts.isEmpty)
        let host = try #require(session.clip("H")?.clip.envelope)
        #expect(host.gain(at: 96_480) == -96, "a mute of 961 frames mutes its middle frame")
        #expect(host.points.allSatisfy { $0.frame < 200_000 }, "the skipped mute adds no point")
    }
}
