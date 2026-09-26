import DirigibleCore
import Foundation

/// The folder of the raw segments in a package (decision 0012).
package let captureFolderName = "Capture"

/// The name of one segment of a take: `take<take>-<arm>-<segment>` (decision 0012). `arm` is the
/// 1-based index of the track in `Recording.armedTracks`; `segment` counts from 1 for each
/// device. Each part has 1 to 9 digits and no leading zero, so a name has one spelling.
public struct SegmentName: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let take: Int
    public let arm: Int
    public let segment: Int

    init(take: Int, arm: Int, segment: Int) {
        precondition(
            [take, arm, segment].allSatisfy { (1...999_999_999).contains($0) }, "A stem part has 1 to 9 digits")
        self.take = take
        self.arm = arm
        self.segment = segment
    }

    /// A file name in `Capture/` or `Clips/`, for example `take3-1-2.caf`.
    init?(fileName: String) {
        guard let match = fileName.wholeMatch(of: /(.+)\.(?:caf|sidecar|wav)/) else { return nil }
        self.init(stem: String(match.1))
    }

    /// A capture, file, or clip ID. The part before the first "@" counts, so a split clip
    /// `take3-1-1@48000` has the name of its segment.
    init?(id: String) {
        self.init(stem: String(id.prefix { $0 != "@" }))
    }

    /// A stem, for example `take3-1-2`: the parse at a boundary (the CLI, the app).
    public init?(stem: String) {
        guard let match = stem.wholeMatch(of: /take([1-9][0-9]{0,8})-([1-9][0-9]{0,8})-([1-9][0-9]{0,8})/) else {
            return nil
        }
        self.init(take: Int(match.1)!, arm: Int(match.2)!, segment: Int(match.3)!)
    }

    public var stem: String { "take\(take)-\(arm)-\(segment)" }
    public var description: String { stem }

    /// 1 plus the highest take number in the file names of `Capture/` and `Clips/`, the capture,
    /// file, and clip IDs of the session, and the pending take. So a take number is never reused,
    /// also after a user empties a folder (decision 0012).
    static func nextTake(in package: URL, session: Session) -> Int {
        let files = [captureFolderName, clipsFolderName].flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: package.appending(path: $0).path)) ?? []
        }
        let ids =
            session.captures.keys.map(\.rawValue) + session.files.keys.map(\.rawValue)
            + session.tracks.flatMap { $0.clips.map(\.id.rawValue) }
        let takes =
            files.compactMap { SegmentName(fileName: $0)?.take } + ids.compactMap { SegmentName(id: $0)?.take }
            + [session.recording?.take ?? 0]
        return takes.max()! + 1
    }

    public static func < (a: Self, b: Self) -> Bool { (a.take, a.arm, a.segment) < (b.take, b.arm, b.segment) }
}

/// The signed difference `to - from` in nanoseconds. Every host-time difference uses it, so a
/// first frame before the take start gives a negative value, not a trap.
func nanos(from: UInt64, to: UInt64) -> Int64 { Int64(bitPattern: to &- from) }

/// The first record of a sidecar: the device facts and the time of the first frame.
struct CaptureHeader: Hashable, Sendable {
    var deviceUID: String
    var deviceName: String
    var nominalRate: Double
    var availableRates: [ClosedRange<Double>]
    /// The channel count of the CAF: 1 or 2.
    var channelCount: Int
    /// In device frames.
    var latency: Int
    var firstSampleTime: Double
    var firstHostTimeNanos: UInt64
}

/// The device clock at one file frame of the segment.
struct Checkpoint: Hashable, Sendable {
    var fileFrame: Int64
    var sampleTime: Double
    var hostTimeNanos: UInt64
}

/// The sidecar file of a segment, version 1 (decision 0012). Little-endian. An 8-byte magic,
/// then records: a UInt32 payload length, a UInt8 kind, the payload, and the FNV-1a 32 hash of
/// the kind and the payload. Kind 1 is the header and comes first; kind 2 is a checkpoint.
struct Sidecar: Hashable, Sendable {
    var header: CaptureHeader
    var checkpoints: [Checkpoint]

    private static let magic = Array("DRGSIDE1".utf8)
    private static let headerKind: UInt8 = 1
    private static let checkpointKind: UInt8 = 2

    /// The magic and the header record: the first bytes of a sidecar file.
    static func encode(_ header: CaptureHeader) -> Data {
        var payload = ByteWriter()
        payload.put(header.firstSampleTime)
        payload.put(header.firstHostTimeNanos)
        payload.put(header.nominalRate)
        payload.put(Int32(truncatingIfNeeded: header.latency))
        payload.put(UInt8(truncatingIfNeeded: header.channelCount))
        payload.put(header.deviceUID)
        payload.put(header.deviceName)
        payload.put(UInt16(header.availableRates.count))
        for range in header.availableRates {
            payload.put(range.lowerBound)
            payload.put(range.upperBound)
        }
        return Data(magic) + record(headerKind, payload.bytes)
    }

    static func encode(_ checkpoint: Checkpoint) -> Data {
        var payload = ByteWriter()
        payload.put(checkpoint.fileFrame)
        payload.put(checkpoint.sampleTime)
        payload.put(checkpoint.hostTimeNanos)
        return record(checkpointKind, payload.bytes)
    }

    /// One record: a UInt32 payload length, the kind, the payload, and the FNV-1a 32 hash of the
    /// kind and the payload. The take anchor uses the same framing (decision 0021).
    static func record(_ kind: UInt8, _ payload: [UInt8]) -> Data {
        var record = ByteWriter()
        record.put(UInt32(payload.count))
        let body = [kind] + payload
        record.bytes += body
        record.put(fnv1a(body))
        return Data(record.bytes)
    }

    /// Nil when the magic or the header is bad. The checkpoints end before the first record that
    /// is short, has a bad hash, has a bad value, or goes back: a torn last record or a tail of
    /// zeros after a power loss.
    static func decode(_ data: Data) -> Sidecar? {
        var reader = ByteReader(Array(data))
        guard reader.take(magic.count).map(Array.init) == magic, let first = reader.record(),
            first.kind == headerKind, let header = decodeHeader(first.payload)
        else { return nil }
        var checkpoints: [Checkpoint] = []
        while let record = reader.record(), record.kind == checkpointKind, record.payload.count == 24 {
            var fields = ByteReader(Array(record.payload))
            let checkpoint = Checkpoint(
                fileFrame: Int64(bitPattern: fields.integer()!), sampleTime: fields.double()!,
                hostTimeNanos: fields.integer()!)
            let previous = checkpoints.last
            guard checkpoint.sampleTime.isFinite, checkpoint.fileFrame >= (previous?.fileFrame ?? 0),
                checkpoint.hostTimeNanos >= (previous?.hostTimeNanos ?? 0)
            else { break }
            checkpoints.append(checkpoint)
        }
        return Sidecar(header: header, checkpoints: checkpoints)
    }

    private static func decodeHeader(_ payload: ArraySlice<UInt8>) -> CaptureHeader? {
        var fields = ByteReader(Array(payload))
        guard let sampleTime = fields.double(), let hostTime: UInt64 = fields.integer(),
            let rate = fields.double(), let latency: UInt32 = fields.integer(), let channels: UInt8 = fields.integer(),
            let uid = fields.text(), let name = fields.text(), let rateCount: UInt16 = fields.integer()
        else { return nil }
        var ranges: [ClosedRange<Double>] = []
        for _ in 0..<rateCount {
            guard let low = fields.double(), let high = fields.double(), low <= high,
                isValidRange(low...high)
            else { return nil }
            ranges.append(low...high)
        }
        let latencyFrames = Int(Int32(bitPattern: latency))
        guard fields.isAtEnd, sampleTime.isFinite, isValidRate(rate), latencyFrames >= 0, (1...2).contains(channels),
            (uid + name).unicodeScalars.allSatisfy(\.isStorableInSession)
        else { return nil }
        return CaptureHeader(
            deviceUID: uid, deviceName: name, nominalRate: rate, availableRates: ranges, channelCount: Int(channels),
            latency: latencyFrames, firstSampleTime: sampleTime, firstHostTimeNanos: hostTime)
    }
}

/// FNV-1a, 32 bits.
func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt32 {
    bytes.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 }
}

struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func put(_ value: some FixedWidthInteger) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }

    mutating func put(_ value: Double) { put(value.bitPattern) }

    /// A UInt16 byte count and the UTF-8 bytes. `InputDevice` keeps each text in that count.
    mutating func put(_ text: String) {
        let utf8 = Array(text.utf8)
        put(UInt16(utf8.count))
        bytes += utf8
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard bytes.count - offset >= count else { return nil }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func integer<T: FixedWidthInteger & UnsignedInteger>() -> T? {
        take(MemoryLayout<T>.size)?.reversed().reduce(0) { $0 << 8 | T($1) }
    }

    mutating func double() -> Double? { integer().map(Double.init(bitPattern:)) }

    mutating func text() -> String? {
        guard let count: UInt16 = integer(), let utf8 = take(Int(count)) else { return nil }
        return String(bytes: utf8, encoding: .utf8)
    }

    /// The kind and the payload of the next record, or nil when it is short or its hash is bad.
    mutating func record() -> (kind: UInt8, payload: ArraySlice<UInt8>)? {
        guard let length: UInt32 = integer(), let body = take(1 + Int(length)), let hash: UInt32 = integer(),
            fnv1a(body) == hash
        else { return nil }
        return (body.first!, body.dropFirst())
    }
}
