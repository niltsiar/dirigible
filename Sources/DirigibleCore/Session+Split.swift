import Foundation

/// A channel of a stereo file (decision 0053).
public enum Side: String, Hashable, Sendable { case left, right }

/// The two mono files of one run of a split, by their stems: the file ID, and the path "<stem>.wav"
/// in `Clips/`. Each file holds `run.span` of the source file, one channel.
public struct MonoPair: Hashable, Sendable {
    public let run: ClipRun
    public let leftStem: String
    public let rightStem: String

    public init(run: ClipRun, leftStem: String, rightStem: String) {
        self.run = run
        self.leftStem = leftStem
        self.rightStem = rightStem
    }
}

/// A clip that a split replaced, and the clips and tracks that took its place.
public struct SplitPart: Hashable, Sendable {
    public let source: ClipID
    public let left: ClipID
    public let right: ClipID
    public let leftTrack: TrackID
    public let rightTrack: TrackID
}

extension Session {
    /// Splits the stereo clips of `pairs` (decision 0053). The caller writes the mono files and gives
    /// their stems. For each source track with a clip in `pairs`, two mono tracks go under it, named
    /// "<name> <names.left>" and "<name> <names.right>". They copy its gain, mute, solo, and role, and
    /// have no route. Each source clip becomes a left clip and a right clip with the same start,
    /// length, gain, and fades. The offset is the old offset minus the start of its run, and the
    /// envelope keeps its gain at each source frame (decision 0060). A crossfade stays when its
    /// partner is split too. The clip IDs are "<id> L" and "<id> R", then " 2", " 3" when taken.
    /// The source clips go, and the source tracks and files stay. The parts are by source track in
    /// session order, then by clip start.
    ///
    /// The pairs must be the runs that `clipRuns(of:)` gives for the clips of all pairs, else it
    /// throws `.frameOutOfRange`. A clip on a mono track throws `.notStereo`. A stem that a file of
    /// the pool has, an ID or a path, and each other refusal of `addDerivedFile` throw too. A throw
    /// changes nothing, so a caller runs it before it writes a file.
    public mutating func splitStereo(_ pairs: [MonoPair], names: (left: String, right: String)) throws(SessionError)
        -> [SplitPart]
    {
        var copy = self
        let parts = try copy.splitting(pairs, names: names)
        self = copy
        return parts
    }

    /// Throws `.notStereo` for the first of `clips` on a track that is not stereo. A split calls it
    /// before any check of the disk, the files, or the transcripts.
    package func checkStereo(_ clips: [ClipID]) throws(SessionError) {
        let mono = Set(tracks.lazy.filter { $0.layout != .stereo }.flatMap(\.clips).map(\.id))
        if let id = clips.first(where: mono.contains) { throw .notStereo(id) }
    }

    /// The mono files of the run of a moved clip, and the start and length of the run.
    private struct Placement {
        let left: FileID
        let right: FileID
        let spanStart: Frames
        let spanLength: Frames
    }

    private mutating func splitting(_ pairs: [MonoPair], names: (left: String, right: String))
        throws(SessionError) -> [SplitPart]
    {
        let runs = try clipRuns(of: pairs.flatMap(\.run.clips))
        guard runs.count == pairs.count, Set(runs) == Set(pairs.map(\.run)) else { throw .frameOutOfRange }
        try checkStereo(pairs.flatMap(\.run.clips))
        var placements: [ClipID: Placement] = [:]
        for pair in pairs {
            let left = try addDerivedFile(from: pair.run, stem: pair.leftStem, layout: .mono)
            let right = try addDerivedFile(from: pair.run, stem: pair.rightStem, layout: .mono)
            let span = pair.run.span
            for id in pair.run.clips {
                placements[id] = Placement(
                    left: left, right: right, spanStart: span.lowerBound, spanLength: span.upperBound - span.lowerBound)
            }
        }
        let sources = tracks.filter { $0.clips.contains { placements[$0.id] != nil } }

        var taken = clipIDs
        var parts: [SplitPart] = []
        for source in sources {
            var sides = [(Side.left, names.left), (.right, names.right)].map { side, name in
                var track = Track(id: TrackID(), name: "\(source.name) \(name)", layout: .mono)
                (track.gain, track.isMuted, track.isSoloed, track.role) =
                    (source.gain, source.isMuted, source.isSoloed, source.role)
                return (side: side, track: track, clips: [Clip]())
            }
            try Self.checkText(sides[0].track.name, sides[1].track.name)
            for clip in source.clips {
                guard let placement = placements[clip.id] else { continue }
                var ids: [ClipID] = []
                for index in sides.indices {
                    let side = sides[index].side
                    let moved = Self.monoClip(
                        of: clip, side: side, placement: placement, id: Self.sideID(of: clip.id, side, &taken))
                    try check(moved, on: sides[index].track)
                    sides[index].clips.append(moved)
                    ids.append(moved.id)
                }
                parts.append(
                    SplitPart(
                        source: clip.id, left: ids[0], right: ids[1], leftTrack: sides[0].track.id,
                        rightTrack: sides[1].track.id))
            }
            let index = try trackIndex(source.id)
            tracks[index].clips.remove(ids: Set(source.clips.lazy.map(\.id).filter { placements[$0] != nil }))
            for side in sides.indices {
                sides[side].track.clips.insert(sorted: sides[side].clips)
            }
            tracks.insert(contentsOf: sides.map(\.track), at: index + 1)
        }
        return parts
    }

    /// The clip on one side: the file of the side, the offset in the run file, and the envelope at
    /// the frames of that file. The edge rule of decision 0060 keeps its gain at the edges of the run.
    private static func monoClip(of clip: Clip, side: Side, placement: Placement, id: ClipID) -> Clip {
        Clip(
            id: id, file: side == .left ? placement.left : placement.right, start: clip.start,
            offset: clip.offset - placement.spanStart, length: clip.length, gain: clip.gain, fades: clip.fades,
            crossfades: clip.crossfades,
            envelope: clip.envelope.moved(by: .zero - placement.spanStart, fileLength: placement.spanLength))
    }

    /// "<id> L" or "<id> R", else the first free one of "<id> L 2", "<id> L 3", and so on. It goes
    /// into `taken`.
    private static func sideID(of id: ClipID, _ side: Side, _ taken: inout Set<ClipID>) -> ClipID {
        let base = "\(id.rawValue) \(side == .left ? "L" : "R")"
        var candidate = ClipID(base)
        var number = 2
        while taken.contains(candidate) {
            candidate = ClipID("\(base) \(number)")
            number += 1
        }
        taken.insert(candidate)
        return candidate
    }
}
