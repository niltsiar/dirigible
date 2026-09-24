import Foundation
import Testing

@testable import DirigibleAudio

struct SidecarTests {
    static let header = CaptureHeader(
        deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000,
        availableRates: [44_100...44_100, 48_000...48_000], channelCount: 1, latency: 48,
        firstSampleTime: 512, firstHostTimeNanos: 1_000_000_000)

    /// One checkpoint each second, 5 in total.
    static let checkpoints = (0..<5).map {
        Checkpoint(
            fileFrame: Int64($0) * 48_000, sampleTime: 512 + Double($0) * 48_000,
            hostTimeNanos: 1_000_000_000 + UInt64($0) * 1_000_000_000)
    }

    /// The size of one checkpoint record: length, kind, 24 payload bytes, hash.
    static let checkpointRecord = 4 + 1 + 24 + 4

    static func bytes(_ header: CaptureHeader = header, _ checkpoints: [Checkpoint] = checkpoints) -> Data {
        checkpoints.reduce(Sidecar.encode(header)) { $0 + Sidecar.encode($1) }
    }

    @Test func aHeaderAndFiveCheckpointsReadBackEqual() throws {
        let sidecar = try #require(Sidecar.decode(Self.bytes()))
        #expect(sidecar == Sidecar(header: Self.header, checkpoints: Self.checkpoints))
        #expect(Sidecar.decode(Sidecar.encode(Self.header)) == Sidecar(header: Self.header, checkpoints: []))
    }

    @Test func aCutInsideTheLastRecordDropsOnlyThatRecord() throws {
        let full = Self.bytes()
        for length in (full.count - Self.checkpointRecord)..<full.count {
            let sidecar = try #require(Sidecar.decode(full.prefix(length)), "cut at \(length)")
            #expect(sidecar.checkpoints == Array(Self.checkpoints.prefix(4)), "cut at \(length)")
        }
    }

    @Test func aTailOfZerosInPlaceOfTheLastRecordIsDropped() throws {
        let data = Self.bytes().dropLast(Self.checkpointRecord) + Data(count: 64)
        #expect(try #require(Sidecar.decode(data)).checkpoints == Array(Self.checkpoints.prefix(4)))
    }

    @Test(arguments: ["XXXXXXXX", "DRGSIDE2"])
    func aBadMagicIsRefused(magic: String) {
        var data = Self.bytes()
        data.replaceSubrange(0..<8, with: Data(magic.utf8))
        #expect(Sidecar.decode(data) == nil)
    }

    @Test func aShortHeaderIsRefused() {
        let header = Sidecar.encode(Self.header)
        for length in 0..<header.count {
            #expect(Sidecar.decode(header.prefix(length)) == nil, "cut at \(length)")
        }
    }

    @Test func aHeaderWithABadHashIsRefused() {
        var data = Self.bytes()
        data[8 + 5] ^= 0x01  // the first payload byte of the header record
        #expect(Sidecar.decode(data) == nil)
    }

    static let badHeaders: [CaptureHeader] = {
        let good = header
        var headers: [CaptureHeader] = []
        func with(_ change: (inout CaptureHeader) -> Void) {
            var bad = good
            change(&bad)
            headers.append(bad)
        }
        with { $0.nominalRate = 0 }
        with { $0.nominalRate = .nan }
        with { $0.nominalRate = .infinity }
        with { $0.nominalRate = 0.4 }
        with { $0.availableRates = [48_000...48_000, 44_100...44_100, 0...48_000] }
        with { $0.availableRates = [(-Double.infinity)...48_000] }
        with { $0.availableRates = [48_000...Double.infinity] }
        with { $0.channelCount = 3 }
        with { $0.channelCount = 0 }
        with { $0.latency = -1 }
        with { $0.firstSampleTime = .nan }
        with { $0.deviceName = "A\u{01}B" }
        with { $0.deviceName = "A\u{FFFE}B" }
        with { $0.deviceUID = "usb\u{FFFE}1" }
        return headers
    }()

    @Test(arguments: badHeaders)
    func aHeaderWithABadValueIsRefused(header: CaptureHeader) {
        #expect(Sidecar.decode(Self.bytes(header)) == nil)
    }

    /// A range with min > max cannot be built as a `ClosedRange`, so the test writes its bytes.
    @Test func aRangeWithMinAboveMaxIsRefused() throws {
        var data = Sidecar.encode(Self.header)
        let min = withUnsafeBytes(of: Double(48_000).bitPattern.littleEndian) { Data($0) }
        let max = withUnsafeBytes(of: Double(44_100).bitPattern.littleEndian) { Data($0) }
        let lastRange = data.count - 4 - 16
        data.replaceSubrange(lastRange..<(lastRange + 16), with: min + max)
        // Fix the hash, so that only the range is wrong.
        let payload = data[(8 + 4)..<(data.count - 4)]
        data.replaceSubrange(
            (data.count - 4)..<data.count, with: withUnsafeBytes(of: fnv1a(payload).littleEndian) { Data($0) })
        #expect(Sidecar.decode(data) == nil)
        #expect(Sidecar.decode(Sidecar.encode(Self.header)) != nil)
    }

    @Test func aCheckpointThatIsNotFiniteDropsItAndTheRest() throws {
        var checkpoints = Self.checkpoints
        checkpoints[2].sampleTime = .nan
        #expect(
            try #require(Sidecar.decode(Self.bytes(Self.header, checkpoints))).checkpoints
                == Array(checkpoints.prefix(2)))
    }

    @Test func aCheckpointThatGoesBackDropsItAndTheRest() throws {
        var lowerFrame = Self.checkpoints
        lowerFrame[3].fileFrame = lowerFrame[2].fileFrame - 1
        #expect(
            try #require(Sidecar.decode(Self.bytes(Self.header, lowerFrame))).checkpoints == Array(lowerFrame.prefix(3))
        )
        var lowerHost = Self.checkpoints
        lowerHost[3].hostTimeNanos = lowerHost[2].hostTimeNanos - 1
        #expect(
            try #require(Sidecar.decode(Self.bytes(Self.header, lowerHost))).checkpoints == Array(lowerHost.prefix(3)))
    }

    @Test func aCheckpointWithABadHashDropsItAndTheRest() throws {
        var data = Self.bytes()
        let third = Sidecar.encode(Self.header).count + 2 * Self.checkpointRecord
        data[third + 5] ^= 0x01
        #expect(try #require(Sidecar.decode(data)).checkpoints == Array(Self.checkpoints.prefix(2)))
    }

    @Test func randomSidecarsReadBackEqual() throws {
        var random = SeededGenerator(seed: 0x51DE_CA12)
        let letters: [Character] = ["a", "Z", "0", " ", "-", "é", "ß", "語", "🎙", "\u{FFFD}"]
        func text() -> String {
            String((0..<Int.random(in: 0...12, using: &random)).map { _ in letters.randomElement(using: &random)! })
        }
        func rate() -> Double { Double.random(in: 1...400_000, using: &random) }

        for _ in 0..<200 {
            let ranges = (0..<Int.random(in: 0...4, using: &random)).map { _ in
                let low = rate()
                return low...(low + Double.random(in: 0...1000, using: &random))
            }
            let header = CaptureHeader(
                deviceUID: text(), deviceName: text(), nominalRate: rate(), availableRates: ranges,
                channelCount: Int.random(in: 1...2, using: &random),
                latency: Int.random(in: 0...100_000, using: &random),
                firstSampleTime: Double.random(in: -1e12...1e12, using: &random),
                firstHostTimeNanos: UInt64.random(in: 0...UInt64.max, using: &random))
            var frame = Int64.random(in: 0...1_000_000, using: &random)
            var host = UInt64.random(in: 0...(UInt64.max / 2), using: &random)
            let checkpoints = (0..<Int.random(in: 0...20, using: &random)).map { _ in
                frame += Int64.random(in: 0...96_000, using: &random)
                host += UInt64.random(in: 0...2_000_000_000, using: &random)
                return Checkpoint(
                    fileFrame: frame, sampleTime: Double.random(in: -1e12...1e12, using: &random), hostTimeNanos: host)
            }
            #expect(
                Sidecar.decode(Self.bytes(header, checkpoints)) == Sidecar(header: header, checkpoints: checkpoints))
        }
    }
}
