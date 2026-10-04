import DirigibleCore
import Foundation

/// The edits of a selection (decision 0038). A range uses the rules of `Marks` (decision 0018). A
/// clip set takes its clips from `selectedClips(in:)`, so a stale ID never reaches Core, and no
/// edit reads a clip set as a range.
extension Selection {
    private func tracks(of clips: [(clip: Clip, lane: Int)], in session: Session) -> Set<TrackID> {
        Set(clips.map { session.tracks[$0.lane].id })
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
        guard case .clips = self else { return try marks?.faded(session) }
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

    /// The clips of Auto Level (decision 0031). Nil with no selection.
    public func clipsToLevel(in session: Session) -> Set<ClipID>? {
        guard case .clips = self else { return marks?.clipsToLevel(in: session) }
        let ids = Set(selectedClips(in: session).map(\.clip.id))
        return ids.isEmpty ? nil : ids
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

    /// The frames and tracks of a split: for a clip set, the playhead on the tracks where a set
    /// clip holds it.
    public func splitPoints(playhead: Frames, in session: Session) -> (frames: [Frames], tracks: [TrackID]) {
        guard case .clips = self else { return (marks ?? Marks()).splitPoints(playhead: playhead, in: session) }
        let holding = tracks(of: selectedClips(in: session).filter { $0.clip.range.contains(playhead) }, in: session)
        return ([playhead], session.tracks.map(\.id).filter(holding.contains))
    }

    /// I and O: a clip set gives a range on its tracks.
    public func settingIn(_ playhead: Frames, in session: Session) -> Marks {
        rangeMarks(in: session).settingIn(playhead, in: session)
    }

    public func settingOut(_ playhead: Frames, in session: Session) -> Marks {
        rangeMarks(in: session).settingOut(playhead, in: session)
    }

    /// The Marks of I and O: the range, or no points on the tracks of a clip set.
    private func rangeMarks(in session: Session) -> Marks {
        marks ?? Marks(tracks: tracks(of: selectedClips(in: session), in: session))
    }

    /// Zoom to Selection: the range, or the span of the set clips (a view, not an edit).
    public func span(in session: Session) -> Range<Frames>? {
        guard case .clips = self else { return marks?.selection(in: session)?.range }
        let clips = selectedClips(in: session).map(\.clip)
        guard let start = clips.map(\.start).min(), let end = clips.map(\.end).max() else { return nil }
        return start..<end
    }

    /// Show Clips in Finder: the files of the set clips, of the clips that overlap the range on its
    /// tracks, or of every clip with no selection.
    public func files(in session: Session) -> Set<FileID> {
        if case .clips = self { return Set(selectedClips(in: session).map(\.clip.file)) }
        let selection = marks?.selection(in: session)
        let tracks = selection?.tracks.compactMap(session.track) ?? session.tracks
        return Set(
            tracks.flatMap { track in
                track.clips.filter { clip in selection.map { clip.range.overlaps($0.range) } ?? true }.map(\.file)
            })
    }
}
