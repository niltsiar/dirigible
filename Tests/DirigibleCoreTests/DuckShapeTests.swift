import Foundation
import Testing

@testable import DirigibleCore

/// The shape of a duck (decision 0060, C15), as a seeded property over speech runs, shapes, and
/// clips on the file map of a music track.
struct DuckShapeTests {
    /// A seeded generator, so a failing case can run again.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// The expected duck at timeline frame `t`: `depth` on each run, linear ramps of the attack
    /// before and the release after, 0 dB elsewhere. The runs are merged and far apart.
    static func expected(_ t: Int, runs: [Range<Frames>], shape: DuckShape) -> Double {
        let (a, r) = (max(shape.attack.count, 1), max(shape.release.count, 1))
        for run in runs {
            let (s, e) = (run.lowerBound.count, run.upperBound.count)
            if t >= s - a, t < s { return shape.depth.dB * Double(t - (s - a)) / Double(a) }
            if t >= s, t <= e { return shape.depth.dB }
            if t > e, t < e + r { return shape.depth.dB * Double(e + r - t) / Double(r) }
        }
        return 0
    }

    /// A music track `m` with clip `c1` of file `f1` (`fileLength` frames) at `start`, playing from
    /// `offset` for `length` frames, with `envelope`.
    static func session(
        fileLength: Int, start: Int, offset: Int, length: Int, envelope: GainEnvelope = .empty
    ) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(fileLength)))
        try session.addTrack("m", name: "Music", layout: .mono)
        try session.place(
            Clip(
                id: "c1", file: "f1", start: Frames(start), offset: Frames(offset), length: Frames(length),
                envelope: envelope), on: "m")
        return session
    }

    /// 300 seeded cases: the played gain equals the shape at each sampled frame, the frames ascend
    /// strictly inside the file, a second duck changes nothing, and the points outside the clip
    /// window stay. Some runs have ramps that pass both file ends.
    @Test func theDuckFollowsTheShapeAndDoesNotStack() throws {
        var random = Seeded(state: 20_261_018)
        var ducks = 0
        for _ in 0..<300 {
            let fileLength = Int.random(in: 100_000...2_000_000, using: &random)
            let offset = Int.random(in: 0...(fileLength / 4), using: &random)
            let length = Int.random(in: 1_000...(fileLength - offset), using: &random)
            let start = Int.random(in: 0...500_000, using: &random)
            let shape = DuckShape(
                depth: Gain(dB: -Double.random(in: 1...40, using: &random))!,
                attack: Frames(Int.random(in: 0...200_000, using: &random)),
                release: Frames(Int.random(in: 0...200_000, using: &random)), threshold: Gain(dB: -40)!,
                hold: Frames(Int.random(in: 0...96_000, using: &random)))
            var runs: [Range<Frames>] = []
            var cursor = start - Int.random(in: 0...300_000, using: &random)
            for _ in 0..<Int.random(in: 1...5, using: &random) {
                cursor += Int.random(in: 1...300_000, using: &random)
                let end = cursor + Int.random(in: 1...300_000, using: &random)
                runs.append(Frames(max(cursor, 0))..<Frames(max(end, 1)))
                cursor = end
            }
            // Points outside the clip window on one side or both.
            var outside: [GainEnvelope.Point] = []
            if offset > 10, Bool.random(using: &random) { outside.append(.init(frame: 0, gain: Gain(dB: -6)!)) }
            if offset + length < fileLength - 10, Bool.random(using: &random) {
                outside.append(.init(frame: Frames(fileLength), gain: Gain(dB: -3)!))
            }
            let before = try #require(GainEnvelope(outside))
            var session = try Self.session(
                fileLength: fileLength, start: start, offset: offset, length: length, envelope: before)
            let merged = shape.merged(runs.map { $0.clamped(to: 0..<Frames(start + length)) })
            let first: DuckResult
            do throws(SessionError) {
                first = try session.duck(runs: runs, shape: shape, music: ["m"], scope: nil)
            } catch {
                // Every run lies before the clip window and session end clamps none: no speech.
                guard case .noSpeech = error else { throw error }
                continue
            }
            let clip = try #require(session.clip("c1")?.clip)
            if first.kept == ["c1"] {
                #expect(clip.envelope == before, "a clip that no run reaches changed")
                continue
            }
            ducks += 1
            let points = clip.envelope.points
            #expect(GainEnvelope(points) != nil && points.allSatisfy { $0.frame.count <= fileLength })
            for point in outside { #expect(points.contains(point), "a point outside the window was lost") }
            for _ in 0..<40 {
                let t = Int.random(in: start..<(start + length), using: &random)
                let played = clip.envelope.gain(at: Frames(t - start + offset))
                let want = Self.expected(t, runs: merged, shape: shape)
                #expect(abs(played - want) < 1e-6, "frame \(t): \(played) dB, want \(want) dB")
            }
            let once = session
            try session.duck(runs: runs, shape: shape, music: ["m"], scope: nil)
            #expect(session == once, "a second duck changed the envelope")
        }
        #expect(ducks > 200, "only \(ducks) of 300 seeds ducked")
    }

    /// A clip that no run, widened by the attack and the release, reaches keeps its envelope, and
    /// the result names it.
    @Test func aClipThatNoRunReachesKeepsItsEnvelope() throws {
        let fade = try #require(
            GainEnvelope([.init(frame: 0, gain: Gain(dB: -30)!), .init(frame: 48_000, gain: .zero)]))
        var session = try Self.session(fileLength: 480_000, start: 0, offset: 0, length: 480_000, envelope: fade)
        try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 480_000))
        try session.place(Clip(id: "c2", file: "f2", start: 1_000_000, offset: 0, length: 480_000), on: "m")
        let shape = DuckShape.defaults(sampleRate: 48_000)
        let result = try session.duck(runs: [1_200_000..<1_300_000], shape: shape, music: ["m"], scope: nil)
        #expect(result.kept == ["c1"] && result.ducked == ["c2"])
        #expect(session.clip("c1")?.clip.envelope == fade)
    }

    /// A range edge inside a clip joins the old value with a 500 ms ramp inside the range.
    @Test func aRangeEdgeJoinsTheOldValueWithAHalfSecondRamp() throws {
        var session = try Self.session(fileLength: 960_000, start: 0, offset: 0, length: 960_000)
        let shape = DuckShape.defaults(sampleRate: 48_000)
        try session.duck(runs: [200_000..<700_000], shape: shape, music: ["m"], scope: 240_000..<720_000)
        let envelope = try #require(session.clip("c1")?.clip.envelope)
        #expect(envelope.gain(at: 240_000) == 0 && envelope.gain(at: 264_000) == -16)
        #expect(envelope.gain(at: 696_000) == -16 && envelope.gain(at: 720_000) == 0)
        #expect(envelope.gain(at: 100_000) == 0 && envelope.gain(at: 800_000) == 0)
    }

    /// A range of 1 frame inside a clip changes no frame after it: each frame from the range end to
    /// the clip end keeps the old gain.
    @Test func aOneFrameRangeKeepsTheGainAfterIt() throws {
        let before = try #require(
            GainEnvelope([.init(frame: 0, gain: Gain(dB: -6)!), .init(frame: 480_000, gain: Gain(dB: -3)!)]))
        var session = try Self.session(fileLength: 480_000, start: 0, offset: 0, length: 480_000, envelope: before)
        try session.duck(
            runs: [0..<480_000], shape: .defaults(sampleRate: 48_000), music: ["m"], scope: 100_000..<100_001)
        let envelope = try #require(session.clip("c1")?.clip.envelope)
        for frame in Array(0..<100_000) + Array(100_001..<480_000) {
            let (now, old) = (envelope.gain(at: Frames(frame)), before.gain(at: Frames(frame)))
            guard abs(now - old) < 1e-9 else {
                Issue.record("frame \(frame): \(now) dB, want the old \(old) dB")
                return
            }
        }
    }

    /// 300 seeded ranges, some shorter than a ramp or 1 frame long: each played frame outside the
    /// range keeps its old gain, also the frame at the range end and the frame before its start.
    @Test func aRangeChangesNoFrameOutsideIt() throws {
        var random = Seeded(state: 20_261_022)
        var ducks = 0
        for _ in 0..<300 {
            let fileLength = Int.random(in: 100_000...1_000_000, using: &random)
            let offset = Int.random(in: 0...(fileLength / 4), using: &random)
            let length = Int.random(in: 1_000...(fileLength - offset), using: &random)
            let start = Int.random(in: 0...200_000, using: &random)
            let ramp = Int.random(in: 0...100_000, using: &random)
            let shape = DuckShape(
                depth: Gain(dB: -Double.random(in: 1...40, using: &random))!, attack: Frames(ramp),
                release: Frames(Int.random(in: 0...100_000, using: &random)), threshold: Gain(dB: -40)!,
                hold: Frames(Int.random(in: 0...96_000, using: &random)))
            let frames = (0..<Int.random(in: 0...4, using: &random)).map { _ in
                Int.random(in: 0...fileLength, using: &random)
            }
            var points: [GainEnvelope.Point] = []
            for frame in Set(frames).sorted() {
                points.append(.init(frame: Frames(frame), gain: Gain(dB: -Double.random(in: 0...20, using: &random))!))
            }
            let before = try #require(GainEnvelope(points))
            let short = [1, 2, 3, Int.random(in: 1...(2 * ramp + 2), using: &random)]
            let scopeLength = short[Int.random(in: 0..<short.count, using: &random)]
            let low = max(0, Int.random(in: (start - 2_000)...(start + length), using: &random))
            let scope = Frames(low)..<Frames(low + scopeLength)
            let runStart = max(0, low - Int.random(in: 0...200_000, using: &random))
            let runs = [Frames(runStart)..<Frames(low + scopeLength + Int.random(in: 0...200_000, using: &random))]
            var session = try Self.session(
                fileLength: fileLength, start: start, offset: offset, length: length, envelope: before)
            do throws(SessionError) {
                try session.duck(runs: runs, shape: shape, music: ["m"], scope: scope)
            } catch {
                guard case .noSpeech = error else { throw error }
                continue
            }
            ducks += 1
            let envelope = try #require(session.clip("c1")?.clip.envelope)
            let window = start..<(start + length)
            let edges = [scope.lowerBound.count - 1, scope.upperBound.count]
            let samples = (0..<40).map { _ in Int.random(in: window, using: &random) }
            for t in edges + samples where window.contains(t) && !scope.contains(Frames(t)) {
                let file = Frames(t - start + offset)
                let (now, old) = (envelope.gain(at: file), before.gain(at: file))
                #expect(abs(now - old) < 1e-6, "scope \(scope), frame \(t): \(now) dB, want the old \(old) dB")
            }
        }
        #expect(ducks > 200, "only \(ducks) of 300 seeds ducked")
    }

    /// No run throws `noSpeech` with the scope and the threshold, and changes nothing.
    @Test func noRunIsNoSpeech() throws {
        var session = try Self.session(fileLength: 480_000, start: 0, offset: 0, length: 480_000)
        let before = session
        #expect(throws: SessionError.noSpeech(0..<480_000, threshold: -40)) {
            try session.duck(runs: [], shape: .defaults(sampleRate: 48_000), music: ["m"], scope: nil)
        }
        #expect(session == before)
    }
}
