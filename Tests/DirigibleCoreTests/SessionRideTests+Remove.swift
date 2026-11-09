import Foundation
import Testing

@testable import DirigibleCore

/// Remove Level Over Time on a range: a ridden 60 s clip, remove on 20..30 s with
/// the 500 ms ramp.
extension SessionRideTests {
    static let removeRange: Range<Frames> = 960_000..<1_440_000
    static let ramp: Frames = 24_000

    func ride(_ id: ClipID) throws -> GainEnvelope { try #require(session.clip(id)).clip.ride }

    /// The ride is 0 dB at each frame of the range, and the old ride before 19.5 s and after
    /// 30.5 s, within 1e-9 dB.
    @Test mutating func removeOnARangeLeavesTheRest() throws {
        let old = Self.ride(1_600)
        try place("A", on: "t", start: 0, length: 2_880_000)
        try session.setRides(["A": old])

        #expect(try session.removeRides(["A"], in: Self.removeRange, ramp: Self.ramp) == ["A"])

        let new = try ride("A")
        let inside = stride(from: 960_000, to: 1_440_000, by: 997).map { Frames($0) } + [1_439_999]
        #expect(inside.allSatisfy { new.gain(at: $0) == 0 }, "a ride point is left in the range")
        let outside =
            stride(from: 0, through: 936_000, by: 1_009).map { Frames($0) }
            + stride(from: 1_464_000, to: 2_880_000, by: 1_009).map { Frames($0) } + [936_000, 1_464_000]
        let worst = outside.map { abs(new.gain(at: $0) - old.gain(at: $0)) }.max()!
        #expect(worst <= 1e-9, "the ride outside the ramps moved by \(worst) dB")
    }

    /// A clip split at 25 s keeps one list: the two parts of the set share the new array, and a
    /// third part at 50 s, outside the set, plays no changed frame and gets it too.
    @Test mutating func removeOnARangeKeepsOneList() throws {
        try place("A", on: "t", start: 0, length: 2_880_000)
        try session.setRides(["A": Self.ride(1_600)])
        try session.splitClips(at: [1_200_000, 2_400_000], on: ["t"])

        #expect(
            try session.removeRides(["A", "A@1200000"], in: Self.removeRange, ramp: Self.ramp) == ["A", "A@1200000"])

        let (a, b, c) = (try ride("A"), try ride("A@1200000"), try ride("A@2400000"))
        #expect(a.gain(at: 1_000_000) == 0 && a == b && a == c, "the parts hold more than one list")
        #expect(Self.sameArray(a, c))
    }

    /// Part B moved 1 s later: two lists. A plays its old ride before 19.5 s, B after 30.5 s on the
    /// timeline, and each plays 0 dB on the frames of 20..30 s that it plays.
    @Test mutating func removeOnARangeWithAMovedPartKeepsTheRideOutsideTheRange() throws {
        let old = Self.ride(1_600)
        try place("A", on: "t", start: 0, length: 2_880_000)
        try session.setRides(["A": old])
        try session.splitClips(at: [1_200_000], on: ["t"])
        try session.move("A@1200000", to: "t", start: 1_248_000)

        _ = try session.removeRides(["A", "A@1200000"], in: Self.removeRange, ramp: Self.ramp)

        let (a, b) = (try ride("A"), try ride("A@1200000"))
        #expect(a != b, "one list for two file maps")
        let before = stride(from: 0, through: 936_000, by: 1_009).map { Frames($0) }
        #expect(before.allSatisfy { a.gain(at: $0) == old.gain(at: $0) }, "A moved outside the range")
        // B plays file frame t - 48 000 at timeline frame t.
        let after = stride(from: 1_464_001, to: 2_928_000, by: 1_009).map { Frames($0 - 48_000) }
        #expect(after.allSatisfy { abs(b.gain(at: $0) - old.gain(at: $0)) <= 1e-9 }, "B moved outside the range")
        #expect(stride(from: 960_000, to: 1_200_000, by: 997).allSatisfy { a.gain(at: Frames($0)) == 0 })
        #expect(stride(from: 1_200_000, to: 1_392_000, by: 997).allSatisfy { b.gain(at: Frames($0)) == 0 })
    }
}
