import Foundation
import Testing

@testable import DirigibleCore

/// Roll and slip (decisions 0036 and 0037, run timeline-edits). 48 kHz, mono tracks "t1" and "t2",
/// files "fa" and "fb" of 480 000 frames. On "t1", A is 0 ..< 144 000 at offset 96 000 and B is
/// 144 000 ..< 240 000 at offset 192 000, so the join is 144 000. The crossfade of the join is 960.
struct RollSlipTests {
    static let fileLength: Frames = 480_000

    /// The roll fixture: A and B with a crossfade of `crossfade` frames at the join (0 for none).
    /// `a` and `b` change the clips before they are placed.
    static func fixture(
        crossfade: Frames = 960, a: (inout Clip) -> Void = { _ in }, b: (inout Clip) -> Void = { _ in }
    ) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for id in ["fa", "fb"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: fileLength))
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        var clipA = Clip(id: "A", file: "fa", start: 0, offset: 96_000, length: 144_000)
        var clipB = Clip(id: "B", file: "fb", start: 144_000, offset: 192_000, length: 96_000)
        a(&clipA)
        b(&clipB)
        try session.place(clipA, on: "t1")
        try session.place(clipB, on: "t1")
        if crossfade != .zero { try session.setCrossfades(["A": crossfade]) }
        return session
    }

    static func clip(_ id: ClipID, in session: Session) -> Clip { session.clip(id)!.clip }

    // MARK: Roll

    /// C6: the first test. The roll fixture gives the limits of the worked example.
    @Test func rollLimits() throws {
        let session = try Self.fixture()
        #expect(session.rollLimits("A") == -143_520...95_520, "half a crossfade is left in each clip")
        let plain = try Self.fixture(crossfade: .zero)
        #expect(plain.rollLimits("A") == -143_999...95_999, "one frame is left in each clip")
        #expect(session.rollLimits("B") == nil, "B has no clip after it")
        #expect(session.rollLimits("nobody") == nil)
    }

    @Test func aRollMovesTheJoinAndNothingElse() throws {
        var session = try Self.fixture()
        try session.place(Clip(id: "C", file: "fa", start: 240_000, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "G", file: "fa", start: 144_000, offset: 0, length: 48_000), on: "t2")
        try session.setMarker(Marker(id: "m", name: "m", position: 150_000, kind: .marker))
        let before = session
        try session.roll("A", by: 24_000)
        #expect(
            Self.clip("A", in: session)
                == Clip(
                    id: "A", file: "fa", start: 0, offset: 96_000, length: 168_000,
                    crossfades: Crossfades(start: 0, end: 960)!))
        #expect(
            Self.clip("B", in: session)
                == Clip(
                    id: "B", file: "fb", start: 168_000, offset: 216_000, length: 72_000,
                    crossfades: Crossfades(start: 960, end: 0)!))
        #expect(Self.clip("C", in: session) == Self.clip("C", in: before), "a later clip stays")
        #expect(session.track("t2")?.clips.map { $0 } == before.track("t2")?.clips.map { $0 }, "no other track moves")
        #expect(session.markers == before.markers, "a marker stays")
        #expect(throws: Never.self, "the lane still holds its pairing") {
            try ClipLane(validating: session.track("t1")!.clips.map { $0 })
        }
    }

    /// Control: two `trim` calls break the join at the first call, and the repair drops the crossfade.
    @Test func aRollKeepsTheCrossfadeOfItsJoin() throws {
        var session = try Self.fixture(
            a: { $0.fades = Fades(fadeIn: 1_000, fadeOut: 0)! }, b: { $0.fades = Fades(fadeIn: 0, fadeOut: 2_000)! })
        var viaTrims = session
        try viaTrims.trim("B", to: 168_000..<240_000)
        try viaTrims.trim("A", to: 0..<168_000)
        #expect(Self.clip("A", in: viaTrims).crossfades == .zero, "control: two trims drop the crossfade")

        try session.roll("A", by: 24_000)
        #expect(Self.clip("B", in: session).start == 168_000, "the join moved")
        #expect(Self.clip("A", in: session).crossfades == Crossfades(start: 0, end: 960))
        #expect(Self.clip("B", in: session).crossfades == Crossfades(start: 960, end: 0))
        #expect(Self.clip("A", in: session).fades == Fades(fadeIn: 1_000, fadeOut: 0), "the far fade stays")
        #expect(Self.clip("B", in: session).fades == Fades(fadeIn: 0, fadeOut: 2_000), "the far fade stays")
    }

    @Test func theFadesAtAJoinYieldToTheRoom() throws {
        var session = try Self.fixture(
            crossfade: .zero, a: { $0.fades = Fades(fadeIn: 1_000, fadeOut: 143_000)! },
            b: { $0.fades = Fades(fadeIn: 90_000, fadeOut: 6_000)! })
        try session.roll("A", by: -10_000)
        #expect(Self.clip("A", in: session).fades == Fades(fadeIn: 1_000, fadeOut: 133_000), "the join fade yields")
        #expect(Self.clip("B", in: session).fades == Fades(fadeIn: 90_000, fadeOut: 6_000), "B grew, so it keeps both")
        try session.roll("A", by: 20_000)
        #expect(
            Self.clip("B", in: session).fades == Fades(fadeIn: 80_000, fadeOut: 6_000), "B shrank: its join fade yields"
        )
    }

    @Test func aRollChangesNoEnvelopePoint() throws {
        var session = try Self.fixture()
        try session.setEnvelope([150_000: Gain(dB: -6)!], clip: "B")
        let points = Self.clip("B", in: session).envelope
        #expect(points.points.count == 1, "control: the point is there")
        try session.roll("A", by: 24_000)
        #expect(Self.clip("B", in: session).start == 168_000, "the join moved")
        #expect(Self.clip("B", in: session).envelope == points, "the point is a file frame, so it stays")
    }

    @Test func aRollNeedsAJoin() throws {
        var session = try Self.fixture()
        let before = session
        #expect(throws: SessionError.noJoin("B")) { try session.roll("B", by: 10) }
        #expect(throws: SessionError.unknownClip("nobody")) { try session.roll("nobody", by: 10) }
        #expect(session == before)

        try session.roll("A", by: 0)
        #expect(session == before, "a roll by 0 changes nothing")

        try session.clear(144_000..<145_000, on: ["t1"])
        let gapped = session
        #expect(throws: SessionError.noJoin("A"), "a gap is no join") { try session.roll("A", by: 0) }
        #expect(session.rollLimits("A") == nil)
        #expect(session == gapped)
    }

    /// C6: every fixture. A delta passes `roll` exactly when `rollLimits` holds it, and a delta past an end
    /// throws the reason of that end and changes nothing.
    @Test func rollLimitsMatchTheRefusals() throws {
        struct Case {
            var name: String
            var session: Session
            var limits: ClosedRange<Frames>
            var low: SessionError
            var high: SessionError
        }
        let cases: [Case] = [
            Case(
                name: "crossfade", session: try Self.fixture(), limits: -143_520...95_520,
                low: .fadeOutsideClip("A", length: 479), high: .fadeOutsideClip("B", length: 479)),
            Case(
                name: "no crossfade", session: try Self.fixture(crossfade: .zero), limits: -143_999...95_999,
                low: .clipOutsideFile("A"), high: .clipOutsideFile("B")),
            Case(
                name: "A at the media end", session: try Self.fixture(a: { $0.offset = 288_000 }),
                limits: -143_520...47_520, low: .fadeOutsideClip("A", length: 479),
                high: .crossfadeOutsideFile("A", needed: 480)),
            Case(
                name: "A at the media end, no crossfade",
                session: try Self.fixture(crossfade: .zero, a: { $0.offset = 288_000 }), limits: -143_999...48_000,
                low: .clipOutsideFile("A"), high: .clipOutsideFile("A")),
            Case(
                name: "B at its handle", session: try Self.fixture(b: { $0.offset = 480 }), limits: 0...95_520,
                low: .crossfadeOutsideFile("B", needed: 480), high: .fadeOutsideClip("B", length: 479)),
            Case(
                name: "B at the file start, no crossfade",
                session: try Self.fixture(crossfade: .zero, b: { $0.offset = 7 }), limits: -7...95_999,
                low: .frameOutOfRange, high: .clipOutsideFile("B")),
        ]
        for fixture in cases {
            let limits = try #require(fixture.session.rollLimits("A"), "\(fixture.name)")
            #expect(limits == fixture.limits, "\(fixture.name): the limits")
            for delta in [limits.lowerBound, limits.upperBound, .zero] {
                var session = fixture.session
                #expect(throws: Never.self, "\(fixture.name): \(delta) passes") { try session.roll("A", by: delta) }
            }
            for (delta, error) in [(limits.lowerBound - 1, fixture.low), (limits.upperBound + 1, fixture.high)] {
                var session = fixture.session
                #expect(throws: error, "\(fixture.name): \(delta) throws") { try session.roll("A", by: delta) }
                #expect(session == fixture.session, "\(fixture.name): a refusal changes nothing")
            }
        }
    }

    // MARK: Slip

    @Test func aSlipMovesTheAudioUnderTheClip() throws {
        var session = try Self.fixture(
            a: {
                $0.fades = Fades(fadeIn: 100, fadeOut: 0)!
                $0.gain = Gain(dB: 3)!
            },
            b: { $0.fades = Fades(fadeIn: 0, fadeOut: 200)! })
        try session.setEnvelope([150_000: Gain(dB: -6)!], clip: "B")
        try session.setMarker(Marker(id: "m", name: "m", position: 150_000, kind: .marker))
        let before = session
        try session.slip(["B"], by: 24_000)
        var expected = Self.clip("B", in: before)
        expected.offset = 216_000
        #expect(
            Self.clip("B", in: session) == expected, "only the offset changes: the crossfade, fades, and envelope stay")
        #expect(Self.clip("A", in: session) == Self.clip("A", in: before))
        #expect(session.markers == before.markers)

        try session.slip(["A", "B"], by: -480)
        #expect(Self.clip("A", in: session).offset == 95_520 && Self.clip("B", in: session).offset == 215_520)
        #expect(Self.clip("A", in: session).start == 0 && Self.clip("B", in: session).length == 96_000)

        let slipped = session
        try session.slip(["B", "B"], by: 0)
        #expect(session == slipped, "a slip by 0 changes nothing")
        #expect(throws: SessionError.unknownClip("nobody")) { try session.slip(["A", "nobody"], by: 480) }
        #expect(session == slipped, "an unknown ID changes nothing")
    }

    @Test func slipLimits() throws {
        var session = try Self.fixture()
        try session.place(Clip(id: "C", file: "fa", start: 0, offset: 0, length: 48_000), on: "t2")
        #expect(try session.slipLimits("B") == -191_520...192_000, "the crossfade half is the handle that must stay")
        #expect(try session.slipLimits("C") == 0...432_000)
        #expect(try session.slipLimits("A") == -96_000...239_520)
        #expect(throws: SessionError.unknownClip("nobody")) { try session.slipLimits("nobody") }
    }

    @Test func slipLimitsMatchTheRefusals() throws {
        var session = try Self.fixture()
        try session.place(Clip(id: "C", file: "fa", start: 0, offset: 0, length: 48_000), on: "t2")
        let cases: [(ClipID, SessionError, SessionError)] = [
            ("A", .frameOutOfRange, .crossfadeOutsideFile("A", needed: 480)),
            ("B", .crossfadeOutsideFile("B", needed: 480), .clipOutsideFile("B")),
            ("C", .frameOutOfRange, .clipOutsideFile("C")),
        ]
        for (id, low, high) in cases {
            let limits = try session.slipLimits(id)
            for delta in [limits.lowerBound, limits.upperBound] {
                var copy = session
                #expect(throws: Never.self, "\(id): \(delta) passes") { try copy.slip([id], by: delta) }
                #expect(Self.clip(id, in: copy).offset == Self.clip(id, in: session).offset + delta)
            }
            for (delta, error) in [(limits.lowerBound - 1, low), (limits.upperBound + 1, high)] {
                var copy = session
                #expect(throws: error, "\(id): \(delta) throws") { try copy.slip([id], by: delta) }
                #expect(copy == session, "\(id): a refusal changes nothing")
            }
        }
        var copy = session
        #expect(throws: SessionError.clipOutsideFile("B"), "one refused clip refuses the call") {
            try copy.slip(["A", "B"], by: 192_001)
        }
        #expect(copy == session, "A did not move")
    }
}
