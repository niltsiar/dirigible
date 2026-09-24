import Foundation

/// A string ID of one kind of object. The tag makes a `TrackID` and a `ClipID` different types.
/// Callers can give their own IDs, because capture makes deterministic IDs (decision 0004).
public struct ID<Tag>: Hashable, Comparable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// A new unique ID, for objects that the user makes.
    public init() { self.init(UUID().uuidString) }
    public init(stringLiteral value: String) { self.init(value) }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
}

/// A count or a position in frames at the session sample rate. A device sample time or a
/// latency is at the device rate, so it is not `Frames`.
public struct Frames: Hashable, Comparable, Sendable, AdditiveArithmetic, ExpressibleByIntegerLiteral,
    CustomStringConvertible
{
    public var count: Int

    public init(_ count: Int) { self.count = count }
    public init(integerLiteral value: Int) { self.count = value }

    public static let zero = Frames(0)
    /// The largest position or length: 2^40 frames, about 260 days at 48 kHz. Sums of two
    /// values in `0...limit` cannot overflow.
    public static let limit = Frames(1 << 40)
    public static func + (a: Frames, b: Frames) -> Frames { Frames(a.count + b.count) }
    public static func - (a: Frames, b: Frames) -> Frames { Frames(a.count - b.count) }
    public static func < (a: Frames, b: Frames) -> Bool { a.count < b.count }
    public var description: String { String(count) }

    var isInRange: Bool { self >= .zero && self <= .limit }
}

/// A gain in dB. It is always finite.
public struct Gain: Hashable, Sendable, CustomStringConvertible {
    public let dB: Double

    public init?(dB: Double) {
        guard dB.isFinite else { return nil }
        self.dB = dB
    }

    public static let zero = Gain(dB: 0)!
    public var description: String { "\(dB) dB" }
}

public enum ChannelLayout: String, Sendable {
    case mono, stereo

    public init?(channelCount: Int) {
        switch channelCount {
        case 1: self = .mono
        case 2: self = .stereo
        default: return nil
        }
    }

    public var channelCount: Int { self == .mono ? 1 : 2 }
}

public typealias CaptureID = ID<Capture>
public typealias FileID = ID<AudioFile>
public typealias TrackID = ID<Track>
public typealias ClipID = ID<Clip>
public typealias MarkerID = ID<Marker>

/// The device channels that feed a track. The case holds the channel count, so a route with
/// three channels cannot exist. Channels are 1-based.
public struct Route: Hashable, Sendable {
    public enum Channels: Hashable, Sendable {
        case mono(Int)
        case stereo(Int, Int)

        public var layout: ChannelLayout {
            switch self {
            case .mono: .mono
            case .stereo: .stereo
            }
        }

        public var numbers: [Int] {
            switch self {
            case .mono(let channel): [channel]
            case .stereo(let left, let right): [left, right]
            }
        }
    }

    public var deviceUID: String
    public var channels: Channels

    public init(deviceUID: String, channels: Channels) {
        self.deviceUID = deviceUID
        self.channels = channels
    }
}

/// One device segment of a take (decision 0004): the timing data that aligns it with the
/// other devices. `sampleTime` and `latency` are at the device rate.
public struct Capture: Identifiable, Hashable, Sendable {
    public let id: CaptureID
    public var deviceUID: String
    public var deviceName: String
    public var hostTimeNanos: UInt64
    public var sampleTime: Double
    public var nominalSampleRate: Double
    public var measuredSampleRate: Double
    public var latency: Int
    /// The source rate when finalize resampled, else nil.
    public var resampledFromRate: Double?
    /// False when finalize refused the drift fit.
    public var driftCorrected: Bool

    public init(
        id: CaptureID, deviceUID: String, deviceName: String, hostTimeNanos: UInt64, sampleTime: Double,
        nominalSampleRate: Double, measuredSampleRate: Double, latency: Int, resampledFromRate: Double? = nil,
        driftCorrected: Bool = true
    ) {
        self.id = id
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.hostTimeNanos = hostTimeNanos
        self.sampleTime = sampleTime
        self.nominalSampleRate = nominalSampleRate
        self.measuredSampleRate = measuredSampleRate
        self.latency = latency
        self.resampledFromRate = resampledFromRate
        self.driftCorrected = driftCorrected
    }
}

/// An audio file in the pool. `path` is relative to the `Clips/` folder of the package.
public struct AudioFile: Identifiable, Hashable, Sendable {
    public let id: FileID
    public var path: String
    public var layout: ChannelLayout
    public var length: Frames
    /// Nil for an imported file.
    public var capture: CaptureID?

    public init(id: FileID, path: String, layout: ChannelLayout, length: Frames, capture: CaptureID? = nil) {
        self.id = id
        self.path = path
        self.layout = layout
        self.length = length
        self.capture = capture
    }
}

/// A part of a file on the timeline of a track.
public struct Clip: Identifiable, Hashable, Sendable {
    public let id: ClipID
    public var file: FileID
    /// The timeline position of the first frame.
    public var start: Frames
    /// The position of the first frame in the file.
    public var offset: Frames
    public var length: Frames
    public var gain: Gain

    public init(id: ClipID, file: FileID, start: Frames, offset: Frames, length: Frames, gain: Gain = .zero) {
        self.id = id
        self.file = file
        self.start = start
        self.offset = offset
        self.length = length
        self.gain = gain
    }

    public var end: Frames { start + length }
    public var range: Range<Frames> { start..<end }
}

public struct Marker: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case marker, chapter }

    public let id: MarkerID
    public var name: String
    public var position: Frames
    public var kind: Kind

    public init(id: MarkerID, name: String, position: Frames, kind: Kind) {
        self.id = id
        self.name = name
        self.position = position
        self.kind = kind
    }
}

/// A take that runs or waits for finalize (decisions 0003 and 0004). It holds the take anchor.
public struct Recording: Hashable, Sendable {
    /// The take numbers that a stem can hold: 1 to 9 digits (decision 0012).
    public static let takes = 1...999_999_999

    /// In `takes`; `Session.setRecording` refuses other values.
    public var take: Int
    public var playheadFrame: Frames
    public var takeStartHostTimeNanos: UInt64
    public var armedTracks: [TrackID]

    public init(take: Int, playheadFrame: Frames, takeStartHostTimeNanos: UInt64, armedTracks: [TrackID]) {
        self.take = take
        self.playheadFrame = playheadFrame
        self.takeStartHostTimeNanos = takeStartHostTimeNanos
        self.armedTracks = armedTracks
    }
}

/// A track has no public initializer, and only `Session` changes it. So every track that a
/// caller sees is valid.
public struct Track: Identifiable, Hashable, Sendable {
    public let id: TrackID
    public internal(set) var name: String
    public internal(set) var gain: Gain
    public internal(set) var layout: ChannelLayout
    public internal(set) var route: Route?
    public internal(set) var clips: ClipLane

    init(id: TrackID, name: String, layout: ChannelLayout) {
        self.id = id
        self.name = name
        self.gain = .zero
        self.layout = layout
        self.route = nil
        self.clips = ClipLane()
    }
}
