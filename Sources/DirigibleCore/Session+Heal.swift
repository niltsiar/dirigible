import Foundation

extension Session {
    /// Joins each pair of clips that play on in one file at one gain at each frame, the envelope
    /// included, and touch, with no fade at the join, so the sound stays: the undo of a split. A
    /// heal goes left to right, so three pieces become one clip. A join is in `range` when its
    /// timeline frame is in `range`, the upper bound too. `tracks` nil is all tracks. The result
    /// keeps the ID of the left piece and gives the ID of each healed clip. A heal of no join throws
    /// `.nothingToHeal`, an unknown track `.unknownTrack`; a throw changes nothing.
    @discardableResult
    public mutating func heal(tracks: [TrackID]? = nil, range: ClosedRange<Frames>? = nil) throws(SessionError)
        -> [ClipID]
    {
        let targets: [Int]
        if let tracks { targets = try trackIndices(tracks) } else { targets = Array(self.tracks.indices) }
        var lanes = self.tracks
        var healed: [ClipID] = []
        for track in targets {
            var index = 0
            while index + 1 < lanes[track].clips.count {
                let lane = lanes[track].clips
                guard lane.canHeal(after: index), range?.contains(lane[index + 1].start) ?? true else {
                    index += 1
                    continue
                }
                if healed.last != lane[index].id { healed.append(lane[index].id) }
                lanes[track].clips.heal(at: index)
            }
        }
        guard !healed.isEmpty else { throw .nothingToHeal }
        self.tracks = lanes
        return healed
    }
}
