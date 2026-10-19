import Foundation
import Testing

@testable import DirigibleCore

/// The range gain and the set of the envelope (decision 0060, C6 and C7). Track "t1" (mono); files
/// "fa" and "fb" of 60 000 frames.
struct RangeGainTests {
    static let fileLength = 60_000

    static func session(_ clips: [Clip]) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for id in ["fa", "fb"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: Frames(fileLength)))
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Music", layout: .mono)
        for clip in clips { try session.place(clip, on: "t1") }
        return session
    }

    /// The window of a range gain at the timeline frame `t`: 1 in `range`, 0 at `ramp` frames or more
    /// outside it, and linear between.
    static func window(_ t: Int, _ range: Range<Int>, ramp: Int) -> Double {
        if range.contains(t) { return 1 }
        let distance = t < range.lowerBound ? range.lowerBound - t : t - (range.upperBound - 1)
        return max(0, 1 - Double(distance) / Double(ramp))
    }

    /// C7 worked values: -16 dB on 20 000..<30 000 with 5000-frame ramps outside the range, on a clip
    /// with no point that plays the file from frame 0 at timeline frame 0.
    @Test func aRangeGainOnAClipWithNoPointAddsFourCorners() throws {
        var session = try Self.session([Clip(id: "c", file: "fa", start: 0, offset: 0, length: 60_000)])
        let changed = try session.changeGain(by: Gain(dB: -16)!, in: 20_000..<30_000, on: ["t1"], ramp: 5_000)
        #expect(changed == ["c"])
        let points = session.clip("c")?.clip.envelope.points.map { [$0.frame.count, Int($0.gain.dB)] }
        #expect(points == [[15_000, 0], [20_000, -16], [29_999, -16], [34_999, 0]])
    }

    /// C7 property: for seeded clips, envelopes, ranges, and ramps, the gain at each file frame is the
    /// old gain plus d times the window, on the file map of the clip, and the frames ascend strictly
    /// inside the file. The ranges and ramps pass both file ends. A clip that plays no frame of the
    /// widened range keeps its envelope. Controls: no ramps fails at the ramp middle; a corner moved
    /// to the file edge gives two points on one frame.
    @Test(arguments: [UInt64(1), 2, 3])
    func aRangeGainAddsATrapezoid(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &random) }
        func randomEnvelope() -> GainEnvelope {
            let frames = Set((0..<int(0...5)).map { _ in int(0...Self.fileLength) }).sorted()
            return envelope(frames.map { ($0, Double(int(-20...0))) })
        }
        var (pastStart, pastEnd, wrong) = (0, 0, [String]())
        for step in 0..<150 {
            let offset = int(0...20_000)
            let clip = Clip(
                id: "c", file: "fa", start: Frames(int(20_000...40_000)), offset: Frames(offset),
                length: Frames(int(1_000...(Self.fileLength - offset))), envelope: randomEnvelope())
            let far = Clip(
                id: "far", file: "fb", start: 200_000, offset: 0, length: 10_000, envelope: randomEnvelope())
            var session = try Self.session([clip, far])
            let low = int((clip.start.count - 10_000)...clip.end.count)
            let range = low..<int((low + 1)...(clip.end.count + 10_000))
            let (ramp, d) = (int(1...30_000), Double(int(-20...6)))
            let changed = try session.changeGain(
                by: Gain(dB: d)!, in: Frames(range.lowerBound)..<Frames(range.upperBound), on: ["t1"],
                ramp: Frames(ramp))
            let after = try #require(session.clip("c")?.clip.envelope)
            let shift = clip.start.count - clip.offset.count

            // A clip that plays no frame where the window is more than 0 keeps its envelope.
            let reach = (range.lowerBound - ramp + 1)..<(range.upperBound + ramp - 1)
            guard reach.overlaps(clip.start.count..<clip.end.count) else {
                if after != clip.envelope || !changed.isEmpty {
                    wrong.append("step \(step): a clip out of reach changed")
                }
                continue
            }
            if range.lowerBound - ramp - shift < 0 { pastStart += 1 }
            if range.upperBound - 1 + ramp - shift > Self.fileLength { pastEnd += 1 }
            let frames = after.points.map(\.frame.count)
            if !zip(frames, frames.dropFirst()).allSatisfy({ $0 < $1 })
                || !frames.allSatisfy({ (0...Self.fileLength).contains($0) })
            {
                wrong.append("step \(step): frames \(frames)")
            }
            let corners =
                [range.lowerBound - ramp, range.lowerBound, range.upperBound - 1, range.upperBound - 1 + ramp]
                .map { $0 - shift } + clip.envelope.points.map(\.frame.count)
            let probes = Set(
                corners.flatMap { [$0 - 1, $0, $0 + 1] } + Array(stride(from: 0, through: Self.fileLength, by: 997))
                    + [range.lowerBound - ramp / 2 - shift, range.upperBound - 1 + ramp / 2 - shift])
            for f in probes.sorted() where (0...Self.fileLength).contains(f) {
                let expected = clip.envelope.gain(at: Frames(f)) + d * Self.window(f + shift, range, ramp: ramp)
                if abs(after.gain(at: Frames(f)) - expected) > 1e-9 {
                    wrong.append("step \(step): frame \(f) has \(after.gain(at: Frames(f))) dB, not \(expected)")
                }
            }
            if session.clip("far")?.clip.envelope != far.envelope { wrong.append("step \(step): far changed") }
            if changed != (after == clip.envelope ? [] : ["c"]) { wrong.append("step \(step): changed \(changed)") }
        }
        #expect(pastStart > 0 && pastEnd > 0, "no case passed a file end: \(pastStart), \(pastEnd)")
        #expect(wrong.isEmpty, "\(wrong.count) faults, first: \(wrong.prefix(3))")
    }

    /// C6: the set replaces only the points inside the clip window and keeps the points outside it;
    /// an empty set clears the window. The clip plays file frames 20 000..<60 000 at timeline frame
    /// 10 000. Control: a set that replaces the whole list fails.
    @Test func aSetKeepsThePointsOutsideTheClipWindow() throws {
        let points = envelope([(5_000, -3), (30_000, -6), (59_999, -1), (60_000, -9)])
        var session = try Self.session([
            Clip(id: "c", file: "fa", start: 10_000, offset: 20_000, length: 40_000, envelope: points)
        ])
        try session.setEnvelope([15_000: Gain(dB: -12)!, 10_000: Gain(dB: 2)!], clip: "c")
        #expect(session.clip("c")?.clip.envelope == envelope([(5_000, -3), (20_000, 2), (25_000, -12), (60_000, -9)]))
        try session.setEnvelope([:], clip: "c")
        #expect(session.clip("c")?.clip.envelope == envelope([(5_000, -3), (60_000, -9)]))
    }

    /// C6: a frame outside the clip window is refused with the window, and the envelope stays.
    @Test func aSetOutsideTheClipIsRefused() throws {
        let points = envelope([(30_000, -6)])
        var session = try Self.session([
            Clip(id: "c", file: "fa", start: 10_000, offset: 20_000, length: 40_000, envelope: points)
        ])
        for frame in [9_999, 50_000] {
            #expect(throws: SessionError.pointOutsideClip("c", Frames(frame), 10_000..<50_000)) {
                try session.setEnvelope([20_000: .zero, Frames(frame): .zero], clip: "c")
            }
        }
        #expect(session.clip("c")?.clip.envelope == points)
    }
}
