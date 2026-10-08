import DirigibleCore
import Testing

/// The edge scale of a paste from a package of another rate (decision 0042, C10a).
struct ExcerptResampleTests {
    /// 1,000 seeded lanes of touching clips with fades and crossfades, in both directions: each
    /// touching pair still touches, both clips of a join keep one crossfade, and the paste of the
    /// scaled excerpt passes every check of `Session`. Control: a scale of each length in place
    /// of each edge gives a gap or an overlap.
    @Test(arguments: [(44_100, 48_000), (48_000, 44_100)])
    func scaledEdgesKeepJoinsAndFitTheFile(from: Int, to: Int) throws {
        var random = SplitMix(seed: UInt64(from))
        let fileLength = 20_000_000
        let converted = Frames((2 * fileLength * to + from) / (2 * from))
        var failures = 0
        for _ in 0..<1_000 {
            var session = Session(sampleRate: from)
            try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: Frames(fileLength)))
            try session.addTrack("t", name: "T", layout: .mono)
            var start = Int.random(in: 0..<5_000, using: &random)
            var ids: [ClipID] = []
            for index in 0..<Int.random(in: 2...6, using: &random) {
                let length = Int.random(in: 3_001...50_000, using: &random)
                // A small offset makes a short media handle, so a crossfade at its limit clamps.
                let offset =
                    Bool.random(using: &random)
                    ? Int.random(in: 1...3_000, using: &random) : Int.random(in: 100_000...15_000_000, using: &random)
                let id = ClipID("c\(index)")
                try session.place(
                    Clip(
                        id: id, file: "f", start: Frames(start), offset: Frames(offset), length: Frames(length),
                        fades: Fades(fadeIn: Frames(length / 7), fadeOut: Frames(length / 5))!), on: "t")
                ids.append(id)
                start += length
            }
            // Code gate 2 nit: a split makes a seamless join, which must stay seamless.
            if Bool.random(using: &random), let first = session.track("t")?.clips.first {
                _ = try session.split(first.id, at: first.start + Frames(first.length.count / 2))
                ids = session.track("t").map { $0.clips.map(\.id) } ?? ids
            }
            // Gate 1 item 1: half of the joins take the longest crossfade (`crossfadeLimit`).
            for (index, id) in ids.dropLast().enumerated() where Bool.random(using: &random) {
                let lane = try #require(session.track("t")).clips
                let limit = session.crossfadeLimit(after: index, in: lane) ?? .zero
                let value =
                    Bool.random(using: &random)
                    ? limit : min(limit, Frames(2 * Int.random(in: 1...1_000, using: &random)))
                if value > .zero { try session.setCrossfades([id: value]) }
            }
            let excerpt = try session.excerpt(of: 0..<Frames(start + 1_000), on: ["t"])

            let scaled = excerpt.resampled(to: to, lengths: ["f": converted])

            let clips = scaled.lanes[0].clips
            let touching = zip(clips, clips.dropFirst()).allSatisfy { $0.end == $1.start }
            let joined = zip(clips, clips.dropFirst()).allSatisfy { $0.crossfades.end == $1.crossfades.start }
            var target = Session(sampleRate: to)
            try target.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: converted))
            try target.addTrack("t", name: "T", layout: .mono)
            // A lane with an overlap would trap in `ClipLane`, so it counts as a failure before the paste.
            let pasted = touching && (try? target.paste(scaled, at: 0, on: ["t"])) != nil
            let kept = clips.map(\.crossfades) == target.track("t").map { $0.clips.map(\.crossfades) }
            // Code gate 2 item 1: a join with a source crossfade keeps one (at most the scaled value
            // and the limit of the pasted lane) unless that limit is under 2 frames.
            var live = true
            if pasted, let lane = target.track("t")?.clips {
                for index in 0..<max(0, lane.count - 1) {
                    let source = excerpt.lanes[0].clips[index].crossfades.end
                    guard source > .zero, let limit = target.crossfadeLimit(after: index, in: lane) else { continue }
                    let value = lane[index].crossfades.end
                    let even = Frames(2 * ((source.count * to + from) / (2 * from)))
                    if value > even || value > limit || (limit >= 2 && value == .zero) { live = false }
                }
            }
            let sources = excerpt.lanes[0].clips
            let seamless = zip(sources.indices.dropLast(), sources.indices.dropFirst()).allSatisfy { i, j in
                !sources[i].isSeamless(with: sources[j]) || clips[i].isSeamless(with: clips[j])
            }
            if !(touching && joined && pasted && kept && live && seamless && scaled.sampleRate == to) { failures += 1 }
        }
        #expect(failures == 0, "\(failures) of 1000 lanes broke a join or a check")
    }

    /// Literal edges at 44 100 to 48 000 Hz: 88 200 -> 96 000, a 441-frame fade -> 480, an
    /// 882-frame crossfade -> 960, and the length stops at the converted file end.
    @Test func literalEdgesScaleToTheNearestFrame() throws {
        var session = Session(sampleRate: 44_100)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 176_400))
        try session.addTrack("t", name: "T", layout: .mono)
        try session.place(
            Clip(id: "A", file: "f", start: 0, offset: 0, length: 88_200, fades: Fades(fadeIn: 441, fadeOut: 0)!),
            on: "t")
        try session.place(Clip(id: "B", file: "f", start: 88_200, offset: 88_201, length: 88_199), on: "t")
        try session.setCrossfades(["A": 882])
        let excerpt = try session.excerpt(of: 0..<176_399, on: ["t"])

        let scaled = excerpt.resampled(to: 48_000, lengths: ["f": 191_999])

        let clips = scaled.lanes[0].clips
        #expect(clips.map(\.start) == [0, 96_000] && clips.map(\.length) == [96_000, 95_998])
        #expect(clips.map(\.offset) == [0, 96_001], "B stops at the file end: 96 001 + 95 998 = 191 999")
        #expect(clips[0].fades.fadeIn == 480 && clips[0].crossfades.end == 960 && clips[1].crossfades.start == 960)
        #expect(scaled.length == 191_999 && scaled.files["f"]?.length == 191_999 && scaled.sampleRate == 48_000)
    }
}
