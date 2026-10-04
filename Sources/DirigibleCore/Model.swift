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
    /// The gain limit of decision 0008, in dB, in each direction: auto-level, the warning of the
    /// export report, the start rule of the gain drag of the lanes, and the clamp of the inspector.
    public static let levelLimit = 20.0
    public var description: String { "\(dB) dB" }
}

/// The fade lengths of a clip (decision 0035). Each length is in `0...Frames.limit`, so a sum
/// cannot overflow. `Session.check` keeps fadeIn + fadeOut <= the clip length.
public struct Fades: Hashable, Sendable {
    public enum Edge: Sendable { case start, end }

    public let fadeIn: Frames
    public let fadeOut: Frames

    public static let zero = Fades(fadeIn: .zero, fadeOut: .zero)!

    /// Nil for a negative length or a length over `Frames.limit`.
    public init?(fadeIn: Frames, fadeOut: Frames) {
        guard fadeIn.isInRange, fadeOut.isInRange else { return nil }
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// The one curve, for the clip frame `frame` of a clip of `length` frames. Fade-in frame k:
    /// sin(pi/2 * k / I). Fade-out: sin(pi/2 * (N - k) / O), that is cos(pi/2 * j / O) from the
    /// fade-out start. 1 outside the fades. The domain is 0 <= frame < length. `fadeEnvelope` of
    /// `MixReader` is the vector copy of this curve; `MixTests.theEnvelopeEqualsFadesGain` compares
    /// the two.
    public func gain(at frame: Frames, length: Frames) -> Double {
        precondition(frame >= .zero && frame < length, "A fade gain is for a frame of the clip")
        var gain = 1.0
        if fadeIn > .zero, frame < fadeIn { gain *= sin(.pi / 2 * Double(frame.count) / Double(fadeIn.count)) }
        let left = length - frame
        if fadeOut > .zero, left <= fadeOut { gain *= sin(.pi / 2 * Double(left.count) / Double(fadeOut.count)) }
        return gain
    }

    /// The fade of `edge`.
    public subscript(edge: Edge) -> Frames { edge == .start ? fadeIn : fadeOut }

    /// The fade of `edge` stays, clamped to `length`; the other fade yields to the rest.
    public func fitted(to length: Frames, keeping edge: Edge) -> Fades {
        switch edge {
        case .start:
            let fadeIn = min(fadeIn, length)
            return Fades(fadeIn: fadeIn, fadeOut: min(fadeOut, length - fadeIn))!
        case .end:
            let fadeOut = min(fadeOut, length)
            return Fades(fadeIn: min(fadeIn, length - fadeOut), fadeOut: fadeOut)!
        }
    }

    /// A cut part keeps only the fade of an edge of `clip` that it keeps, fitted to its length.
    func cut(_ part: Range<Frames>, of clip: Range<Frames>) -> Fades {
        let fades = Fades(
            fadeIn: part.lowerBound == clip.lowerBound ? fadeIn : .zero,
            fadeOut: part.upperBound == clip.upperBound ? fadeOut : .zero)!
        return fades.fitted(to: part.upperBound - part.lowerBound, keeping: fades.fadeIn > .zero ? .start : .end)
    }
}

/// The crossfade length at each edge of a clip (decision 0036). Each length is even, in
/// `0...Frames.limit`; 0 is no crossfade. At a join, the end of the left clip equals the start of
/// the right clip, and `ClipLane` keeps that pairing.
public struct Crossfades: Hashable, Sendable {
    public let start: Frames
    public let end: Frames

    public static let zero = Crossfades(start: .zero, end: .zero)!

    /// Nil for an odd or negative length, or a length over `Frames.limit`.
    public init?(start: Frames, end: Frames) {
        guard start.isInRange, end.isInRange, start.count % 2 == 0, end.count % 2 == 0 else { return nil }
        self.start = start
        self.end = end
    }

    /// The crossfade of `edge`.
    public subscript(edge: Fades.Edge) -> Frames { edge == .start ? start : end }
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

/// The source of a track (decision 0029): device channels, or the audio of an app. A device
/// case holds the channel count, so a route with three channels cannot exist. Channels are
/// 1-based. An app case has no channels: the track layout picks a mono or a stereo mixdown
/// (decision 0006).
public enum Route: Hashable, Sendable {
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

    case device(uid: String, channels: Channels)
    case app(bundleID: String)
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
    /// `Session.check` keeps the fades and the crossfade halves inside the length (decision 0035).
    public var fades: Fades
    /// `ClipLane` keeps each crossfade paired with the touching neighbor (decision 0036).
    public var crossfades: Crossfades

    public init(
        id: ClipID, file: FileID, start: Frames, offset: Frames, length: Frames, gain: Gain = .zero,
        fades: Fades = .zero, crossfades: Crossfades = .zero
    ) {
        self.id = id
        self.file = file
        self.start = start
        self.offset = offset
        self.length = length
        self.gain = gain
        self.fades = fades
        self.crossfades = crossfades
    }

    public var end: Frames { start + length }
    public var range: Range<Frames> { start..<end }
}

/// The geometry of crossfades (decision 0036).
extension Clip {
    /// The clip as it sounds: the clip plus half of each crossfade from its media handles, with
    /// the crossfade of each edge as the fade of that edge. The render and the draw read it, so
    /// `Fades.gain` and `fadeEnvelope` play a crossfade with no neighbor lookup.
    public var sounding: Clip {
        guard crossfades != .zero else { return self }
        let (left, right) = (crossfades.start.half, crossfades.end.half)
        let fades = Fades(
            fadeIn: crossfades.start == .zero ? self.fades.fadeIn : crossfades.start,
            fadeOut: crossfades.end == .zero ? self.fades.fadeOut : crossfades.end)!
        return Clip(
            id: id, file: file, start: start - left, offset: offset - left, length: length + left + right,
            gain: gain, fades: fades, crossfades: .zero)
    }

    /// The frames of the clip that `edge` reaches: its fade plus half its crossfade.
    func reach(_ edge: Fades.Edge) -> Frames { fades[edge] + crossfades[edge].half }

    /// The room of `edge`: the length minus the reach of the other edge.
    public func room(_ edge: Fades.Edge) -> Frames { length - reach(edge == .start ? .end : .start) }

    /// The fades with the fade of `edge` at `value`, clamped to 0...room(edge): the other edge
    /// never yields (the fade handle and the inspector). Nil at an edge with a crossfade, or when
    /// the room is negative.
    public func fades(setting edge: Fades.Edge, to value: Frames) -> Fades? {
        guard crossfades[edge] == .zero else { return nil }
        let value = min(max(.zero, value), room(edge))
        return edge == .start
            ? Fades(fadeIn: value, fadeOut: fades.fadeOut) : Fades(fadeIn: fades.fadeIn, fadeOut: value)
    }

    /// `fades` fitted beside the crossfade halves: the fade of `edge` stays, and the other fade
    /// yields (decision 0035).
    public func fitting(_ fades: Fades, keeping edge: Fades.Edge) -> Fades {
        fades.fitted(to: max(.zero, length - crossfades.start.half - crossfades.end.half), keeping: edge)
    }

    /// True when `right` plays on from the frame of the file where this clip stops: the handles of
    /// a crossfade there hold one signal, which equal power makes 3 dB too loud.
    public func isSeamless(with right: Clip) -> Bool { file == right.file && offset + length == right.offset }
}

extension Frames {
    /// Half of an even crossfade length.
    var half: Frames { Frames(count / 2) }
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
