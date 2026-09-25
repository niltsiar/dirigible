import DirigibleCore
import Foundation
import Testing

/// Edit-commands criterion 3: every session that the edits make, the reader reads back. A seeded
/// sequence of `place`, `clear`, `paste`, `splitClips`, and `nudge` edits, then a write and a read.
struct EditRoundTripTests {
    @Test(arguments: [UInt64(1), 2, 3])
    func aSeededSequenceOfEditsReadsBack(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        var session = try editFixture()
        var done: [String: Int] = [:]
        func frame(_ range: ClosedRange<Int>) -> Frames { Frames(Int.random(in: range, using: &random)) }
        func range() -> Range<Frames> {
            let start = frame(0...300_000)
            return start..<(start + frame(1...60_000))
        }
        func tracks(_ layout: ChannelLayout) -> [TrackID] { layout == .mono ? ["a", "b"] : ["s"] }

        for step in 0..<400 {
            let kind = Int.random(in: 0..<6, using: &random)
            let before = session
            do {
                switch kind {
                case 0:
                    let layout: ChannelLayout = Bool.random(using: &random) ? .mono : .stereo
                    let length = frame(1...40_000)
                    let clip = Clip(
                        id: ClipID("p\(step)"), file: layout == .mono ? "f" : "g", start: frame(0...300_000),
                        offset: frame(0...100_000), length: length)
                    try session.place(clip, on: tracks(layout).randomElement(using: &random)!)
                    done["place", default: 0] += 1
                case 1:
                    try session.clear(range(), on: (["a", "b", "s"] as [TrackID]).randomElement(using: &random)!)
                    done["clear", default: 0] += 1
                case 2:
                    let source = (["a", "b", "s"] as [TrackID]).randomElement(using: &random)!
                    let layout = session.track(source)!.layout
                    let excerpt = try session.excerpt(of: range(), on: [source])
                    try session.paste(
                        excerpt, at: frame(0...300_000), on: [tracks(layout).randomElement(using: &random)!])
                    done["paste", default: 0] += 1
                case 3:
                    let sources: [TrackID] = Bool.random(using: &random) ? ["a", "b"] : ["a", "a"]
                    let excerpt = try session.excerpt(of: range(), on: sources)
                    try session.paste(excerpt, at: frame(0...300_000), on: ["b", "a"])
                    done["paste two lanes", default: 0] += 1
                case 4:
                    let frames = (0..<Int.random(in: 1...3, using: &random)).map { _ in frame(0...360_000) }
                    try session.splitClips(at: frames, on: ["a", "b", "s"].filter { _ in Bool.random(using: &random) })
                    done["splitClips", default: 0] += 1
                default:
                    let ids = session.tracks.flatMap { $0.clips.map(\.id) }.shuffled(using: &random).prefix(3)
                    try session.nudge(Array(ids), by: frame(-20_000...20_000))
                    done["nudge", default: 0] += 1
                }
            } catch {
                #expect(session == before, "a refused edit changes nothing: \(error)")
            }
        }

        #expect(done.keys.sorted() == ["clear", "nudge", "paste", "paste two lanes", "place", "splitClips"])
        #expect(session.tracks.allSatisfy { !$0.clips.isEmpty })
        let package = FileManager.default.temporaryDirectory
            .appending(path: "EditRoundTripTests-\(UUID().uuidString)/Episode.dirigible")
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try session.write(to: package)
        #expect(try Session(contentsOf: package) == session)
    }
}

/// SplitMix64, so each seed gives the same edits on each run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
