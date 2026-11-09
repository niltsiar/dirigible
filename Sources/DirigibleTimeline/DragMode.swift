import DirigibleCore

/// What a clip drag does to the clips that it meets. The app keeps one mode for all windows.
public enum DragMode: String, CaseIterable, Sendable {
    case overwrite
    case noOverlap
    case crossfade
    /// A single move drag is `Session.shuffle`, and a plain trim drag ripples its own track.
    case shuffle

    /// The overlap rule of a move or a nudge in this mode. A group move and the nudge keys are no
    /// ripple, so Shuffle gives Overwrite.
    public var overlap: OverlapMode {
        switch self {
        case .overwrite, .shuffle: .overwrite
        case .noOverlap: .noOverlap
        case .crossfade: .crossfade
        }
    }
}

/// The tracks that a trim press ripples: Option ripples all tracks (decision 0037), and a plain
/// press in Shuffle mode ripples its own track.
enum TrimRipple: Sendable {
    case none
    case ownTrack
    case allTracks

    init(option: Bool, mode: DragMode) {
        self = option ? .allTracks : mode == .shuffle ? .ownTrack : .none
    }
}
