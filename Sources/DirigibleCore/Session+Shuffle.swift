import Foundation

extension Session {
    /// Moves the clip to `start` on `track` as a ripple (decision 0037): a Ripple Delete of its range on its
    /// own track, then a Ripple Insert of its length at `start` on `track`, then the clip at `start`. `start`
    /// is a frame of the timeline after the close. Only these two tracks edit, as named lanes (decision
    /// 0073), so another track stays, also a follow track. The markers follow Rule M of the delete and the
    /// insert. A move to the same track and start changes nothing. A throw changes nothing.
    public mutating func shuffle(_ id: ClipID, to track: TrackID, start: Frames) throws(SessionError) {
        let (source, index) = try position(of: id)
        let clip = tracks[source].clips[index]
        if tracks[source].id == track, clip.start == start { return }
        var copy = self
        try copy.shuffleClose(clip, on: tracks[source].id)
        try copy.shuffleDrop(clip, to: track, start: start)
        self = copy
    }

    /// The first part of `shuffle`: a Ripple Delete of the range of `clip` on `track`, its own track. It
    /// names the track, so a follow track edits too (decision 0073). A Shuffle drag calls this once. A
    /// throw changes nothing.
    package mutating func shuffleClose(_ clip: Clip, on track: TrackID) throws(SessionError) {
        try rippleDelete([clip.range], on: [track], naming: [track])
    }

    /// The part of `shuffle` after the close, on a session where the gap of `clip` is closed: a Ripple
    /// Insert of its length at `start` on `track`, then the clip at `start`. A Shuffle drag closes the gap
    /// once and calls this at each event. A throw changes nothing.
    package mutating func shuffleDrop(_ clip: Clip, to track: TrackID, start: Frames) throws(SessionError) {
        var copy = self
        try copy.rippleInsert(clip.length, at: start, on: [track], naming: [track])
        var moved = clip
        moved.start = start
        try copy.place(moved, on: track)
        self = copy
    }
}
