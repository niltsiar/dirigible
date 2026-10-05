import DirigibleCore
import Foundation

/// The selection of a window (decision 0038): a range (in, out, tracks) or a set of clips. The two
/// kinds are never active together. Window state in `SessionWindow`, never in `Session`.
public enum Selection: Hashable, Sendable {
    /// `.range(Marks())` is no selection.
    case range(Marks)
    /// The clips of Command-click.
    case clips(ClipSet)

    public static let none = Selection.range(Marks())

    /// The range; nil for a clip set, so a range edit does nothing for it.
    public var marks: Marks? {
        if case .range(let marks) = self { return marks }
        return nil
    }

    /// True for a range with no frames or no live track, and for a set with no live clip.
    public func isEmpty(in session: Session) -> Bool {
        switch self {
        case .range(let marks): marks.selection(in: session) == nil
        case .clips: selectedClips(in: session).isEmpty
        }
    }

    /// The selected clips in session order, with their lanes: the set clips that the session
    /// still has, or the clips that the range holds whole. Every Core call on a clip set takes its
    /// IDs from here, so a stale ID never reaches Core.
    public func selectedClips(in session: Session) -> [(clip: Clip, lane: Int)] {
        switch self {
        case .range(let marks): return marks.heldClips(in: session)
        case .clips(let set):
            return session.tracks.indices.flatMap { lane in
                session.tracks[lane].clips.filter { set.ids.contains($0.id) }.map { ($0, lane) }
            }
        }
    }

    /// Command-click on a clip: the selected clips with the clip added, or removed when it is in
    /// them. No clip left gives no selection.
    public func toggling(_ clip: ClipID, in session: Session) -> Selection {
        var ids = Set(selectedClips(in: session).map(\.clip.id))
        if ids.remove(clip) == nil { ids.insert(clip) }
        return ClipSet(ids).map { .clips($0) } ?? .none
    }

    /// The tracks that the headers show as selected: the live tracks of a range, also with no
    /// points. A clip set picks clips, not tracks, so it gives none (decision 0038).
    public func headerTracks(in session: Session) -> Set<TrackID> {
        guard let marks else { return [] }
        return Set(session.tracks.map(\.id).filter(marks.tracks.contains))
    }

    /// A click on the header of `track`. A range keeps its points; a clip set becomes a range with
    /// no points. Command toggles the track. Shift spans the tracks in session order from the
    /// selected tracks to `track`.
    public func clickingHeader(_ track: TrackID, command: Bool, shift: Bool, in session: Session) -> Selection {
        let marks = marks ?? Marks()
        if command { return .range(marks.toggled(track)) }
        var tracks: Set<TrackID> = [track]
        if shift {
            let picked = headerTracks(in: session).union([track])
            let lanes = session.tracks.indices.filter { picked.contains(session.tracks[$0].id) }
            if let first = lanes.first, let last = lanes.last { tracks = Set(session.tracks[first...last].map(\.id)) }
        }
        return .range(Marks(inPoint: marks.inPoint, outPoint: marks.outPoint, tracks: tracks))
    }
}

/// The clips of a clip selection: never empty. An ID that an undo removed stays until the next read
/// drops it.
public struct ClipSet: Hashable, Sendable {
    public let ids: Set<ClipID>

    /// Nil when `ids` is empty.
    public init?(_ ids: Set<ClipID>) {
        guard !ids.isEmpty else { return nil }
        self.ids = ids
    }
}
