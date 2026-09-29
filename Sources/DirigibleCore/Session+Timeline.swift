import Foundation

extension Session {
    /// The largest clip end on any track; 0 with no clip.
    public var end: Frames { tracks.compactMap { $0.clips.last?.end }.max() ?? .zero }

    /// The first clip start or clip end on any track after `frame`. Nil when there is none.
    public func edge(after frame: Frames) -> Frames? { edges.filter { $0 > frame }.min() }

    /// The last clip start or clip end on any track before `frame`. Nil when there is none.
    public func edge(before frame: Frames) -> Frames? { edges.filter { $0 < frame }.max() }

    /// The nearest marker or chapter position strictly after `frame`. Nil when there is none.
    public func markerPosition(after frame: Frames) -> Frames? {
        markers.values.map(\.position).filter { $0 > frame }.min()
    }

    /// The nearest marker or chapter position strictly before `frame`. Nil when there is none.
    public func markerPosition(before frame: Frames) -> Frames? {
        markers.values.map(\.position).filter { $0 < frame }.max()
    }

    private var edges: [Frames] { tracks.flatMap { $0.clips.flatMap { [$0.start, $0.end] } } }
}
