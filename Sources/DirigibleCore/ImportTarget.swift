import Foundation

/// Where an import puts its clip (decision 0040).
public struct ImportTarget: Hashable, Sendable {
    /// Nil: a new last track, named after the file, with the file layout.
    public var track: TrackID?
    public var start: Frames

    public init(track: TrackID?, start: Frames) {
        self.track = track
        self.start = start
    }
}
