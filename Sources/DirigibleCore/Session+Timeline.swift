import Foundation

extension Session {
    /// The largest clip end on any track; 0 with no clip.
    public var end: Frames { tracks.compactMap { $0.clips.last?.end }.max() ?? .zero }

    /// The first clip start or clip end on any track after `frame`. Nil when there is none.
    public func edge(after frame: Frames) -> Frames? { edges.filter { $0 > frame }.min() }

    /// The last clip start or clip end on any track before `frame`. Nil when there is none.
    public func edge(before frame: Frames) -> Frames? { edges.filter { $0 < frame }.max() }

    /// True when a clip on one of `tracks` holds `frame` (start <= frame < end). The transport
    /// bar warns before a take records over it (decision 0016).
    public func hasClip(at frame: Frames, on tracks: [TrackID]) -> Bool {
        self.tracks.contains { track in
            tracks.contains(track.id) && track.clips.contains { $0.start <= frame && frame < $0.end }
        }
    }

    private var edges: [Frames] { tracks.flatMap { $0.clips.flatMap { [$0.start, $0.end] } } }
}
