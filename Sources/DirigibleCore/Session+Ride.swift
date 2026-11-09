import Foundation

/// A part of the file frames of a measure group, with the envelope of a clip that plays it.
package struct RideWindow: Hashable, Sendable {
    package let frames: Range<Frames>
    package let envelope: GainEnvelope
}

/// One measure group of Level Over Time (leveler C7c): clips of one file whose windows touch or
/// overlap, with equal clip gains. The ride reads `frames` once and writes one list on `written`.
package struct RideGroup: Hashable, Sendable {
    package let file: FileID
    /// File frames: the union of the windows, with no gap.
    package let frames: Range<Frames>
    /// The measured clips, in track and clip order.
    package let clips: [ClipID]
    /// The selected clips of `clips`: only they get the list.
    package let written: [ClipID]
    /// Disjoint and ascending, they cover `frames`. Where two windows overlap, their envelopes are
    /// equal (else `rideGroups` splits the group), so each part keeps the envelope of one of them.
    package let windows: [RideWindow]

    /// The envelope gain in dB at `frame`: the envelope of the clip whose window holds it, 0 outside
    /// `frames`.
    package func envelopeGain(at frame: Frames) -> Double {
        var (low, high) = (windows.startIndex, windows.endIndex)
        while low < high {
            let middle = (low + high) / 2
            if windows[middle].frames.upperBound <= frame { low = middle + 1 } else { high = middle }
        }
        guard low < windows.endIndex, windows[low].frames.contains(frame) else { return 0 }
        return windows[low].envelope.gain(at: frame)
    }
}

extension Session {
    /// The measure groups of `selected` (leveler C7c). A group holds the clips of one file whose
    /// windows touch or overlap and whose clip gains are equal, selected or not. When two clips of a
    /// group play one file frame with envelopes that differ there, one of them leaves: the clip on
    /// the track with fewer frames of the group, on equal frames the later track, on one track the
    /// later clip. Then the clips that stay and the clips that left form groups again by these
    /// rules. Only the groups with a selected clip return, by file and first frame. An unknown ID
    /// throws `.unknownClip`.
    package func rideGroups(_ selected: Set<ClipID>) throws(SessionError) -> [RideGroup] {
        let found = Set(tracks.lazy.flatMap(\.clips).map(\.id))
        if let missing = selected.subtracting(found).sorted().first { throw .unknownClip(missing) }
        var members: [RideMember] = []
        let selectedFiles = Set(tracks.lazy.flatMap(\.clips).filter { selected.contains($0.id) }.map(\.file))
        for (track, lane) in tracks.enumerated() {
            for (index, clip) in lane.clips.enumerated() where selectedFiles.contains(clip.file) {
                members.append(RideMember(clip: clip, track: track, index: index))
            }
        }
        return RideMember.groups(of: members)
            .filter { $0.contains { selected.contains($0.clip.id) } }
            .map { group in
                let ordered = group.sorted { ($0.track, $0.index) < ($1.track, $1.index) }
                return RideGroup(
                    file: ordered[0].clip.file, frames: RideMember.union(group), clips: ordered.map(\.clip.id),
                    written: ordered.map(\.clip.id).filter(selected.contains), windows: RideMember.windows(of: group))
            }
            .sorted { ($0.file, $0.frames.lowerBound) < ($1.file, $1.frames.lowerBound) }
    }

    /// Sets the ride layer of each clip in one pass over the lanes. Each clip passes `check`.
    /// `.empty` removes it. An unknown ID throws `.unknownClip`. A throw changes nothing.
    package mutating func setRides(_ rides: [ClipID: GainEnvelope]) throws(SessionError) {
        var lanes = tracks
        var found = 0
        for track in lanes.indices {
            for index in lanes[track].clips.indices {
                guard let new = rides[lanes[track].clips[index].id] else { continue }
                var clip = lanes[track].clips[index]
                clip.ride = new
                try check(clip, on: lanes[track])
                lanes[track].clips.replace(at: index, with: clip)
                found += 1
            }
        }
        if found < rides.count, let missing = rides.keys.sorted().first(where: { clip($0) == nil }) {
            throw .unknownClip(missing)
        }
        tracks = lanes
    }

    /// Remove Level Over Time on the clip set `clips` (leveler C32). With `range` nil, the ride layer
    /// of each clip of the set is empty. With `range` (timeline frames), on the file map of each
    /// clip of the set that plays a frame of `range` or of its ramps: 0 dB on `range`, a ramp of
    /// `ramp` frames (linear in dB) outside each edge to the old ride, and the old points outside.
    /// The clips with one old list and one file map share the new list. A clip that the remove does
    /// not change gets the new list of its old list when exactly one new list has that old list and
    /// the clip plays no file frame that it changes, so it hears no change. It returns the clips
    /// whose ride changed, in track and clip order. An unknown clip throws `.unknownClip`, a bound
    /// or a ramp outside `0...Frames.limit` `.frameOutOfRange`. A throw changes nothing.
    package mutating func removeRides(_ clips: Set<ClipID>, in range: Range<Frames>?, ramp: Frames)
        throws(SessionError) -> [ClipID]
    {
        let found = Set(tracks.lazy.flatMap(\.clips).map(\.id))
        if let missing = clips.subtracting(found).sorted().first { throw .unknownClip(missing) }
        let ridden = tracks.flatMap(\.clips).filter { clips.contains($0.id) && !$0.ride.isEmpty }
        guard let range else {
            try setRides(Dictionary(uniqueKeysWithValues: ridden.map { ($0.id, GainEnvelope.empty) }))
            return ridden.map(\.id)
        }
        guard range.lowerBound.isInRange, range.upperBound.isInRange, ramp.isInRange else { throw .frameOutOfRange }
        guard !range.isEmpty else { return [] }
        let ramp = max(ramp.count, 1)
        let (low, high) = (range.lowerBound.count, range.upperBound.count - 1)
        var maps = RideMaps()
        // Each new list with its old list and the open file frames where it differs from it.
        var made: [(old: GainEnvelope, new: GainEnvelope, changed: Range<Int>)] = []
        var rides: [ClipID: GainEnvelope] = [:]
        for clip in ridden where clip.soundingRange.overlaps(Frames(low - ramp + 1)..<Frames(high + ramp)) {
            guard let file = files[clip.file] else { throw .unknownFile(clip.file) }
            let shift = clip.start.count - clip.offset.count
            let new = maps.map(clip.ride, FileMap(shift: Frames(shift), length: file.length)) {
                $0.removed(low: low - shift, high: high - shift, ramp: ramp, fileLength: file.length)
            }
            guard new != clip.ride else { continue }
            rides[clip.id] = new
            if !made.contains(where: { $0.new == new }) {
                made.append((clip.ride, new, (low - shift - ramp + 1)..<(high - shift + ramp)))
            }
        }
        let changed = tracks.flatMap(\.clips).map(\.id).filter { rides[$0] != nil }
        for clip in tracks.flatMap(\.clips) where rides[clip.id] == nil && !clip.ride.isEmpty {
            let lists = made.filter { $0.old == clip.ride }
            let shift = clip.start.count - clip.offset.count
            let plays = (clip.soundingRange.lowerBound.count - shift)..<(clip.soundingRange.upperBound.count - shift)
            if lists.count == 1, !plays.overlaps(lists[0].changed) { rides[clip.id] = lists[0].new }
        }
        try setRides(rides)
        return changed
    }

    /// Gives each clip the ride array of its clip in `other` when the two lists are equal, so the
    /// read-back compare of a save (`checkedData`) returns at the buffer identity (leveler C34).
    /// Each pair of arrays compares once. A list that differs stays, so `==` still finds it.
    mutating func shareRides(of other: Session) {
        var rides: [ClipID: GainEnvelope] = [:]
        for track in other.tracks {
            for clip in track.clips where !clip.ride.isEmpty { rides[clip.id] = clip.ride }
        }
        // The parts of a split clip are next to each other, so the last pair is the usual match.
        var compared: [(read: GainEnvelope, written: GainEnvelope, isEqual: Bool)] = []
        for track in tracks.indices {
            var shared: [(index: Int, clip: Clip)] = []
            for index in tracks[track].clips.indices {
                var clip = tracks[track].clips[index]
                guard let ride = rides[clip.id], !clip.ride.isEmpty else { continue }
                let isEqual: Bool
                if let pair = compared.last(where: {
                    $0.read.sharesPoints(with: clip.ride) && $0.written.sharesPoints(with: ride)
                }) {
                    isEqual = pair.isEqual
                } else {
                    isEqual = clip.ride == ride
                    compared.append((clip.ride, ride, isEqual))
                }
                guard isEqual else { continue }
                clip.ride = ride
                shared.append((index, clip))
            }
            tracks[track].clips.replace(shared)
        }
    }
}

extension GainEnvelope {
    /// True when the two point arrays are one buffer.
    fileprivate func sharesPoints(with other: GainEnvelope) -> Bool {
        points.withUnsafeBufferPointer { mine in
            other.points.withUnsafeBufferPointer { mine.baseAddress == $0.baseAddress }
        }
    }

    /// The list with 0 dB on the file frames `low...high`, the old value at `low - ramp` and at
    /// `high + ramp`, linear in dB between, and the old points outside; fitted to the file.
    fileprivate func removed(low: Int, high: Int, ramp: Int, fileLength: Frames) -> GainEnvelope {
        let (start, end) = (low - ramp, high + ramp)
        let old = points.map { (frame: $0.frame.count, dB: $0.gain.dB) }
        let edges = low == high ? [(frame: low, dB: 0.0)] : [(frame: low, dB: 0.0), (frame: high, dB: 0.0)]
        let held = { (frame: Int) in Self.value(of: old.lazy.map { ($0.frame, $0.dB) }, at: frame) }
        let corners =
            old.filter { $0.frame < start } + [(frame: start, dB: held(start))] + edges
            + [(frame: end, dB: held(end))] + old.filter { $0.frame > end }
        return Self.fitted(corners, fileLength: fileLength)
    }
}

/// A clip of a measure group, with its place in the session.
private struct RideMember {
    let clip: Clip
    let track: Int
    let index: Int

    var window: Range<Frames> { clip.offset..<(clip.offset + clip.length) }

    /// The groups of `members` by the rules of `Session.rideGroups`.
    static func groups(of members: [RideMember]) -> [[RideMember]] {
        var result: [[RideMember]] = []
        for group in touching(members) {
            var (stay, left) = (group, [RideMember]())
            while let leaver = leaver(of: stay) {
                left.append(stay.remove(at: leaver))
            }
            if left.isEmpty {
                result.append(group)
            } else {
                result += groups(of: stay) + groups(of: left)
            }
        }
        return result
    }

    /// The S1 rule: one file, equal clip gains, windows that touch or overlap.
    private static func touching(_ members: [RideMember]) -> [[RideMember]] {
        let byFile = Dictionary(grouping: members, by: \.clip.file)
        var result: [[RideMember]] = []
        for file in byFile.keys.sorted() {
            let byGain = Dictionary(grouping: byFile[file]!, by: \.clip.gain)
            for gain in byGain.keys.sorted(by: { $0.dB < $1.dB }) {
                var end: Frames?
                for member in byGain[gain]!.sorted(by: { $0.clip.offset < $1.clip.offset }) {
                    if let end, member.clip.offset <= end {
                        result[result.count - 1].append(member)
                    } else {
                        result.append([member])
                    }
                    end = max(end ?? .zero, member.window.upperBound)
                }
            }
        }
        return result
    }

    /// The index in `group` of the clip that leaves for the first pair of clips that play one file
    /// frame with envelopes that differ there, nil when no pair does.
    private static func leaver(of group: [RideMember]) -> Int? {
        let order = group.indices.sorted { group[$0].clip.offset < group[$1].clip.offset }
        for (position, a) in order.enumerated() {
            for b in order[(position + 1)...] {
                let (first, second) = (group[a], group[b])
                guard second.clip.offset < first.window.upperBound else { break }
                let shared = second.clip.offset...(min(first.window.upperBound, second.window.upperBound) - Frames(1))
                guard !first.clip.envelope.hasEqualGain(to: second.clip.envelope, in: shared) else { continue }
                func frames(_ track: Int) -> Int {
                    group.lazy.filter { $0.track == track }.map(\.clip.length.count).reduce(0, +)
                }
                let (x, y) = (frames(first.track), frames(second.track))
                if x != y { return x < y ? a : b }
                return (first.track, first.index) > (second.track, second.index) ? a : b
            }
        }
        return nil
    }

    static func union(_ group: [RideMember]) -> Range<Frames> {
        group.map(\.clip.offset).min()!..<group.map(\.window.upperBound).max()!
    }

    static func windows(of group: [RideMember]) -> [RideWindow] {
        var windows: [RideWindow] = []
        var covered = Frames.zero
        for member in group.sorted(by: { $0.clip.offset < $1.clip.offset }) {
            let window = member.window
            guard window.upperBound > covered else { continue }
            windows.append(
                RideWindow(frames: max(window.lowerBound, covered)..<window.upperBound, envelope: member.clip.envelope))
            covered = window.upperBound
        }
        return windows
    }
}
