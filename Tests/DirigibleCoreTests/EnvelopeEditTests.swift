import Foundation
import Testing

@testable import DirigibleCore

/// The edits keep the gain envelope and the ride layer (decision 0060). Track "t1"
/// (mono); files "fa" and "fb" of 60 000 frames.
struct EnvelopeEditTests {
    static let fileLength = 60_000

    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        for id in ["fa", "fb"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: Frames(fileLength)))
        }
        try session.addTrack("t1", name: "Host", layout: .mono)
        return session
    }

    /// After each seeded edit, each file frame that plays before and after the edit at one
    /// place has the same layer gain (envelope plus ride). A clip after the edit compares with its source before it:
    /// the clip of the same ID, else of its ID up to the last "@" (split, clear, paste), and for a
    /// heal each clip of the same file map inside it. Points lie inside and outside each clip window.
    /// Control: a trim that drops the points outside the new window fails here.
    @Test(arguments: [UInt64(1), 2, 3])
    func everyEditKeepsTheGainAtEachKeptFileFrame(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        var session = try Self.session()
        func frame(_ range: ClosedRange<Int>) -> Frames { Frames(Int.random(in: range, using: &random)) }
        func randomEnvelope() -> GainEnvelope {
            let frames = Set(
                (0..<Int.random(in: 0...4, using: &random)).map { _ in
                    Int.random(in: 0...Self.fileLength, using: &random)
                }
            ).sorted()
            return envelope(frames.map { ($0, [-20, -12, -6, 0, 3, 6].randomElement(using: &random)!) })
        }
        for index in 0..<4 {
            let file: FileID = index == 2 ? "fb" : "fa"
            try session.place(
                Clip(
                    id: ClipID("c\(index)"), file: file, start: Frames(index * 5_000),
                    offset: Frames(10_000 + index * 5_000), length: 5_000, envelope: randomEnvelope(),
                    ride: randomEnvelope()),
                on: "t1")
        }
        var done: [String: Int] = [:]
        var (compared, outside, wrong) = (0, 0, [String]())
        for step in 0..<400 {
            let before = session
            let lane = session.tracks[0].clips
            func anyClip() -> Clip? { lane.randomElement(using: &random) }
            let kind = Int.random(in: 0..<13, using: &random)
            let name: String
            do {
                switch kind {
                case 0:
                    name = "place"
                    try session.place(
                        Clip(
                            id: ClipID("p\(step)"), file: Bool.random(using: &random) ? "fa" : "fb",
                            start: frame(0...30_000), offset: frame(0...40_000), length: frame(1...8_000),
                            envelope: randomEnvelope(), ride: randomEnvelope()),
                        on: "t1")
                case 1:
                    name = "clear"
                    let start = frame(0...30_000)
                    try session.clear(start..<(start + frame(1...3_000)), on: ["t1"])
                case 2:
                    name = "paste"
                    let start = frame(0...30_000)
                    let excerpt = try session.excerpt(of: start..<(start + frame(1...8_000)), on: ["t1"])
                    try session.paste(excerpt, at: frame(0...30_000), on: ["t1"])
                case 3:
                    name = "split"
                    try session.splitClips(at: [frame(0...35_000), frame(0...35_000)], on: ["t1"])
                case 4:
                    name = "move"
                    guard let clip = anyClip() else { continue }
                    try session.move(clip.id, to: "t1", start: frame(0...30_000))
                case 5:
                    name = "trim"
                    guard let clip = anyClip() else { continue }
                    let low = clip.start + frame(-2_000...2_000)
                    try session.trim(clip.id, to: low..<max(low, clip.end + frame(-2_000...2_000)))
                case 6:
                    name = "rippleTrim"
                    guard let clip = anyClip() else { continue }
                    let edge: Fades.Edge = Bool.random(using: &random) ? .start : .end
                    try session.rippleTrim(clip.id, edge: edge, by: frame(-2_000...2_000), on: ["t1"], naming: [])
                case 7:
                    name = "rippleDelete"
                    let start = frame(0...30_000)
                    try session.rippleDelete(start..<(start + frame(1...4_000)), on: ["t1"], naming: [])
                case 8:
                    name = "rippleInsert"
                    try session.rippleInsert(frame(1...4_000), at: frame(0...30_000), on: ["t1"], naming: [])
                case 9:
                    name = "crossfade"
                    var lengths: [ClipID: Frames] = [:]
                    for index in lane.indices where Bool.random(using: &random) {
                        guard let limit = session.crossfadeLimit(after: index, in: lane), limit > .zero else {
                            continue
                        }
                        lengths[lane[index].id] = Frames(
                            min(limit.count, Int.random(in: 2...2_000, using: &random)) / 2 * 2)
                    }
                    guard !lengths.isEmpty else { continue }
                    try session.setCrossfades(lengths)
                case 10:
                    name = "replace"
                    let start = frame(0...30_000)
                    let excerpt = try session.excerpt(of: start..<(start + frame(1...8_000)), on: ["t1"])
                    let at = frame(0...30_000)
                    try session.replace(at..<(at + frame(1...4_000)), with: excerpt, on: ["t1"])
                case 11:
                    name = "fill"
                    let start = frame(0...30_000)
                    let excerpt = try session.excerpt(of: start..<(start + frame(1_000...8_000)), on: ["t1"])
                    let at = frame(0...30_000)
                    try session.fill(at..<(at + frame(1...20_000)), with: excerpt, on: ["t1"])
                default:
                    name = "heal"
                    try session.heal()
                }
            } catch {
                #expect(session == before, "seed \(seed) step \(step): a refused edit changes nothing: \(error)")
                continue
            }
            done[name, default: 0] += 1
            let result = Self.compare(before.tracks[0].clips, session.tracks[0].clips, heal: name == "heal") {
                Int.random(in: $0, using: &random)
            }
            compared += result.compared
            outside += result.outside
            wrong += result.wrong.map { "seed \(seed) step \(step) \(name): \($0)" }
        }
        #expect(wrong.isEmpty, "\(wrong.count) wrong gains, first: \(wrong.prefix(3))")
        #expect(done.keys.count == 13, "each kind of edit ran: \(done)")
        #expect((done["heal"] ?? 0) >= 10, "heals: \(done["heal"] ?? 0)")
        #expect(compared >= 5_000 && outside >= 500, "\(compared) frames compared, \(outside) with a point outside")
    }

    /// The frames that `after` and `before` both play at one place, with a different layer gain.
    /// `outside` counts the compared clips that have an envelope or ride point outside their window.
    static func compare(
        _ before: ClipLane, _ after: ClipLane, heal: Bool, random: (ClosedRange<Int>) -> Int
    ) -> (compared: Int, outside: Int, wrong: [String]) {
        var (compared, outside, wrong) = (0, 0, [String]())
        let old = before.indices.map { before.sounding(at: $0).clip }
        for index in after.indices {
            let new = after.sounding(at: index).clip
            let sources: [Clip]
            if heal {
                sources = old.filter {
                    $0.file == new.file && $0.start - $0.offset == new.start - new.offset
                        && new.start <= $0.start && $0.end <= new.end
                }
            } else {
                let raw = new.id.rawValue
                let id =
                    old.contains { $0.id == new.id }
                    ? new.id : raw.lastIndex(of: "@").map { ClipID(String(raw[..<$0])) }
                sources = old.filter { $0.id == id && $0.file == new.file }
            }
            for source in sources {
                let low = max(source.offset, new.offset)
                let high = min(source.offset + source.length, new.offset + new.length) - Frames(1)
                guard low <= high else { continue }
                let window = source.offset..<(source.offset + source.length)
                let points = source.envelope.points + source.ride.points
                if points.contains(where: { !window.contains($0.frame) }) { outside += 1 }
                let marks = (points + new.envelope.points + new.ride.points).flatMap { point in
                    [point.frame - Frames(1), point.frame, point.frame + Frames(1)]
                }
                let picks = (0..<3).map { _ in Frames(random(low.count...high.count)) }
                for frame in ([low, high] + marks + picks) where low <= frame && frame <= high {
                    compared += 1
                    let (was, now) = (source.layerGain(at: frame), new.layerGain(at: frame))
                    if abs(was - now) > 1e-9 { wrong.append("\(new.id) at file frame \(frame): \(was) then \(now)") }
                }
            }
        }
        return (compared, outside, wrong)
    }

    /// C2: a trim keeps every point, so a trim and an extend back give the clip and its gains again.
    /// Control: a trim that drops the points outside the new window loses (5 000, -6) and (35 000, 3).
    @Test func aTrimAndAnExtendGiveBackTheGain() throws {
        var session = try Self.session()
        let points = envelope([(5_000, -6), (15_000, 0), (25_000, -12), (35_000, 3)])
        let clip = Clip(id: "A", file: "fa", start: 0, offset: 10_000, length: 20_000, envelope: points)
        try session.place(clip, on: "t1")

        try session.trim("A", to: 5_000..<15_000)
        let trimmed = try #require(session.clip("A")?.clip)
        #expect(trimmed.offset == 15_000 && trimmed.envelope == points, "the trim keeps the list")
        #expect(trimmed.envelope.gain(at: 20_000) == -6, "file frame 20 000 is still -6 dB")

        try session.trim("A", to: 0..<20_000)
        #expect(session.clip("A")?.clip == clip, "the extend gives the clip back")
        #expect(session.clip("A")?.clip.envelope.gain(at: 10_000) == -3, "file frame 10 000")
    }

    /// C2: a split gives both parts the list of the clip and adds no point, so a clip with no point
    /// gives two parts with no point and keeps the file version (0024 P6). The clip with points
    /// shows that the split reaches the list.
    @Test func aSplitOfAClipWithNoPointKeepsTheFileVersion() throws {
        var session = try Self.session()
        try session.place(Clip(id: "A", file: "fa", start: 0, offset: 0, length: 20_000), on: "t1")
        let points = envelope([(30_000, -6), (50_000, 0)])
        try session.place(
            Clip(id: "B", file: "fb", start: 20_000, offset: 20_000, length: 20_000, envelope: points), on: "t1")
        let version = session.fileVersion

        try session.splitClips(at: [10_000, 30_000], on: ["t1"])

        let lane = try #require(session.track("t1")).clips
        #expect(lane.map(\.id) == ["A", "A@10000", "B", "B@30000"])
        #expect(lane.map(\.envelope) == [.empty, .empty, points, points])
        #expect(session.fileVersion == version && version == 10)
        try session.removeClips(["B", "B@30000"])
        #expect(session.fileVersion == 1, "the parts of A have no point")
    }

    /// `Session.check` refuses a point after the end of the file; a point at the end is valid.
    @Test func aPointAfterTheFileEndIsRefused() throws {
        var session = try Self.session()
        let atEnd = Clip(id: "A", file: "fa", start: 0, offset: 0, length: 1_000, envelope: envelope([(60_000, -6)]))
        try session.place(atEnd, on: "t1")
        let before = session
        let late = Clip(id: "B", file: "fa", start: 2_000, offset: 0, length: 1_000, envelope: envelope([(60_001, -6)]))
        #expect(throws: SessionError.clipOutsideFile("B")) { try session.place(late, on: "t1") }
        #expect(session == before)
    }
}
