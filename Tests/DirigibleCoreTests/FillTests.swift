import Foundation
import Testing

@testable import DirigibleCore

/// Paste to Fill Selection (run replace-roomtone-split C10b, C13; decision 0053) on `editFixture`.
/// Clip "L" on "a" at 240 000..<288 000 is after the range of each literal case. The clipboard of
/// `ReplaceTests.clipboard` is clip "K" of file "f" from file frame 100 000.
struct FillTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "L", file: "f", start: 240_000, offset: 300_000, length: 48_000), on: "a")
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// C13: a clipboard longer than the range gives one copy, cut at the range end. The later clip
    /// does not move.
    @Test mutating func longClipboardCut() throws {
        let pasted = try session.fill(96_000..<144_000, with: try ReplaceTests.clipboard(72_000), on: ["a"])

        #expect(pasted == ["K@96000"])
        #expect(
            lane("a") == [
                Clip(id: "K@96000", file: "f", start: 96_000, offset: 100_000, length: 48_000),
                Clip(id: "L", file: "f", start: 240_000, offset: 300_000, length: 48_000),
            ])
    }

    /// C13: a shorter clipboard repeats with butt joins, and the last copy ends at the range end.
    @Test mutating func shortClipboardRepeats() throws {
        let pasted = try session.fill(96_000..<216_000, with: try ReplaceTests.clipboard(48_000), on: ["a"])

        #expect(pasted == ["K@96000", "K@144000", "K@192000"])
        #expect(
            lane("a") == [
                Clip(id: "K@96000", file: "f", start: 96_000, offset: 100_000, length: 48_000),
                Clip(id: "K@144000", file: "f", start: 144_000, offset: 100_000, length: 48_000),
                Clip(id: "K@192000", file: "f", start: 192_000, offset: 100_000, length: 24_000),
                Clip(id: "L", file: "f", start: 240_000, offset: 300_000, length: 48_000),
            ])
    }

    /// A clipboard of 100 frames: one clip, or two clips at 0..<40 and 50..<90.
    static func shortClipboard(clips: Int) throws -> Excerpt {
        var source = try editFixture()
        try source.place(Clip(id: "K", file: "f", start: 0, offset: 0, length: 40), on: "a")
        if clips == 2 { try source.place(Clip(id: "J", file: "f", start: 50, offset: 1_000, length: 40), on: "a") }
        return try source.excerpt(of: 0..<100, on: ["a"])
    }

    /// C13: the limit counts new clips, copies x the clips of the clipboard. 1 000 pass; 1 001 and
    /// 1 002 throw `.fillTooManyClips` with the count and change nothing.
    @Test(arguments: [(1, Frames(100_000), 1_000), (1, 100_100, 1_001), (2, 50_000, 1_000), (2, 50_100, 1_002)])
    mutating func clipLimit(clips: Int, length: Frames, needed: Int) throws {
        let clipboard = try Self.shortClipboard(clips: clips)
        let before = session
        if needed <= Session.fillClipLimit {
            let pasted = try session.fill(300_000..<(300_000 + length), with: clipboard, on: ["a"])
            #expect(pasted.count == needed)
        } else {
            #expect(throws: SessionError.fillTooManyClips(needed: needed)) {
                try session.fill(300_000..<(300_000 + length), with: clipboard, on: ["a"])
            }
            #expect(session == before)
        }
    }

    /// C13: a clipboard of length 0, a range or a clip set, throws `.emptyExcerpt` and changes
    /// nothing. The range form shows that the fill reaches the lane.
    @Test mutating func emptyClipboardRefused() throws {
        let before = session
        for clipboard in [try session.excerpt(of: 10..<10, on: ["a"]), try session.excerpt(of: [])] {
            #expect(throws: SessionError.emptyExcerpt) { try session.fill(0..<96_000, with: clipboard, on: ["a"]) }
            #expect(session == before)
        }
        try session.fill(0..<96_000, with: try ReplaceTests.clipboard(48_000), on: ["a"])
        #expect(lane("a").count == 3)
    }

    /// 0053: each join between two copies is a butt join. Clip "K" has a 960-frame crossfade at
    /// each edge, so a copy of "K" alone, as a clip set or as the range of "K", would pair with the
    /// next copy. Three copies have no crossfade.
    @Test mutating func joinsHaveNoCrossfade() throws {
        var source = try editFixture()
        try source.place(Clip(id: "P", file: "f", start: 0, offset: 0, length: 10_000), on: "a")
        try source.place(Clip(id: "K", file: "f", start: 10_000, offset: 100_000, length: 20_000), on: "a")
        try source.place(Clip(id: "Q", file: "f", start: 30_000, offset: 200_000, length: 10_000), on: "a")
        try source.setCrossfades(["P": 960, "K": 960])
        let before = session
        for clipboard in [try source.excerpt(of: ["K"]), try source.excerpt(of: 10_000..<30_000, on: ["a"])] {
            #expect(clipboard.lanes.map { $0.clips.map(\.crossfades) } == [[Crossfades(valid: 960, end: 960)]])
            session = before

            try session.fill(0..<60_000, with: clipboard, on: ["a"])

            #expect(lane("a").map(\.start) == [0, 20_000, 40_000, 240_000])
            #expect(lane("a").map(\.crossfades) == Array(repeating: Crossfades.zero, count: 4), "\(clipboard.kind)")
        }
    }

    /// C13: a clip-set clipboard fills as a block of its length; its gaps stay silent, so the fill
    /// clears clip "L" and clip "X" under a gap. Lane "b" holds its clip 60 000 frames into each
    /// copy, and the third copy of it starts after the range end.
    @Test mutating func clipSetBlock() throws {
        var source = try editFixture()
        try source.place(Clip(id: "P", file: "f", start: 0, offset: 0, length: 40_000), on: "a")
        try source.place(Clip(id: "Q", file: "f", start: 60_000, offset: 50_000, length: 40_000), on: "b")
        let clipboard = try source.excerpt(of: ["P", "Q"])
        try session.place(Clip(id: "X", file: "f", start: 420_000, offset: 0, length: 10_000), on: "b")

        try session.fill(200_000..<450_000, with: clipboard, on: ["a", "b"])

        #expect(
            lane("a") == [
                Clip(id: "P@200000", file: "f", start: 200_000, offset: 0, length: 40_000),
                Clip(id: "P@300000", file: "f", start: 300_000, offset: 0, length: 40_000),
                Clip(id: "P@400000", file: "f", start: 400_000, offset: 0, length: 40_000),
            ])
        #expect(
            lane("b") == [
                Clip(id: "Q@260000", file: "f", start: 260_000, offset: 50_000, length: 40_000),
                Clip(id: "Q@360000", file: "f", start: 360_000, offset: 50_000, length: 40_000),
            ])
    }

    /// C10b, C13, 0053: a seeded fill equals its paste loop on a copy: a clear of the range on each
    /// target, a paste of each whole copy at its start, then a paste of the last copy cut at the
    /// range end. Each pasted copy has no crossfade at its edges, so each join is a butt join. Most
    /// clips touch the clip before them with one crossfade length of the seed. It compares every
    /// clip of the targets without the IDs: file, start, offset, length, gain, fades, crossfades,
    /// and envelope.
    @Test(arguments: Array(UInt64(1)...16))
    func fillEqualsAPasteLoop(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &random) }
        var session = try editFixture()
        var ids: [[ClipID]] = []
        var crossfades: [ClipID: Frames] = [:]
        let crossfade = Frames(2 * int(10...400))
        for track in ["a", "b"] as [TrackID] {
            var cursor = int(0...20_000)
            var touching: ClipID?
            var lane: [ClipID] = []
            for _ in 0..<int(3...6) {
                let length = int(2_000...30_000)
                let id = ClipID("\(track)\(lane.count)")
                let points = (0..<int(0...3)).map { _ in (int(0...480_000), Double(int(-12...6))) }
                if let touching { crossfades[touching] = crossfade }
                try session.place(
                    Clip(
                        id: id, file: "f", start: Frames(cursor), offset: Frames(int(1_000...(479_000 - length))),
                        length: Frames(length), gain: Gain(dB: Double(int(-12...6)))!,
                        fades: Fades(fadeIn: Frames(int(0...length / 4)), fadeOut: Frames(int(0...length / 4)))!,
                        envelope: envelope(
                            Dictionary(points, uniquingKeysWith: { a, _ in a }).sorted { $0.key < $1.key }
                                .map { ($0.key, $0.value) })),
                    on: track)
                lane.append(id)
                let gap = int(0...3) == 0 ? int(1...10_000) : 0
                touching = gap == 0 ? id : nil
                cursor += length + gap
            }
            ids.append(lane)
        }
        try session.setCrossfades(crossfades)
        let clipboard: Excerpt
        if Bool.random(using: &random) {
            let start = Frames(int(0...100_000))
            clipboard = try session.excerpt(of: start..<(start + Frames(int(5_000...60_000))), on: ["a", "b"])
        } else {
            // A run of 1 to 3 clips inside track "a", so a crossfade can be at each run edge, and
            // maybe a run of track "b".
            var chosen: [ClipID] = []
            for (track, lane) in ids.enumerated() where track == 0 || Bool.random(using: &random) {
                let inner = track == 0
                let first = inner ? int(1...(lane.count - 2)) : int(0...(lane.count - 1))
                chosen += lane[first..<min(inner ? lane.count - 1 : lane.count, first + int(1...3))]
            }
            clipboard = try session.excerpt(of: chosen)
        }
        let targets = Array((["a", "b"] as [TrackID]).prefix(clipboard.lanes.count))
        let low = Frames(int(0...200_000))
        let range = low..<(low + Frames(int(1...(clipboard.length.count * 8))))

        var copy = clipboard
        for lane in copy.lanes.indices {
            for (index, clip) in copy.lanes[lane].clips.enumerated() {
                copy.lanes[lane].clips[index].crossfades = Crossfades(
                    valid: clip.start == .zero ? .zero : clip.crossfades.start,
                    end: clip.end == clipboard.length ? .zero : clip.crossfades.end)
            }
        }
        var reference = session
        for target in targets { try reference.clear(range, on: [target]) }
        var at = range.lowerBound
        while at < range.upperBound {
            if at + clipboard.length <= range.upperBound {
                try reference.paste(copy, at: at, on: targets)
            } else {
                var scratch = reference
                try scratch.paste(copy, at: at, on: targets)
                try reference.paste(try scratch.excerpt(of: at..<range.upperBound, on: targets), at: at, on: targets)
            }
            at = at + clipboard.length
        }
        try session.fill(range, with: clipboard, on: targets)

        func shapes(_ session: Session) -> [[Clip]] {
            targets.map { target in
                (session.track(target).map { Array($0.clips) } ?? []).map {
                    Clip(
                        id: "x", file: $0.file, start: $0.start, offset: $0.offset, length: $0.length, gain: $0.gain,
                        fades: $0.fades, crossfades: $0.crossfades, envelope: $0.envelope)
                }
            }
        }
        let (got, want) = (shapes(session), shapes(reference))
        let same = got == want
        let counts = "\(got.map(\.count)) clips, want \(want.map(\.count))"
        #expect(same, "seed \(seed), range \(range), \(clipboard.kind) clipboard of \(clipboard.length): \(counts)")
    }

    /// C10b: the fill checks its clips as a paste does. A clipboard clip whose file record differs
    /// from the record of its ID here throws `.foreignFile` and changes nothing. A clipboard of
    /// another package with words adds each source transcript once, not once for each copy.
    @Test mutating func fillChecksLikePaste() throws {
        var other = Session(sampleRate: 48_000)
        try other.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 400_000))
        try other.addTrack("a", name: "A", layout: .mono)
        try other.place(Clip(id: "K", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        let foreign = try other.excerpt(of: 0..<48_000, on: ["a"])
        let before = session
        #expect(throws: SessionError.foreignFile("f")) {
            try session.fill(0..<144_000, with: foreign, on: ["a"])
        }
        #expect(session == before)

        let words = TranscriptPasteTests()
        var target = try words.target()
        let record = try #require(target.files["h2"])
        let clipboard = try words.source().excerpt(of: 0..<96_000, on: ["host"]).mapped(to: ["h": record])

        try target.fill(0..<288_000, with: clipboard, on: ["t"])

        #expect(target.track("t")?.clips.count == 3)
        #expect(target.transcripts.count == 1, "\(target.transcripts.keys)")
        #expect(target.transcripts.values.first?.words?.keys.contains("h2") == true)
    }
}
