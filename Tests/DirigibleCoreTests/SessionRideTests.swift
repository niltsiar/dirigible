import Foundation
import Testing

@testable import DirigibleCore

/// The measure groups of Level Over Time and the ride layer under the edits. Tracks "t", "u", and "v" (stereo); files "f" and "g" of 2 h at 48 kHz.
struct SessionRideTests {
    static let twoHours = 345_600_000
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        for id in ["f", "g"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .stereo, length: Frames(Self.twoHours)))
        }
        for id in ["t", "u", "v"] as [TrackID] { try session.addTrack(id, name: id.rawValue, layout: .stereo) }
    }

    /// A ride list of `count` points every 1 728 frames from frame 864, with gains on the 0.01 dB grid.
    static func ride(_ count: Int, shift: Double = 0) -> GainEnvelope {
        envelope((0..<count).map { (864 + $0 * 1_728, Double(($0 * 37) % 600 - 300) / 100 + shift) })
    }

    mutating func place(
        _ id: ClipID, on track: TrackID, file: FileID = "f", start: Int, offset: Int? = nil, length: Int,
        gain: Double = 0, envelope: GainEnvelope = .empty
    ) throws {
        try session.place(
            Clip(
                id: id, file: file, start: Frames(start), offset: Frames(offset ?? start), length: Frames(length),
                gain: Gain(dB: gain)!, envelope: envelope),
            on: track)
    }

    func groups(_ ids: Set<ClipID>) throws -> [[ClipID]] { try session.rideGroups(ids).map(\.clips) }

    /// A split clip is one group: one window of file frames, and both parts are written.
    @Test mutating func splitClipIsOneGroup() throws {
        try place("A", on: "t", start: 0, length: 100_000)
        try session.splitClips(at: [40_000], on: ["t"])

        let groups = try session.rideGroups(["A", "A@40000"])

        #expect(groups.map(\.clips) == [["A", "A@40000"]])
        #expect(groups[0].frames == 0..<100_000 && groups[0].written == ["A", "A@40000"])
    }

    /// A duck across the cut gives each part other points: one group, and the envelope gain is of
    /// A in the frames of A and of B in the frames of B. A at 46 000 is -12 and B at 32 000 is -12,
    /// so a read of the wrong part fails.
    @Test mutating func duckAcrossTheCutKeepsOneGroup() throws {
        try place("A", on: "t", start: 0, length: 100_000)
        try session.splitClips(at: [40_000], on: ["t"])
        try session.setEnvelopes([
            "A": envelope([(30_000, 0), (35_000, -12)]), "A@40000": envelope([(45_000, -12), (50_000, 0)]),
        ])

        let groups = try session.rideGroups(["A", "A@40000"])

        #expect(groups.map(\.clips) == [["A", "A@40000"]])
        let group = groups[0]
        #expect(abs(group.envelopeGain(at: 32_000) - -4.8) < 1e-9)
        #expect(abs(group.envelopeGain(at: 46_000) - -9.6) < 1e-9)
        #expect(group.envelopeGain(at: 39_999) == -12 && group.envelopeGain(at: 40_000) == -12)
    }

    /// A manual point on one part keeps one group; the other part reads its own empty envelope.
    @Test mutating func pointOnOnePartKeepsOneGroup() throws {
        try place("A", on: "t", start: 0, length: 100_000)
        try session.splitClips(at: [40_000], on: ["t"])
        try session.setEnvelopes(["A": envelope([(10_000, -6)])])

        let groups = try session.rideGroups(["A"])

        #expect(groups.map(\.clips) == [["A", "A@40000"]])
        #expect(groups[0].envelopeGain(at: 20_000) == -6 && groups[0].envelopeGain(at: 60_000) == 0)
    }

    /// A duplicated clip (same window, gain, and envelope) on another track is one group.
    @Test mutating func duplicatedClipIsOneGroup() throws {
        let points = envelope([(10_000, -6)])
        try place("A", on: "t", start: 0, length: 100_000, envelope: points)
        try place("D", on: "u", start: 0, length: 100_000, envelope: points)

        #expect(try groups(["A"]) == [["A", "D"]])
    }

    /// Overlapping clips with other clip gains are two groups.
    @Test mutating func otherGainsAreTwoGroups() throws {
        try place("A", on: "t", start: 0, length: 100_000)
        try place("B", on: "u", start: 0, offset: 50_000, length: 100_000, gain: -3)

        #expect(try groups(["A", "B"]) == [["A"], ["B"]])
    }

    /// A clip gain of -0 dB equals 0 dB, so the parts are one group.
    @Test mutating func negativeZeroGainIsOneGroup() throws {
        try place("A", on: "t", start: 0, length: 40_000)
        try place("B", on: "t", start: 40_000, length: 60_000, gain: -0.0)

        #expect(try groups(["A", "B"]) == [["A", "B"]])
    }

    /// Parts with touching file windows that play apart on the timeline are two groups, so the
    /// ride of one part reads no audio of the other.
    @Test mutating func partsMovedApartAreTwoGroups() throws {
        try place("A", on: "t", start: 0, length: 40_000)
        try place("B", on: "t", start: 200_000, offset: 40_000, length: 60_000)
        try place("C", on: "u", start: 0, offset: 40_000, length: 60_000)

        #expect(Set(try groups(["A", "B", "C"])) == [["A"], ["B"], ["C"]])
    }

    /// B plays file frames of A at another timeline position (another shift from file frames to
    /// timeline frames), so B is its own group by the timeline group rule. C plays on from A, so it
    /// stays with A.
    @Test mutating func overlapWithOtherEnvelopesIsTwoGroups() throws {
        try place("A", on: "t", start: 0, length: 100_000)
        try place("C", on: "t", start: 100_000, length: 30_000)
        try place("B", on: "u", start: 0, offset: 50_000, length: 40_000, envelope: envelope([(60_000, -6)]))

        #expect(try groups(["A", "B", "C"]) == [["A", "C"], ["B"]])
        #expect(try groups(["C"]) == [["A", "C"]])
    }

    /// A 2 h clip in 200 parts and a duplicate phrase with a duck on another track: only the
    /// duplicate leaves, so the chain stays one group.
    @Test mutating func duplicateInAChainLeavesTheChainOneGroup() throws {
        try place("A", on: "t", start: 0, length: Self.twoHours)
        try session.splitClips(at: (1..<200).map { Frames($0 * 1_728_000) }, on: ["t"])
        try place(
            "D", on: "u", start: 3_000_000, length: 500_000,
            envelope: envelope([(3_100_000, 0), (3_110_000, -12)]))
        let parts = session.track("t")!.clips.map(\.id)

        let groups = try session.rideGroups(Set(parts + ["D"]))

        #expect(groups.map(\.clips) == [parts, ["D"]])
        #expect(parts.count == 200 && groups[0].frames == 0..<Frames(Self.twoHours))
    }

    /// A ride of part A measures the touching group of A and B and writes only A.
    @Test mutating func rideOfOnePartMeasuresTheTouchingGroup() throws {
        try place("A", on: "t", start: 0, length: 100_000)
        try session.splitClips(at: [40_000], on: ["t"])

        let groups = try session.rideGroups(["A"])

        #expect(groups.map(\.clips) == [["A", "A@40000"]] && groups.map(\.written) == [["A"]])
        let current = session
        #expect(throws: SessionError.unknownClip("X")) { try current.rideGroups(["A", "X"]) }
    }

    /// A ride gain past `Gain.rideLimit` is refused as the load refuses it, so a save never fails its
    /// read-back; the limit itself passes. A throw changes nothing.
    @Test(arguments: [6.01, -6.01, 96.0])
    mutating func setRidesRefusesAGainPastTheLimit(dB: Double) throws {
        try place("A", on: "t", start: 0, length: 1_000_000)
        try place("B", on: "t", start: 1_000_000, length: 1_000_000)
        try session.setRides(["A": envelope([(10, 6), (20, -6)])])
        let before = session

        #expect(throws: SessionError.invalidRideGain("B")) {
            try session.setRides(["A": .empty, "B": envelope([(10, 1), (1_000_020, dB)])])
        }
        #expect(session == before)
    }

    /// A duck writes the envelope only; the ride stays equal.
    @Test mutating func duckKeepsTheRide() throws {
        try place("A", on: "t", start: 0, length: 1_000_000)
        try session.setRides(["A": Self.ride(500)])
        let shape = DuckShape(depth: Gain(dB: -12)!, attack: 4_800, release: 9_600, threshold: Gain(dB: -40)!, hold: 0)

        try session.duck(runs: [200_000..<400_000], shape: shape, music: ["t"], scope: nil)

        let clip = try #require(session.clip("A")?.clip)
        #expect(!clip.envelope.isEmpty && clip.ride == Self.ride(500))
    }

    /// `setEnvelope` (`clip_envelope`) writes the envelope only; the ride stays equal.
    @Test mutating func setEnvelopeKeepsTheRide() throws {
        try place("A", on: "t", start: 0, length: 1_000_000)
        try session.setRides(["A": Self.ride(500)])

        try session.setEnvelope([100_000: Gain(dB: -6)!], clip: "A")

        let clip = try #require(session.clip("A")?.clip)
        #expect(clip.envelope == envelope([(100_000, -6)]) && clip.ride == Self.ride(500))
    }

    /// Two parts with other ride lists do not heal; with equal lists they heal to the list.
    @Test mutating func healNeedsEqualRides() throws {
        try place("A", on: "t", start: 0, length: 1_000_000)
        try session.setRides(["A": Self.ride(500)])
        try session.splitClips(at: [400_000], on: ["t"])
        try session.setRides(["A@400000": Self.ride(500, shift: 0.01)])

        #expect(throws: SessionError.nothingToHeal) { try session.heal() }
        #expect(session.track("t")!.clips.count == 2)

        try session.setRides(["A@400000": Self.ride(500)])
        #expect(try session.heal() == ["A"])
        #expect(session.clip("A")?.clip.ride == Self.ride(500))
    }

    /// Whether two ride lists hold their points in one storage. The compare stays inside the closures.
    static func sameArray(_ a: GainEnvelope, _ b: GainEnvelope) -> Bool {
        a.points.withUnsafeBufferPointer { x in
            b.points.withUnsafeBufferPointer { x.baseAddress == $0.baseAddress }
        }
    }

    /// Whether `rides` is not empty and all its lists hold their points in one storage.
    static func shareOneArray(_ rides: [GainEnvelope]) -> Bool {
        guard let first = rides.first else { return false }
        return rides.allSatisfy { sameArray($0, first) }
    }

    /// Each edit that maps ride lists maps each distinct list once, so the 200 parts of A keep
    /// one array, and B (another list) keeps its own. A heal of parts with one list keeps the array.
    @Test mutating func repointKeepsOneListForEachDistinctList() throws {
        let (a, b) = (Self.ride(1_000), Self.ride(1_000, shift: 0.01))
        try place("A", on: "t", start: 0, offset: 1_000_000, length: 100_000_000)
        try place("B", on: "u", file: "g", start: 0, offset: 2_000_000, length: 50_000_000)
        try session.splitClips(at: (1..<200).map { Frames($0 * 500_000) }, on: ["t"])
        let parts = session.track("t")!.clips.map(\.id)
        try session.setRides(Dictionary(uniqueKeysWithValues: parts.map { ($0, a) } + [(ClipID("B"), b)]))
        let source = session
        func lane(_ session: Session, _ track: TrackID) -> [Clip] { Array(session.track(track)!.clips) }
        #expect(Self.shareOneArray(lane(source, "t").map(\.ride)))

        var rendered = source
        let runs = try rendered.clipRuns(of: parts + ["B"]).map {
            RenderedRun(run: $0, stem: "\($0.file) NR", treatment: Treatment(.noise(.standard)), addedGain: .zero)
        }
        _ = try rendered.repoint(runs)
        // The run of A reaches 10 s (480 000 frames) of handle before the first part.
        let span = try #require(runs.first { $0.run.file == "f" }).run.span
        let (shift, length) = (Frames.zero - span.lowerBound, span.upperBound - span.lowerBound)
        let renderedParts = lane(rendered, "t")
        #expect(
            Self.shareOneArray(renderedParts.map(\.ride))
                && !Self.sameArray(lane(rendered, "u")[0].ride, renderedParts[0].ride))
        #expect(span.lowerBound == 520_000 && renderedParts[0].ride == a.moved(by: shift, fileLength: length))

        var restored = rendered
        try restored.restoreOriginals(parts + ["B"])
        #expect(Self.shareOneArray(lane(restored, "t").map(\.ride)))
        #expect(
            lane(restored, "t")[0].ride == renderedParts[0].ride.moved(by: span.lowerBound, fileLength: 345_600_000))

        var split = source
        let pairs = try split.clipRuns(of: parts).map { MonoPair(run: $0, leftStem: "f L", rightStem: "f R") }
        _ = try split.splitStereo(pairs, names: ("L", "R"))
        let sides = split.tracks.filter { $0.layout == .mono }.flatMap(\.clips)
        #expect(sides.count == 400 && Self.shareOneArray(sides.map(\.ride)))
        #expect(sides[0].ride == a.moved(by: shift, fileLength: length))

        let excerpt = try source.excerpt(of: parts + ["B"])
        let scaled = excerpt.resampled(to: 44_100, lengths: ["f": 317_520_000, "g": 317_520_000])
        let scaledParts = scaled.lanes.flatMap(\.clips).filter { $0.file == "f" }
        func scale(_ frames: Frames) -> Frames { Frames((2 * frames.count * 44_100 + 48_000) / 96_000) }
        #expect(scaledParts.count == 200 && Self.shareOneArray(scaledParts.map(\.ride)))
        #expect(scaledParts[0].ride == a.resampled(scale, fileLength: 317_520_000))

        var healed = source
        #expect(try healed.heal(tracks: ["t"]) == [parts[0]])
        #expect(Self.shareOneArray((lane(healed, "t") + lane(source, "t")).map(\.ride)))
    }
}
