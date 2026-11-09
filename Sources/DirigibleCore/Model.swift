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

/// The fade lengths of a clip (decision 0035). Each length is in `0...Frames.limit`, so a sum
/// cannot overflow. `Session.check` keeps fadeIn + fadeOut <= the clip length.
public struct Fades: Hashable, Sendable {
    public enum Edge: Sendable {
        case start, end

        var other: Edge { self == .start ? .end : .start }
    }

    public let fadeIn: Frames
    public let fadeOut: Frames

    public static let zero = Fades(fadeIn: .zero, fadeOut: .zero)!

    /// Nil for a negative length or a length over `Frames.limit`.
    public init?(fadeIn: Frames, fadeOut: Frames) {
        guard fadeIn.isInRange, fadeOut.isInRange else { return nil }
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    /// The fade factor of the clip frame `frame` of a clip of `length` frames. Fade-in frame k:
    /// sin(pi/2 * k / I), or k / I with the linear curve. Fade-out: sin(pi/2 * (N - k) / O), that is
    /// cos(pi/2 * j / O) from the fade-out start, or (N - k) / O. 1 outside the fades. The domain is
    /// 0 <= frame < length. `gainFactors` of `MixReader` is the vector copy of this curve;
    /// `MixTests.theGainFactorsEqualFadesGain` compares the two.
    public func gain(at frame: Frames, length: Frames, curves: Curves) -> Double {
        precondition(frame >= .zero && frame < length, "A fade gain is for a frame of the clip")
        func factor(_ index: Frames, _ fade: Frames, _ curve: Curve) -> Double {
            let (index, fade) = (Double(index.count), Double(fade.count))
            return curve == .sine ? sin(.pi / 2 * index / fade) : index / fade
        }
        var gain = 1.0
        if fadeIn > .zero, frame < fadeIn { gain *= factor(frame, fadeIn, curves.start) }
        let left = length - frame
        if fadeOut > .zero, left <= fadeOut { gain *= factor(left, fadeOut, curves.end) }
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
    /// Nil for a recorded, imported, pasted, or split file (decision 0057).
    public var origin: RenderOrigin?

    public init(
        id: FileID, path: String, layout: ChannelLayout, length: Frames, capture: CaptureID? = nil,
        origin: RenderOrigin? = nil
    ) {
        self.id = id
        self.path = path
        self.layout = layout
        self.length = length
        self.capture = capture
        self.origin = origin
    }

    /// A file that finalize made: its capture ID equals its file ID (decision 0061). Only such a
    /// file has a take time.
    public var isTakeFile: Bool { capture?.rawValue == id.rawValue }
}

/// How a rendered file was made (decision 0057). File frame i is frame `offset + i` of `source`.
public struct RenderOrigin: Hashable, Sendable {
    /// The direct input: a plain file or another rendered file.
    public let source: FileID
    public let offset: Frames
    public let treatment: Treatment
    /// The dB of the second-pass scale of decision 0054, which the render added to each clip of the run.
    public let addedGain: Gain

    public init(source: FileID, offset: Frames, treatment: Treatment, addedGain: Gain) {
        self.source = source
        self.offset = offset
        self.treatment = treatment
        self.addedGain = addedGain
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
    /// At file frames, on top of `gain` (decision 0060). `Session.check` keeps each point in the file.
    public var envelope: GainEnvelope
    /// The Level Over Time layer, at file frames, added to `gain` and `envelope`.
    /// `Session.setRides` sets a new list. The edits that move a clip or change its file map the
    /// list with it: lower, a render, split stereo, heal, and `Excerpt.resampled`. `Session.check`
    /// keeps each point in the file.
    public var ride: GainEnvelope

    public init(
        id: ClipID, file: FileID, start: Frames, offset: Frames, length: Frames, gain: Gain = .zero,
        fades: Fades = .zero, crossfades: Crossfades = .zero, envelope: GainEnvelope = .empty,
        ride: GainEnvelope = .empty
    ) {
        self.id = id
        self.file = file
        self.start = start
        self.offset = offset
        self.length = length
        self.gain = gain
        self.fades = fades
        self.crossfades = crossfades
        self.envelope = envelope
        self.ride = ride
    }

    public var end: Frames { start + length }
    public var range: Range<Frames> { start..<end }
}

public struct Marker: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case marker, chapter }

    /// The longest URL in UTF-8 bytes: the URL length of the 3GPP `href` box of an M4A chapter
    /// has 8 bits (TS 26.245). `Session.setMarker` refuses a longer one.
    public static let maximumURLBytes = 255
    /// The English rule text of a URL over `maximumURLBytes`, for the CLI and MCP (code gate item E5).
    public static let urlTooLongText = "a marker URL has at most \(maximumURLBytes) bytes."

    public let id: MarkerID
    public var name: String
    public var position: Frames
    public var kind: Kind
    /// The link of a chapter in the MP3, the M4A, and chapters.json. A marker keeps it, and only a
    /// chapter goes into a file.
    public var url: WebURL?
    /// The image of a chapter, a file in `Artwork/` (decision 0045).
    public var image: ArtworkName?

    public init(
        id: MarkerID, name: String, position: Frames, kind: Kind, url: WebURL? = nil, image: ArtworkName? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.kind = kind
        self.url = url
        self.image = image
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
    /// A take that starts with a pre-roll. An older build refuses its `session.xml` and its anchor
    /// as newer (decision 0024), so it never places the take audio from the take start.
    public var isPreRoll: Bool

    public init(
        take: Int, playheadFrame: Frames, takeStartHostTimeNanos: UInt64, armedTracks: [TrackID],
        isPreRoll: Bool = false
    ) {
        self.take = take
        self.playheadFrame = playheadFrame
        self.takeStartHostTimeNanos = takeStartHostTimeNanos
        self.armedTracks = armedTracks
        self.isPreRoll = isPreRoll
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
    /// Mute and solo (decision 0039). `Session.heardTracks(in:)` owns the rule.
    public internal(set) var isMuted = false
    public internal(set) var isSoloed = false
    /// A ripple moves the clips of a follow track whole unless the edit names the track (decision 0073).
    public internal(set) var isFollowTrack = false
    /// The header strip, the default track lists of a duck (decision 0060), and the clips that Reduce
    /// Noise takes: none on a music or effects track (decision 0054). No role changes the sound.
    /// A new reader updates the copies of this list: `track.role.help`, `EditRules.roleNote`,
    /// `AgentManual.roleLine`, and the guide section "Give a track a role".
    public internal(set) var role: Role?

    /// The raw value is the word of `session.xml`, the CLI, and the tools.
    public enum Role: String, CaseIterable, Sendable {
        case dialogue, music, effects
    }

    init(id: TrackID, name: String, layout: ChannelLayout) {
        self.id = id
        self.name = name
        self.gain = .zero
        self.layout = layout
        self.route = nil
        self.clips = ClipLane()
    }
}
