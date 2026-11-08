import Foundation
import Testing

@testable import DirigibleCore

/// The ride layer in `session.xml` (leveler C20): one `<rides>` element with one text list for
/// each distinct ride list, at `rideSessionVersion`.
extension SessionFileTests {
    /// Clip "A" of file "f" (60 000 frames) on track "t", with the ride `ride` and the envelope
    /// `points`.
    static func rideSession(_ ride: GainEnvelope, points: GainEnvelope = .empty) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 60_000))
        try session.addTrack("t", name: "Host", layout: .mono)
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 60_000, envelope: points), on: "t")
        try session.setRides(["A": ride])
        return session
    }

    func xml(_ session: Session) throws -> String { String(decoding: try session.checkedData(), as: UTF8.self) }

    /// A session with a ride point writes `rideSessionVersion`, `<rides>` before `<tracks>`, and
    /// `ride="r1"`. With each ride point removed, it writes the version of its other features.
    @Test func rideWritesItsVersion() throws {
        var session = try Self.rideSession(envelope([(1_200, -1.37), (6_000, 2.5)]), points: envelope([(100, -6)]))
        let text = try xml(session)

        #expect(session.fileVersion == rideSessionVersion && text.contains(#"version="\#(rideSessionVersion)""#))
        let rides = try #require(text.range(of: #"<ride id="r1">1200 -1.37 6000 2.5</ride>"#))
        #expect(rides.lowerBound < text.range(of: "<tracks>")!.lowerBound && text.contains(#"ride="r1""#))

        try session.setRides(["A": .empty])
        let plain = try xml(session)
        #expect(session.fileVersion == 10 && plain.contains(#"version="10""#) && !plain.contains("ride"))
    }

    /// A file one version below `rideSessionVersion` with `<rides>` or a `ride` attribute is refused.
    @Test func rideInAnOlderVersionRefused() throws {
        let text = try xml(try Self.rideSession(envelope([(1_200, -1.37)])))
        let older = text.replacingOccurrences(
            of: #"version="\#(rideSessionVersion)""#, with: #"version="\#(rideSessionVersion - 1)""#)
        #expect(older != text)
        #expect(throws: SessionFileError.invalidValue(element: "rides", attribute: "version")) {
            try Session(xml: Data(older.utf8))
        }
        let noList = older.replacingOccurrences(of: #"<rides>[\s\S]*</rides>"#, with: "", options: .regularExpression)
        #expect(!noList.contains("<rides") && noList.contains(#"ride="r1""#))
        #expect(throws: SessionFileError.invalidValue(element: "clip", attribute: "ride")) {
            try Session(xml: Data(noList.utf8))
        }
    }

    /// One case for each clause of the C20 grammar: the reader refuses the list and never traps.
    @Test(arguments: [
        "", "0 1 2", "0  1", " 0 1", "0 1 ", "0\t1", "0\n1", "0 +1", "0 nan", "0 inf", "0 infinity", "0 0x1p3",
        "0 1.", "0 .5", "0 1E5", "0 1e5", "0 1e-", "0 1e999", "0 -1.0000000000000000000000000000001",
        "12345678901234567890 1", "\(Frames.limit.count + 1) 1", "-5 1", "10 1 5 2", "10 1 10 2", "0 1 x 2",
    ])
    func damagedRideListRefused(list: String) throws {
        let text = try xml(try Self.rideSession(envelope([(1_200, -1.37)])))
        let damaged = text.replacingOccurrences(of: ">1200 -1.37<", with: ">\(list)<")
        #expect(damaged != text)

        #expect(throws: SessionFileError.invalidValue(element: "ride", attribute: "text")) {
            try Session(xml: Data(damaged.utf8))
        }
    }

    /// Two lists with one ID, a `ride` that names no list, and a list that no clip names.
    @Test func damagedRideReferencesRefused() throws {
        let text = try xml(try Self.rideSession(envelope([(1_200, -1.37)])))
        let list = #"<ride id="r1">1200 -1.37</ride>"#
        let cases: [(String, SessionFileError)] = [
            (list + list, .invalidValue(element: "ride", attribute: "id")),
            (list + #"<ride id="r2">0 1</ride>"#, .invalidValue(element: "ride", attribute: "id")),
            (#"<ride id="r2">1200 -1.37</ride>"#, .invalidValue(element: "clip", attribute: "ride")),
        ]
        for (replacement, error) in cases {
            let damaged = text.replacingOccurrences(of: list, with: replacement)
            #expect(damaged != text)
            #expect(throws: error) { try Session(xml: Data(damaged.utf8)) }
        }
        let late = try Self.rideSession(envelope([(1_200, -1.37)]))
        let outside = text.replacingOccurrences(of: ">1200 -1.37<", with: ">1200 -1.37 60001 0<")
        #expect(throws: SessionFileError.invalidSession(.clipOutsideFile("A"))) {
            try Session(xml: Data(outside.utf8))
        }
        #expect(try Session(xml: Data(text.utf8)) == late)
    }

    /// Each point and each sharing of a list survives a write and a read, with the gains of the
    /// fast path, of `Double`, and the clamp of `Gain.range`.
    @Test func rideRoundTrips() throws {
        var session = try Self.rideSession(envelope([(0, 0), (1, -0.5), (2, 6.25), (3, -12.345678), (60_000, 1e-05)]))
        try session.place(Clip(id: "B", file: "f", start: 60_000, offset: 0, length: 60_000), on: "t")
        try session.setRides(["B": envelope([(5, -3)])])

        try session.write(to: package)
        let read = try Session(contentsOf: package)

        #expect(read == session)
        #expect(read.clip("A")?.clip.ride.points.map(\.gain.dB) == [0, -0.5, 6.25, -12.345678, 1e-05])
    }

    /// Gains off the 0.01 dB grid: a ride moved with `fitted` edge points, and a corner of a range
    /// Remove (a value on a ramp). Each saves through `checkedData` and reads back equal.
    @Test func offGridRideRoundTrips() throws {
        let moved = envelope([(100, -1.37), (900, 2.41), (2_000, -3.33)]).moved(by: -500, fileLength: 1_000)
        #expect(moved.points.contains { ($0.gain.dB * 100).rounded() != $0.gain.dB * 100 })
        let corner = envelope([(1_000, -1.37 + (2.41 + 1.37) * 0.3333), (24_000, 0)])
        for ride in [moved, corner] {
            let session = try Self.rideSession(ride)
            #expect(try Session(xml: try session.checkedData()) == session)
        }
    }

    /// C20, C34: a ridden 2 h clip in 200 parts writes one list, and after an open the parts
    /// share one array.
    @Test func splitRideIsStoredOnce() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 345_600_000))
        try session.addTrack("t", name: "Host", layout: .mono)
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 345_600_000), on: "t")
        try session.setRides(["A": SessionRideTests.ride(2_000)])
        try session.splitClips(at: (1..<200).map { Frames($0 * 1_728_000) }, on: ["t"])

        let text = try xml(session)
        let read = try Session(xml: Data(text.utf8))

        #expect(text.components(separatedBy: "<ride id=").count == 2)
        #expect(text.components(separatedBy: #"ride="r1""#).count == 201)
        let arrays = Set(
            read.tracks[0].clips.map { $0.ride.points.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } })
        #expect(read == session && arrays.count == 1)
    }

    /// C34: before the read-back compare, a read-back clip takes the ride array of its clip in the
    /// written session only when the two lists are equal. Clip "B" reads back the list of "A" in
    /// the array of "A", but its written list differs, so it keeps its list and `==` refuses it.
    @Test func readBackSharesOnlyEqualRideArrays() throws {
        func address(_ ride: GainEnvelope) -> UnsafeRawPointer? {
            ride.points.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        }
        var written = Session(sampleRate: 48_000)
        try written.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 60_000))
        try written.addTrack("t", name: "Host", layout: .mono)
        for (index, id) in ["A", "B", "C"].enumerated() {
            let start = Frames(index * 20_000)
            try written.place(Clip(id: ClipID(id), file: "f", start: start, offset: start, length: 20_000), on: "t")
        }
        let (ride, other) = (envelope([(100, -1.37), (30_000, 2.5)]), envelope([(100, -1.37), (30_000, 2.51)]))
        try written.setRides(["A": ride, "B": other, "C": ride])
        var read = written
        let copy = GainEnvelope(valid: ride.points.map { $0 })
        try read.setRides(["A": copy, "B": copy, "C": copy])

        read.shareRides(of: written)

        let rides = read.tracks[0].clips.map(\.ride)
        #expect(read != written && rides == [ride, ride, ride])
        #expect(rides.map(address) == [address(ride), address(copy), address(ride)])
        try read.setRides(["B": GainEnvelope(valid: other.points.map { $0 })])
        read.shareRides(of: written)
        #expect(read == written && read.tracks[0].clips.map { address($0.ride) } == [ride, other, ride].map(address))
    }
}
