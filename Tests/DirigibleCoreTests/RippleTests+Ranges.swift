import Foundation
import Testing

@testable import DirigibleCore

/// Ripple delete of several ranges in one edit (run ripple-ranges, criteria RR1 to RR4 and RR13).
extension RippleTests {
    /// The session after one ripple delete of each range on track "a", in the given order.
    func cuts(_ ranges: [Range<Frames>]) throws -> Session {
        var copy = session
        for range in ranges { try copy.rippleDelete(range, on: ["a"]) }
        return copy
    }

    /// RR1. Clip A holds two ranges and clip B the third; a marker in each range and one after
    /// the last. Control: the cuts from the first range to the last give another session.
    @Test mutating func severalRangesEqualCutsFromTheLast() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 200_000), on: "a")
        try session.place(Clip(id: "B", file: "f", start: 220_000, offset: 220_000, length: 100_000), on: "a")
        for (id, at) in [("m1", 30_000), ("m2", 110_000), ("m3", 260_000), ("m4", 300_000)] {
            try marker(MarkerID(id), at: Frames(at))
        }
        let ranges: [Range<Frames>] = [20_000..<40_000, 100_000..<130_000, 250_000..<270_000]
        let fromTheLast = try cuts(ranges.reversed())
        let ordered = try cuts(ranges) != fromTheLast
        #expect(ordered, "the fixture tells the order of the cuts")
        try session.rippleDelete(ranges, on: ["a"])
        let same = session == fromTheLast
        #expect(same, "one edit equals the cuts from the last range to the first")
        #expect(
            ["m1", "m2", "m3", "m4"].map { position(MarkerID($0)) } == [20_000, 80_000, 200_000, 230_000],
            "each marker moves left by the removed frames before it")
    }

    /// RR2. The input reversed and in a mixed order gives the same session.
    @Test mutating func theOrderOfTheRangesDoesNotMatter() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 200_000), on: "a")
        try marker("m", at: 150_000)
        let ranges: [Range<Frames>] = [20_000..<40_000, 60_000..<70_000, 100_000..<130_000]
        let expected = try cuts(ranges.reversed())
        for order in [Array(ranges.reversed()), [ranges[1], ranges[2], ranges[0]]] {
            var copy = session
            try copy.rippleDelete(order, on: ["a"])
            let same = copy == expected
            #expect(same, "the order \(order) gives the same session")
        }
    }

    /// RR3. Overlapping ranges and a range inside another range cut their union. The nested case
    /// compares each start with the end of the last merged range: a compare with the range before
    /// it cuts [20 000, 25 000) on its own, so the marker lands at 10 000.
    @Test mutating func overlappingRangesCutTheirUnion() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 60_000), on: "a")
        try marker("m", at: 42_000)
        var overlap = session
        try overlap.rippleDelete([10_000..<15_000, 12_000..<20_000], on: ["a"])
        let overlapped = overlap == (try cuts([10_000..<20_000]))
        #expect(overlapped, "two overlapping ranges cut their union")
        let union = try cuts([10_000..<40_000])
        try session.rippleDelete([10_000..<40_000, 12_000..<15_000, 20_000..<25_000], on: ["a"])
        let nested = session == union
        #expect(nested, "ranges inside a long range cut only the long range")
        #expect(position("m") == 12_000, "the marker after the long range moves left by 30 000")
    }

    /// RR3. Touching ranges cut as one range, so the part after the cut keeps the clip ID (two
    /// cuts name it "A@20000"). Threshold: a gap of 1 frame keeps frame 10 000.
    @Test mutating func touchingRangesCutAsOne() throws {
        try session.place(Clip(id: "A", file: "f", start: 5_000, offset: 5_000, length: 25_000), on: "a")
        var touching = session
        try touching.rippleDelete([5_000..<10_000, 10_000..<20_000], on: ["a"])
        let merged = touching == (try cuts([5_000..<20_000]))
        #expect(merged, "touching ranges equal their union")
        #expect(
            touching.track("a")?.clips.map(\.id) == ["A"], "the part after one cut keeps the clip ID")
        let gap: [Range<Frames>] = [5_000..<10_000, 10_001..<20_000]
        let expected = try cuts(gap.reversed())
        try session.rippleDelete(gap, on: ["a"])
        let apart = session == expected
        #expect(apart, "a gap of 1 frame cuts two ranges")
        #expect(
            lane("a").map { [$0.start, $0.offset, $0.length] } == [[5_000, 10_000, 1], [5_001, 20_000, 10_000]],
            "frame 10 000 stays")
    }

    /// RR4. A range past the limit, last in the input and after the sort, throws and changes
    /// nothing. Control: the first range alone changes the session. An empty range is skipped.
    @Test mutating func aBadRangeInTheListChangesNothing() throws {
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 60_000), on: "a")
        try marker("m", at: 30_000)
        let before = session
        let reached = try cuts([10_000..<20_000]) != before
        #expect(reached, "the first range alone changes the session")
        #expect(throws: SessionError.frameOutOfRange) {
            try session.rippleDelete([10_000..<20_000, (Frames.limit - 10)..<(Frames.limit + 1)], on: ["a"])
        }
        let unchanged = session == before
        #expect(unchanged, "a refused list changes nothing")
        let expected = try cuts([10_000..<20_000])
        try session.rippleDelete([10_000..<20_000, 30_000..<30_000], on: ["a"])
        let skipped = session == expected
        #expect(skipped, "an empty range in the list is skipped")
    }
}

/// A run of continuous media: frames of one file at continuous timeline and file positions.
struct MediaSpan: Equatable {
    var file: FileID
    var start: Int
    var offset: Int
    var length: Int
}

extension [MediaSpan] {
    /// Appends `span`, or joins it to the last span when the timeline and the file run on.
    mutating func join(_ span: MediaSpan) {
        if let last, last.file == span.file, last.start + last.length == span.start,
            last.offset + last.length == span.offset
        {
            self[count - 1].length += span.length
        } else {
            append(span)
        }
    }
}

extension RippleTests {
    /// RR13. 100 random ranges of 1 to 800 frames, 10 touching pairs, and 10 empty ranges, in a
    /// random order, against a frame oracle that does not call `rippleDelete`. Each clip has its
    /// own file, so no crossfade forms. 40 % or more of the frames stay, so the oracle checks most
    /// frames.
    @Test mutating func manyRandomRangesMatchAFrameOracle() throws {
        var random = SplitMix(seed: 13)
        for file in ["p", "q", "r"] {
            try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 480_000))
        }
        try session.place(Clip(id: "P", file: "p", start: 0, offset: 1_000, length: 45_000), on: "a")
        try session.place(Clip(id: "Q", file: "q", start: 50_000, offset: 0, length: 50_000), on: "a")
        try session.place(Clip(id: "R", file: "r", start: 10_000, offset: 5_000, length: 85_000), on: "b")
        let markers = (0..<5).map { _ in Int.random(in: 0..<100_000, using: &random) }
        for (index, at) in markers.enumerated() { try marker(MarkerID("m\(index)"), at: Frames(at)) }
        func draw(from start: Int) -> Range<Frames> {
            Frames(start)..<Frames(start + Int.random(in: 1...800, using: &random))
        }
        var ranges = (0..<100).map { _ in draw(from: Int.random(in: 0..<100_000, using: &random)) }
        for _ in 0..<10 {
            let first = draw(from: Int.random(in: 0..<100_000, using: &random))
            ranges += [first, draw(from: first.upperBound.count)]
        }
        ranges += (0..<10).map { _ in
            let at = Frames(Int.random(in: 0..<100_000, using: &random))
            return at..<at
        }
        ranges.shuffle(using: &random)

        // The oracle: `before[t]` is the count of removed frames under t.
        let extent = ranges.map(\.upperBound.count).max()!
        var removed = [Bool](repeating: false, count: extent)
        for range in ranges { for frame in range.lowerBound.count..<range.upperBound.count { removed[frame] = true } }
        var before = [0]
        for frame in 0..<extent { before.append(before[frame] + (removed[frame] ? 1 : 0)) }
        #expect(100_000 - before[100_000] >= 40_000, "40 % or more of the frames stay")
        func expected(_ track: TrackID) -> [MediaSpan] {
            var spans: [MediaSpan] = []
            for clip in lane(track) {
                for frame in clip.start.count..<clip.end.count where !removed[frame] {
                    spans.join(
                        MediaSpan(
                            file: clip.file, start: frame - before[frame],
                            offset: clip.offset.count + frame - clip.start.count, length: 1))
                }
            }
            return spans
        }
        let oracle = (a: expected("a"), b: expected("b"))

        try session.rippleDelete(ranges, on: ["a", "b"])
        func spans(_ track: TrackID) -> [MediaSpan] {
            var spans: [MediaSpan] = []
            for clip in lane(track) {
                spans.join(
                    MediaSpan(
                        file: clip.file, start: clip.start.count, offset: clip.offset.count, length: clip.length.count))
            }
            return spans
        }
        let same = spans("a") == oracle.a && spans("b") == oracle.b
        #expect(same, "the clips equal the oracle spans: a \(oracle.a.count), b \(oracle.b.count)")
        #expect(
            markers.indices.map { position(MarkerID("m\($0)")) } == markers.map { Frames($0 - before[$0]) },
            "each marker moves left by the removed frames before it")
    }
}
