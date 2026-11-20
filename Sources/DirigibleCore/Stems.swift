import Foundation

/// How a stem export groups the heard tracks of its set into files.
public enum StemGrouping: String, CaseIterable, Sendable {
    /// One stem for each heard track.
    case track
}

/// One file of a stem export: the mix of its tracks over the range of its plan.
public struct Stem: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case track(TrackID)
    }

    public let key: Key
    /// Heard tracks only, never empty.
    public let tracks: Set<TrackID>
}

/// The stems of one export. Each stem file starts at the range start and has the range length.
public struct StemPlan: Hashable, Sendable {
    public let range: Range<Frames>
    /// In session order.
    public let stems: [Stem]
}

extension Session {
    /// The stems of the tracks of `ids` (nil: all tracks) that the mix hears (`heardTracks(in:)`,
    /// decision 0039), over `range`.
    public func stemPlan(by grouping: StemGrouping, tracks ids: Set<TrackID>?, range: Range<Frames>) -> StemPlan {
        switch grouping {
        case .track:
            StemPlan(range: range, stems: heardTracks(in: ids).map { Stem(key: .track($0.id), tracks: [$0.id]) })
        }
    }
}
