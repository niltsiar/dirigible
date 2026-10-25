import DirigibleCore
import Foundation

/// The edits of a selection (decision 0038). A range uses the rules of `Marks` (decision 0018). A
/// clip set takes its clips from `selectedClips(in:)`, so a stale ID never reaches Core, and no
/// edit reads a clip set as a range.
extension Selection {
    private func tracks(of clips: [(clip: Clip, lane: Int)], in session: Session) -> Set<TrackID> {
        Set(clips.map { session.tracks[$0.lane].id })
    }

    /// Copy: the range, or the live set clips whole (`Session.excerpt(of:)`). Nil when nothing is
    /// selected.
    public func excerpt(in session: Session) throws(SessionError) -> Excerpt? {
        switch self {
        case .range(let marks):
            guard let selection = marks.selection(in: session) else { return nil }
            return try session.excerpt(of: selection.range, on: selection.tracks)
        case .clips:
            let ids = selectedClips(in: session).map(\.clip.id)
            return ids.isEmpty ? nil : try session.excerpt(of: ids)
        }
    }

    /// The selection after a Paste or an Insert: the pasted clips for a set excerpt, because the
    /// pasted range can hold clips that were not copied; the pasted range for a range excerpt.
    public init(pasted ids: [ClipID], of excerpt: Excerpt, at start: Frames, on tracks: [TrackID]) {
        switch excerpt.kind {
        case .range: self = .range(Marks(inPoint: start, outPoint: start + excerpt.length, tracks: Set(tracks)))
        case .clips: self = ClipSet(Set(ids)).map { .clips($0) } ?? .none
        }
    }

    /// Delete: a range clears its frames and leaves a gap; a clip set removes its clips. Nil when
    /// nothing is selected.
    public func deleted(_ session: Session) throws(SessionError) -> Session? {
        var result = session
        switch self {
        case .range(let marks):
            guard let selection = marks.selection(in: session) else { return nil }
            try result.clear(selection.range, on: selection.tracks)
        case .clips:
            let ids = selectedClips(in: session).map(\.clip.id)
            guard !ids.isEmpty else { return nil }
            try result.removeClips(ids)
        }
        return result
    }

    /// Nudge: the clips, the offset that keeps every start at 0 or more, and the selection after
    /// it. A clip set stays. Nil when no clip moves.
    public func nudge(by step: Frames, in session: Session) -> (clips: [ClipID], offset: Frames, selection: Selection)?
    {
        switch self {
        case .range(let marks):
            return marks.nudge(by: step, in: session).map { ($0.clips, $0.offset, .range($0.marks)) }
        case .clips:
            let clips = selectedClips(in: session).map(\.clip)
            guard let first = clips.map(\.start).min() else { return nil }
            let offset = max(step, .zero - first)
            return offset == .zero ? nil : (clips.map(\.id), offset, self)
        }
    }

    /// Command-F: a clip set calls `Marks.faded` with a range that holds each per-track run of
    /// joined set clips whole, and chains the results, so one edit makes one undo entry. Nil when
    /// nothing changes.
    public func faded(_ session: Session) throws(SessionError) -> Session? {
        switch self {
        case .range(let marks): return try marks.faded(session)
        case .clips: return try fadedRuns(session)
        }
    }

    /// The runs of joined set clips of `faded`, each as a range on its track, chained.
    private func fadedRuns(_ session: Session) throws(SessionError) -> Session? {
        var runs: [Marks] = []
        var last: (clip: Clip, lane: Int)?
        for (clip, lane) in selectedClips(in: session) {
            if let previous = last, previous.lane == lane, previous.clip.end == clip.start {
                runs[runs.count - 1].outPoint = clip.end
            } else {
                runs.append(Marks(inPoint: clip.start, outPoint: clip.end, tracks: [session.tracks[lane].id]))
            }
            last = (clip, lane)
        }
        var result: Session?
        for run in runs { result = try run.faded(result ?? session) ?? result }
        return result
    }

    /// The clips of Auto Level (decision 0031). Nil only for the empty selection; a set with no
    /// clip that is still in the session gives an empty set.
    public func clipsToLevel(in session: Session) -> Set<ClipID>? {
        switch self {
        case .range(let marks): marks.clipsToLevel(in: session)
        case .clips: Set(selectedClips(in: session).map(\.clip.id))
        }
    }

    /// The tracks of a paste: for a clip set, the first track with a set clip and the tracks under
    /// it.
    public func pasteTracks(for excerpt: Excerpt, in session: Session) -> [TrackID]? {
        switch self {
        case .range(let marks): marks.pasteTracks(for: excerpt, in: session)
        case .clips:
            Marks(tracks: tracks(of: Array(selectedClips(in: session).prefix(1)), in: session))
                .pasteTracks(for: excerpt, in: session)
        }
    }

    /// The frames and tracks of a split: for a clip set, the playhead on the tracks where it cuts a
    /// set clip.
    public func splitPoints(playhead: Frames, in session: Session) -> (frames: [Frames], tracks: [TrackID]) {
        switch self {
        case .range(let marks): return marks.splitPoints(playhead: playhead, in: session)
        case .clips(let set):
            let cutting = session.tracks.filter { track in
                track.clips.index(cutting: playhead).map { set.ids.contains(track.clips[$0].id) } == true
            }
            return ([playhead], cutting.map(\.id))
        }
    }

    /// I and O: a clip set gives a range on its tracks.
    public func settingIn(_ playhead: Frames, in session: Session) -> Marks {
        rangeMarks(in: session).settingIn(playhead, in: session)
    }

    public func settingOut(_ playhead: Frames, in session: Session) -> Marks {
        rangeMarks(in: session).settingOut(playhead, in: session)
    }

    /// The range Marks of the selection: the range, or no points on the tracks of a clip set.
    func rangeMarks(in session: Session) -> Marks {
        switch self {
        case .range(let marks): marks
        case .clips: Marks(tracks: tracks(of: selectedClips(in: session), in: session))
        }
    }

    /// Zoom to Selection and the duck scope: the range, or the hull of the set clips, from the first
    /// clip start to the last clip end. Neither loses or copies audio.
    public func span(in session: Session) -> Range<Frames>? {
        switch self {
        case .range(let marks): return marks.selection(in: session)?.range
        case .clips:
            let clips = selectedClips(in: session).map(\.clip)
            guard let start = clips.map(\.start).min(), let end = clips.map(\.end).max() else { return nil }
            return start..<end
        }
    }

    /// Show Clips in Finder: the files of the set clips, of the clips that overlap the range on its
    /// tracks, or of every clip with no selection.
    public func files(in session: Session) -> Set<FileID> {
        let selection: (range: Range<Frames>, tracks: [TrackID])?
        switch self {
        case .range(let marks): selection = marks.selection(in: session)
        case .clips: return Set(selectedClips(in: session).map(\.clip.file))
        }
        let tracks = selection?.tracks.compactMap(session.track) ?? session.tracks
        return Set(
            tracks.flatMap { track in
                track.clips.filter { clip in selection.map { clip.range.overlaps($0.range) } ?? true }.map(\.file)
            })
    }
}
