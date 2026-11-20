import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0077 D9: the session edit of a drift fix.
struct SessionDriftEditTests {
    /// The ratio of the worked example: m = +100e-6.
    static let ratio = 1 / (1 + 100e-6)

    /// A 48 kHz session with the plain mono file "guest" (28 800 000 frames) and, on track "t", the
    /// clip "c" of the whole file at start 48 000 with `gain` and fades of 480 and 960 frames.
    static func session(gain: Double = 0) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "guest", path: "guest.wav", layout: .mono, length: 28_800_000))
        try session.addTrack("t", name: "Guest", layout: .mono)
        let clip = Clip(
            id: "c", file: "guest", start: 48_000, offset: 0, length: 28_800_000, gain: try #require(Gain(dB: gain)),
            fades: try #require(Fades(fadeIn: 480, fadeOut: 960)))
        try session.place(clip, on: "t")
        return session
    }

    static func file(_ stem: String, _ length: Frames, gain: Double = 0) throws -> DriftFile {
        DriftFile(stem: stem, length: length, gain: try #require(Gain(dB: gain)))
    }

    /// The worked example: one segment with m = +100e-6 and b = 4800 on the whole clip. The new file links to
    /// "guest" at offset 0 and holds 28 802 881 frames for a written 28 802 881 or 28 802 882. The
    /// clip keeps its ID and fades, starts at 52 800, and plays 28 802 880 frames from frame 0. A
    /// returned +3.01 dB on +95 dB gives +96 dB and a link gain of +1 dB. A second fix of the clip
    /// resamples "guest" again and takes the +1 dB off first. A refused edit changes nothing.
    @Test(arguments: [Frames(28_802_881), Frames(28_802_882)])
    func theWorkedExampleGivesItsFrames(written: Frames) throws {
        var session = try Self.session(gain: 95)
        let lines = try #require(DriftLines(slope: 100e-6, lags: [4800], cuts: []))
        let before = session

        #expect(throws: SessionError.duplicateID("guest")) {
            try session.correctDrift("c", lines: lines, files: [try Self.file("guest", written, gain: 3.01)])
        }
        #expect(session == before)
        let plan = try session.driftPlan(of: "c", lines: lines)
        let result = try session.correctDrift(
            "c", lines: lines, files: [try Self.file("guest drift", written, gain: 3.01)])

        #expect(plan.source == "guest" && plan.spans == [0..<28_800_000])
        #expect(plan.ratio.value.bitPattern == Self.ratio.bitPattern)
        #expect(result == DriftCorrection(clips: ["c"], files: ["guest drift"], cut: SyncCut(head: 0, replaced: [])))
        let file = try #require(session.files["guest drift"])
        let link = DriftOrigin(
            source: "guest", offset: 0, ratio: try #require(DriftRatio(Self.ratio)),
            addedGain: try #require(Gain(dB: 1)))
        #expect(file.length == 28_802_881 && file.drift == link && file.path == "guest drift.wav")
        let clip = try #require(session.clip("c")?.clip)
        #expect(clip.file == "guest drift" && clip.start == 52_800 && clip.offset == 0 && clip.length == 28_802_880)
        #expect(clip.fades == before.clip("c")?.clip.fades && clip.gain.dB == 96)

        let again = try #require(DriftLines(slope: 0, lags: [0], cuts: []))
        let second = try session.driftPlan(of: "c", lines: again)
        try session.correctDrift("c", lines: again, files: [try Self.file("guest drift 2", 28_802_881, gain: 3.01)])

        #expect(second.source == "guest" && second.spans == [0..<28_800_000])
        #expect(session.files["guest drift 2"]?.drift?.addedGain.dB == 1 && session.clip("c")?.clip.gain.dB == 96)
        #expect(session.files["guest drift 2"]?.drift?.source == "guest")
    }

    /// The envelope and the ride points move through the time map, round((f - offset) / ratio).
    /// One piece: old file frame 14 400 000 goes to 14 401 440. With a cut at clip frame 14 400 000,
    /// the second file starts at source frame 13 920 000, so the same point goes to 480 048.
    @Test func theEnvelopeMovesThroughTheTimeMap() throws {
        var session = try Self.session()
        let points = { (pairs: [(Frames, Double)]) in
            GainEnvelope(pairs.map { GainEnvelope.Point(frame: $0.0, gain: Gain(dB: $0.1)!) })
        }
        try session.setEnvelopes(["c": try #require(points([(0, -6), (14_400_000, 0), (28_800_000, -3)]))])
        try session.setRides(["c": try #require(points([(7_200_000, 2), (21_600_000, -2)]))])
        var cut = session
        let one = try #require(DriftLines(slope: 100e-6, lags: [4800], cuts: []))
        let two = try #require(DriftLines(slope: 100e-6, lags: [4800, 964_800], cuts: [14_400_000]))

        try session.correctDrift("c", lines: one, files: [try Self.file("guest drift", 28_802_881)])
        try cut.correctDrift(
            "c", lines: two, files: [try Self.file("guest a", 14_881_489), try Self.file("guest b", 14_881_489)])

        let clip = try #require(session.clip("c")?.clip)
        #expect(clip.envelope.points.map(\.frame) == [0, 14_401_440, 28_802_880])
        #expect(clip.envelope.points.map(\.gain.dB) == [-6, 0, -3])
        #expect(clip.ride.points.map(\.frame) == [7_200_720, 21_602_160])
        let right = try #require(cut.clip("c@14448000")?.clip)
        #expect(right.file == "guest b" && right.envelope.points.map(\.frame).contains(480_048))
        #expect(right.envelope.gain(at: 480_048) == 0)
    }

    /// A pause splits the clip at the cut. The right piece is "c@14448000" on its own file
    /// at start 15 414 240 (the start uses m x c0) and offset 480 048. The clip "d" under the new
    /// range of the right piece loses its head and is named; the clip "e" past it stays. A start of
    /// -4800 cuts the head of the clip, as a sync does.
    @Test func aClipUnderTheNewRangeIsCutAndNamed() throws {
        var early = try Self.session()
        let back = try #require(DriftLines(slope: 100e-6, lags: [-52_800], cuts: []))
        let headCut = try early.correctDrift("c", lines: back, files: [try Self.file("guest drift", 28_802_881)])
        let moved = try #require(early.clip("c")?.clip)
        #expect(headCut.cut == SyncCut(head: 4800, replaced: []))
        #expect(moved.start == 0 && moved.offset == 4800 && moved.length == 28_798_080)

        var session = try Self.session()
        try session.addFile(AudioFile(id: "other", path: "other.wav", layout: .mono, length: 48_000_000))
        try session.place(Clip(id: "d", file: "other", start: 28_848_000, offset: 0, length: 1_000_000), on: "t")
        try session.place(Clip(id: "e", file: "other", start: 40_000_000, offset: 0, length: 48_000), on: "t")
        let lines = try #require(DriftLines(slope: 100e-6, lags: [4800, 964_800], cuts: [14_400_000]))
        let e = session.clip("e")?.clip

        let plan = try session.driftPlan(of: "c", lines: lines)
        let result = try session.correctDrift(
            "c", lines: lines, files: [try Self.file("guest a", 14_881_489), try Self.file("guest b", 14_881_489)])

        #expect(plan.spans == [0..<14_880_000, 13_920_000..<28_800_000])
        #expect(result.clips == ["c", "c@14448000"] && result.files == ["guest a", "guest b"])
        #expect(result.cut == SyncCut(head: 0, replaced: ["d"]))
        let left = try #require(session.clip("c")?.clip)
        let right = try #require(session.clip("c@14448000")?.clip)
        #expect(left.file == "guest a" && left.start == 52_800 && left.offset == 0 && left.length == 14_401_440)
        #expect(right.file == "guest b" && right.start == 15_414_240 && right.offset == 480_048)
        #expect(right.length == 14_401_440 && session.files["guest b"]?.drift?.offset == 13_920_000)
        let d = try #require(session.clip("d")?.clip)
        #expect(d.start == 29_815_680 && d.offset == 967_680 && session.clip("e")?.clip == e)
    }

    /// Over ratios from -999 to +999 ppm, spans that end at the source end, and written
    /// lengths of floor, floor + 1, and ceil + 1 of the exact length, each edit passes the drift check,
    /// the session reads back from its XML, and the record is at most 1 frame shorter than its file.
    @Test func eachEditPassesTheDriftCheck() throws {
        var random = SplitMix(seed: 77)
        var failures: [String] = []
        for index in 0..<300 {
            let ppm = index < 2 ? Double(index == 0 ? -999 : 999) : Double.random(in: -999...999, using: &random)
            let ratio = 1 + ppm * 1e-6
            let length = Int.random(in: 14_400_000...345_600_000, using: &random)
            let offset = Int.random(in: 0..<length / 2, using: &random)
            let lag = Double.random(in: 0...48_000, using: &random)
            let spanStart = max(0, offset - 480_000)
            let exact = Double(length - spanStart) / ratio
            for written in [exact.rounded(.down), exact.rounded(.down) + 1, exact.rounded(.up) + 1].map(Int.init) {
                var session = Session(sampleRate: 48_000)
                try session.addFile(AudioFile(id: "s", path: "s.wav", layout: .mono, length: Frames(length)))
                try session.addTrack("t", name: "T", layout: .mono)
                try session.place(
                    Clip(id: "c", file: "s", start: 96_000, offset: Frames(offset), length: Frames(length - offset)),
                    on: "t")
                let lines = try #require(DriftLines(slope: 1 / ratio - 1, lags: [lag], cuts: []))
                let label = "ppm \(ppm), source \(length), offset \(offset), written \(written)"
                do {
                    try session.correctDrift("c", lines: lines, files: [try Self.file("d", Frames(written))])
                    let record = session.files["d"]?.length.count ?? -1
                    if !(written - 1...written).contains(record) { failures.append("\(label): record \(record)") }
                    if try Session(xml: session.checkedData()) != session { failures.append("\(label): read back") }
                } catch {
                    failures.append("\(label): \(error)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failures, first: \(failures.prefix(3))")
    }
}
