import Foundation

extension Session {
    /// The largest clip end on any track; 0 with no clip.
    public var end: Frames { tracks.compactMap { $0.clips.last?.end }.max() ?? .zero }
}
