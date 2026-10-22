import DirigibleCore
import Testing

@testable import DirigibleAudio

struct SegmentNameTests {
    @Test func aCanonicalFileNameParses() {
        #expect(SegmentName(fileName: "take10-2-3.wav") == SegmentName(take: 10, arm: 2, segment: 3))
        #expect(SegmentName(fileName: "take1-1-1.caf") == SegmentName(take: 1, arm: 1, segment: 1))
        #expect(SegmentName(fileName: "take999999999-1-1.sidecar")?.take == 999_999_999)
    }

    @Test(arguments: [
        "take-1-1.caf", "take1-1.caf", "take1-1-1.aif", "take01x-1-1.caf", "take01-1-1.caf",
        "take1234567890-1-1.caf", "take1-01-1.caf", "take1-1-0.caf", "notes.txt", "xtake1-1-1.caf",
    ])
    func otherFileNamesDoNotParse(name: String) {
        #expect(SegmentName(fileName: name) == nil)
    }

    @Test func theStemIsTheOnlyNameMaker() {
        #expect(SegmentName(take: 3, arm: 1, segment: 2).stem == "take3-1-2")
        #expect(SegmentName(fileName: "take3-1-2.caf")?.stem == "take3-1-2")
    }

    @Test func anIDParsesThePartBeforeTheFirstAt() {
        #expect(SegmentName(id: "take3-1-1") == SegmentName(take: 3, arm: 1, segment: 1))
        #expect(SegmentName(id: "take3-1-1@48000") == SegmentName(take: 3, arm: 1, segment: 1))
        #expect(SegmentName(id: "take3-1-1@48000@96000-2") == SegmentName(take: 3, arm: 1, segment: 1))
        #expect(SegmentName(id: "take3-1-1x") == nil)
        #expect(SegmentName(id: "take01-1-1") == nil)
        #expect(SegmentName(id: "take3-1-1.caf") == nil)
    }

    @Test func namesSortByTakeArmAndSegment() {
        let names = ["take2-1-1", "take1-2-1", "take1-1-2", "take10-1-1", "take1-1-1"].compactMap(SegmentName.init(id:))
        #expect(names.sorted().map(\.stem) == ["take1-1-1", "take1-1-2", "take1-2-1", "take2-1-1", "take10-1-1"])
    }

    @Test func nanosIsASignedDifference() {
        #expect(nanos(from: 1_000_000_000, to: 1_010_000_000) == 10_000_000)
        #expect(nanos(from: 1_000_000_000, to: 995_000_000) == -5_000_000)
        #expect(nanos(from: UInt64.max, to: 1) == 2)
    }
}
