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
        // The clips and the markers end at or before 100 000; a range can end after it.
        let extent = max(100_000, ranges.map(\.upperBound.count).max() ?? 0)
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

extension RippleTests {
    /// S1b (C32). Seeded property: one ripple delete of a range set equals `perRangeRipple`. The
    /// ranges are sorted, some touch, a third of them are one whole clip, and a third of the other
    /// bounds snap to a clip edge, so a cut meets a crossfade at both of its bounds. Control: a
    /// repair only after the shift keeps an end crossfade at a range start that meets a start
    /// crossfade of the same length.
    @Test(arguments: [1, 2, 3] as [UInt64])
    func oneRippleOfManyRangesEqualsTheCutsFromTheLast(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        var reached = 0
        for step in 0..<40 {
            var start = try seededLanes(&random)
            let edges = start.tracks.flatMap { $0.clips.flatMap { [$0.start, $0.end] } }.sorted()
            func frame(from cursor: Frames) -> Frames {
                if Int.random(in: 0..<3, using: &random) == 0, let edge = edges.first(where: { $0 >= cursor }) {
                    return edge
                }
                return cursor + Frames(Int.random(in: 0...20_000, using: &random))
            }
            var ranges: [Range<Frames>] = []
            var cursor = Frames(Int.random(in: 0...20_000, using: &random))
            for _ in 0..<Int.random(in: 1...12, using: &random) {
                let lane = start.tracks.randomElement(using: &random)!.clips
                if Int.random(in: 0..<3, using: &random) == 0, let clip = lane.first(where: { $0.start >= cursor }) {
                    ranges.append(clip.range)
                } else {
                    let lower = frame(from: cursor)
                    ranges.append(lower..<frame(from: lower + Frames(1)))
                }
                let upper = ranges[ranges.count - 1].upperBound
                let gap = Bool.random(using: &random) ? 0 : Int.random(in: 1...30_000, using: &random)
                cursor = upper + Frames(gap)
            }
            let first = ranges[0]
            let inside = first.lowerBound + Frames((first.upperBound - first.lowerBound).count / 2)
            for (n, at) in [first.lowerBound, first.upperBound, inside, ranges[ranges.count - 1].upperBound]
                .enumerated()
            {
                try start.setMarker(Marker(id: MarkerID("e\(n)"), name: "E", position: at, kind: .marker))
            }
            let tracks = start.tracks.map(\.id)
            let scope = tracks.filter { _ in Bool.random(using: &random) } + [tracks.randomElement(using: &random)!]
            let crossfadesAtBothBounds = start.tracks.filter { scope.contains($0.id) }.contains { track in
                Session.merged(ranges).contains { range in
                    track.clips.contains { $0.end == range.lowerBound && $0.crossfades.end != .zero }
                        && track.clips.contains { $0.start == range.upperBound && $0.crossfades.start != .zero }
                }
            }
            if crossfadesAtBothBounds { reached += 1 }
            let oracle = try perRangeRipple(start, ranges, on: scope)
            var edited = start
            try edited.rippleDelete(ranges.shuffled(using: &random), on: scope)
            let same = edited == oracle
            #expect(same, "seed \(seed) case \(step): \(ranges) on \(scope)")
            if !same { break }
        }
        #expect(reached >= 5, "seed \(seed): \(reached) of 40 cases have a crossfade at both bounds of a range")
    }

    /// The oracle: the ripple delete before its one pass. For each merged range, from the last to
    /// the first, one clear and one shift of each lane, then the markers of the range.
    func perRangeRipple(_ session: Session, _ ranges: [Range<Frames>], on scope: [TrackID]) throws -> Session {
        var copy = session
        var taken = session.clipIDs
        let lanes = try session.trackIndices(scope)
        for range in Session.merged(ranges).reversed() {
            let length = range.upperBound - range.lowerBound
            for index in lanes {
                copy.tracks[index].clips.clear([range]) { Session.derivedID(of: $0.id, at: $1, taken: &taken) }
                copy.tracks[index].clips.shift(from: range.upperBound, by: .zero - length)
            }
            for marker in copy.markers.values where marker.position > range.lowerBound {
                var moved = marker
                moved.position = max(range.lowerBound, marker.position - length)
                try copy.setMarker(moved)
            }
        }
        return copy
    }

    /// The tracks of `editFixture` with random clips up to 400 000. Most clips touch the clip
    /// before them at a butt join (a random file offset) with a crossfade of 960 or 1 920 frames,
    /// some have fades, track "a" has a gain change, and three markers sit at random frames.
    func seededLanes(_ random: inout SplitMix) throws -> Session {
        var session = try editFixture()
        for (track, file) in [("a", "f"), ("b", "f"), ("s", "g")] {
            var at = Int.random(in: 0...10_000, using: &random)
            var (previous, n): (ClipID?, Int) = (nil, 0)
            while at < 400_000 {
                let length = Int.random(in: 4_000...40_000, using: &random)
                let id = ClipID("\(track)\(n)")
                let offset = Int.random(in: 2_000...(478_000 - length), using: &random)
                try session.place(
                    Clip(id: id, file: FileID(file), start: Frames(at), offset: Frames(offset), length: Frames(length)),
                    on: TrackID(track))
                if let previous {
                    _ = try? session.setCrossfades([previous: Frames([960, 1_920].randomElement(using: &random)!)])
                }
                if Int.random(in: 0..<3, using: &random) == 0 {
                    let fades = Fades(
                        fadeIn: Frames(Int.random(in: 0...3_000, using: &random)),
                        fadeOut: Frames(Int.random(in: 0...3_000, using: &random)))!
                    _ = try? session.setFades([id: fades])
                }
                let touching = Int.random(in: 0..<5, using: &random) < 3
                previous = touching ? id : nil
                at += length + (touching ? 0 : Int.random(in: 1...20_000, using: &random))
                n += 1
            }
        }
        let gain = Int.random(in: 0..<380_000, using: &random)
        _ = try session.changeGain(
            by: Gain(dB: -6)!, in: Frames(gain)..<Frames(gain + 20_000), on: ["a"], ramp: 480)
        for n in 0..<3 {
            let at = Frames(Int.random(in: 0..<440_000, using: &random))
            try session.setMarker(Marker(id: MarkerID("r\(n)"), name: "R", position: at, kind: .marker))
        }
        return session
    }
}
