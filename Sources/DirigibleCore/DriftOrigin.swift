/// The source frames for each file frame of a drift-corrected file (decision 0077, D1). The value is
/// always finite and less than 1000 ppm from 1.
public struct DriftRatio: Hashable, Sendable {
    public let value: Double

    /// The largest rate error of a clock that the fit and the drift link accept.
    public static let limit = 1000e-6

    /// Nil for a value that is not finite, or is not between `1 - limit` and `1 + limit`.
    public init?(_ value: Double) {
        guard value > 1 - Self.limit, value < 1 + Self.limit else { return nil }
        self.value = value
    }
}

/// The link of a drift-corrected file to the file that it resamples (decision 0077 D1). File frame j
/// is source frame `offset + j x ratio`. `Session.check(_:of:)` holds the rules of D4.
public struct DriftOrigin: Hashable, Sendable {
    /// A plain file: no origin, no drift link, and no capture.
    public let source: FileID
    /// The source frame of file frame 0.
    public let offset: Frames
    public let ratio: DriftRatio
    /// The gain that the fix added to the clip, after the clamp to `Gain.range` (decision 0077 D9).
    /// A second fix takes it off.
    public let addedGain: Gain

    public init(source: FileID, offset: Frames, ratio: DriftRatio, addedGain: Gain) {
        self.source = source
        self.offset = offset
        self.ratio = ratio
        self.addedGain = addedGain
    }

    /// The source frame of file frame `frame`, not rounded.
    public func sourceFrame(of frame: Frames) -> Double {
        Double(offset.count) + Double(frame.count) * ratio.value
    }

    /// The nearest file frame of the source frame `frame`: round((frame - offset) / ratio).
    public func fileFrame(ofSource frame: Double) -> Frames {
        Frames(Int(((frame - Double(offset.count)) / ratio.value).rounded()))
    }
}

/// The first fault that keeps a file from being the source of a drift link (decision 0077 D4).
public enum DriftSourceFault: Hashable, Sendable {
    /// A rendered file.
    case origin
    /// A drift-corrected file.
    case driftLink
    /// A take file or a split half of a take: it is on the session clock (decision 0004).
    case capture
}
