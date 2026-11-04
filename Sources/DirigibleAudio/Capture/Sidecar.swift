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
    /// The capture files of the segment in `Capture/` (decision 0004).
    package var cafName: String { "\(stem).caf" }
    package var sidecarName: String { "\(stem).sidecar" }

    /// 1 plus the highest take number in the file names of `Capture/` and `Clips/`, the capture,
    /// file, and clip IDs of the session, and the pending take. So a take number is never reused,
    /// also after a user empties a folder (decision 0012). Every file name that starts with
    /// `take<n>` and then a byte that is not a digit counts: an anchor, and a file of a newer
    /// build (decision 0024 P10).
    static func nextTake(in package: URL, session: Session) -> Int {
        let files = [captureFolderName, clipsFolderName].flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: package.appending(path: $0).path)) ?? []
        }
        let ids =
            session.captures.keys.map(\.rawValue) + session.files.keys.map(\.rawValue)
            + session.tracks.flatMap { $0.clips.map(\.id.rawValue) }
        let takes =
            files.compactMap { $0.prefixMatch(of: /take([1-9][0-9]{0,8})(?![0-9])/).map { Int($0.1)! } }
            + ids.compactMap { SegmentName(id: $0)?.take }
            + [session.recording?.take ?? 0]
        return takes.max()! + 1
    }

    public static func < (a: Self, b: Self) -> Bool { (a.take, a.arm, a.segment) < (b.take, b.arm, b.segment) }
}

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

/// The facts of one finalize of a segment that a placement from its WAV needs after the CAF is
/// gone (decision 0071).
struct FinalizeRecord: Hashable, Sendable {
    /// The CAF frames that the finalize converted.
    var cafFrames: Int64
    /// `RateChoice.source`.
    var sourceRate: Double
    /// The clip gain of `ClipConversion`, before the level of decision 0031.
    var conversionGain: Gain
}

/// The sidecar file of a segment, version 1 (decision 0012). Little-endian. An 8-byte magic,
/// then records: a UInt32 payload length, a UInt8 kind, the payload, and the FNV-1a 32 hash of
/// the kind and the payload. Kind 1 is the header and comes first; kind 2 is a checkpoint; kind 3
/// is a finalize record, after the last checkpoint (decision 0071). A reader of an older build
/// stops at the first record that is not a checkpoint, so kind 3 keeps version 1.
struct Sidecar: Hashable, Sendable {
    var header: CaptureHeader
    var checkpoints: [Checkpoint]
    /// The last valid finalize record.
    var finalized: FinalizeRecord? = nil

    private static let magic = Array("DRGSIDE1".utf8)
    private static let headerKind: UInt8 = 1
    private static let checkpointKind: UInt8 = 2
    private static let finalizeKind: UInt8 = 3

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

    static func encode(_ finalized: FinalizeRecord) -> Data {
        var payload = ByteWriter()
        payload.put(finalized.cafFrames)
        payload.put(finalized.sourceRate)
        payload.put(finalized.conversionGain.dB)
        return record(finalizeKind, payload.bytes)
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

    /// Nil when the magic or the header is bad; throws for a sidecar of a newer version (decision
    /// 0024). The records end before the first record that is short or has a bad hash: a torn last
    /// record or a tail of zeros after a power loss. The checkpoints end before the first record
    /// that is not a checkpoint, has a bad value, or goes back. `finalized` is the last kind 3
    /// record with valid values.
    static func decode(_ data: Data) throws(NewerFormat) -> Sidecar? {
        var reader = ByteReader(Array(data))
        guard try reader.magic(magic), let first = reader.record(),
            first.kind == headerKind, let header = decodeHeader(first.payload)
        else { return nil }
        var sidecar = Sidecar(header: header, checkpoints: [])
        var checkpointsEnded = false
        while let record = reader.record() {
            if record.kind == finalizeKind, let finalized = decodeFinalized(record.payload) {
                sidecar.finalized = finalized
            }
            guard !checkpointsEnded, record.kind == checkpointKind,
                let checkpoint = decodeCheckpoint(record.payload, after: sidecar.checkpoints.last)
            else {
                checkpointsEnded = true
                continue
            }
            sidecar.checkpoints.append(checkpoint)
        }
        return sidecar
    }

    /// The byte count of the magic and the whole records of `data`: the end of the last record
    /// before one that is short or has a bad hash. Nil when the magic is bad or newer.
    static func wholeLength(_ data: Data) -> Int? {
        var reader = ByteReader(Array(data))
        guard (try? reader.magic(magic)) == true else { return nil }
        var end = reader.offset
        while reader.record() != nil { end = reader.offset }
        return end
    }

    /// Truncates the sidecar at `url` to `wholeLength`, then appends `finalized`, with no flush. A
    /// torn record hides each record after it (`decode`), so the truncate comes first. Returns the
    /// errno of a fault: then the sidecar has no new record.
    static func append(_ finalized: FinalizeRecord, toSidecarAt url: URL) -> Int32? {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return posixCode(of: error) ?? EIO
        }
        guard let length = wholeLength(data) else { return EINVAL }
        let bytes = encode(finalized)
        guard ftruncate(descriptor, off_t(length)) == 0 else { return errno }
        let written = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, bytes.count, off_t(length)) }
        if written < 0 { return errno }
        return written == bytes.count ? nil : EIO
    }

    private static func decodeCheckpoint(_ payload: ArraySlice<UInt8>, after previous: Checkpoint?) -> Checkpoint? {
        guard payload.count == 24 else { return nil }
        var fields = ByteReader(Array(payload))
        let checkpoint = Checkpoint(
            fileFrame: Int64(bitPattern: fields.integer()!), sampleTime: fields.double()!,
            hostTimeNanos: fields.integer()!)
        guard checkpoint.sampleTime.isFinite, checkpoint.fileFrame >= (previous?.fileFrame ?? 0),
            checkpoint.hostTimeNanos >= (previous?.hostTimeNanos ?? 0)
        else { return nil }
        return checkpoint
    }

    private static func decodeFinalized(_ payload: ArraySlice<UInt8>) -> FinalizeRecord? {
        guard payload.count == 24 else { return nil }
        var fields = ByteReader(Array(payload))
        let frames = Int64(bitPattern: fields.integer()!)
        let rate = fields.double()!
        guard frames > 0, isValidRate(rate), let gain = Gain(dB: fields.double()!) else { return nil }
        return FinalizeRecord(cafFrames: frames, sourceRate: rate, conversionGain: gain)
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

/// A file of a format version higher than this build reads (decision 0024 P3).
struct NewerFormat: Error, Hashable, Sendable {
    let version: Int
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

    /// Reads the 8-byte magic of decision 0024 P9: the 7-byte prefix of `current`, then one ASCII
    /// digit 1 to 9, the version. False for another prefix, another byte, or a short file. Throws
    /// for a digit above the digit of `current`.
    mutating func magic(_ current: [UInt8]) throws(NewerFormat) -> Bool { try version(current) != nil }

    /// `magic(_:)` that gives the version, or nil where `magic(_:)` gives false.
    mutating func version(_ current: [UInt8]) throws(NewerFormat) -> Int? {
        guard let bytes = take(current.count), bytes.dropLast().elementsEqual(current.dropLast()),
            let digit = bytes.last, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(digit)
        else { return nil }
        if digit > current.last! { throw NewerFormat(version: Int(digit - UInt8(ascii: "0"))) }
        return Int(digit - UInt8(ascii: "0"))
    }

    /// The kind and the payload of the next record, or nil when it is short or its hash is bad.
    mutating func record() -> (kind: UInt8, payload: ArraySlice<UInt8>)? {
        guard let length: UInt32 = integer(), let body = take(1 + Int(length)), let hash: UInt32 = integer(),
            fnv1a(body) == hash
        else { return nil }
        return (body.first!, body.dropFirst())
    }
}
