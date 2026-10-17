import Foundation

/// Where an import puts its clip, and the shape of the clip (decision 0040).
public struct ImportTarget: Hashable, Sendable {
    /// Nil: a new last track, named after the file, with the file layout.
    public var track: TrackID?
    public var start: Frames
    /// Nil: the stem of the file.
    public var clip: ClipID?
    /// The first clip frame in the made WAV, at the session rate.
    public var offset: Frames
    /// Nil: the rest of the made WAV. A longer length stops at its end.
    public var length: Frames?
    /// Nil: the level gain, or the gain of the conversion with no level.
    public var gain: Gain?
    public var fades: Fades

    public init(
        track: TrackID?, start: Frames, clip: ClipID? = nil, offset: Frames = .zero, length: Frames? = nil,
        gain: Gain? = nil, fades: Fades = .zero
    ) {
        self.track = track
        self.start = start
        self.clip = clip
        self.offset = offset
        self.length = length
        self.gain = gain
        self.fades = fades
    }
}
