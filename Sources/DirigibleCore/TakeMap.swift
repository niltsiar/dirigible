import Foundation

/// The signed difference `to - from` in nanoseconds. Every host-time difference uses it, so a
/// first frame before the take start gives a negative value, not a trap.
package func nanos(from: UInt64, to: UInt64) -> Int64 { Int64(bitPattern: to &- from) }

extension Capture {
    /// The timeline frame of file frame 0 at `sampleRate`, the take anchor of decision 0004
    /// (**Timing**): the playhead, plus the host time from the take start to the first frame,
    /// minus the latency at the nominal device rate, each rounded at `sampleRate`. Nil when the
    /// sum is not an `Int`. Finalize and `TakeMap` both use it, so the two never differ.
    public func alignedStart(in recording: Recording, sampleRate: Int) -> Int? {
        let rate = Double(sampleRate)
        let latency = (Double(latency) * rate / nominalSampleRate).rounded()
        let hostOffset =
            (Double(nanos(from: recording.takeStartHostTimeNanos, to: hostTimeNanos)) * rate / 1e9).rounded()
        return Int(exactly: Double(recording.playheadFrame.count) + hostOffset - latency)
    }
}

/// The take time of the capture files of a session, and where each take frame is on the timeline
/// (decision 0061). The take time of a frame is its time from the record start of its own take, at
/// the session rate. The map uses the file range of each clip, not its crossfade handles.
public struct TakeMap: Sendable {
    /// Where file frame 0 of a capture file is in the take time of `take`.
    public struct Origin: Hashable, Sendable {
        public let take: Int
        public let frame: Int
    }

    /// A timeline frame on a track.
    public struct Place: Hashable, Sendable {
        public let track: TrackID
        public let frame: Frames
    }

    /// A frame in the take time of `take`.
    public struct TakeTime: Hashable, Sendable {
        public let take: Int
        public let frame: Int
    }

    /// A clip of a file with take time.
    struct Piece: Sendable {
        let track: TrackID
        /// The index of `track` in the session.
        let order: Int
        let clip: Clip
        let origin: Origin
        /// The take frame of the first clip frame.
        var first: Int { origin.frame + clip.offset.count }
        /// The take frames that the clip plays: the one owner of the take range of a clip.
        var takeRange: Range<Int> { first..<(first + clip.length.count) }
        /// The timeline frame of take time 0.
        var shift: Int { clip.start.count - first }
    }

    /// The origin of each file that has take time.
    public let origins: [FileID: Origin]
    /// The state of each take with audio, a take with a clip of a file that has an origin. Empty:
    /// the session has no take audio.
    public let sync: [Int: TakeSync]
    /// In timeline order: by start, then by track order.
    private let pieces: [Piece]

    /// The origin of a finalized file is inside this bound, so the sums of the map cannot overflow.
    private static let originBound = 2 * Frames.limit.count
    /// Each take frame that the map can give: an origin plus a file frame.
    public static let takeFrames = -originBound...(originBound + Frames.limit.count)

    /// `recordings` holds the take anchor of each capture. A file has an origin when its capture ID
    /// equals its file ID, and a rendered file has the origin of its root plus the sum of the origin
    /// offsets (decision 0057). So an import, a paste from another package, and a split file have
    /// none. An origin outside `originBound` comes from a damaged `session.xml` and is no take time.
    public init(_ session: Session, recordings: [CaptureID: Recording]) {
        let bound = Self.originBound
        var origins: [FileID: Origin] = [:]
        for file in session.files.values {
            guard file.isTakeFile, let id = file.capture, let capture = session.captures[id],
                let recording = recordings[id]
            else { continue }
            // The aligned start with the playhead at 0: the take time of file frame 0.
            var takeStart = recording
            takeStart.playheadFrame = .zero
            guard let frame = capture.alignedStart(in: takeStart, sampleRate: session.sampleRate),
                (-bound...bound).contains(frame)
            else { continue }
            origins[file.id] = Origin(take: recording.take, frame: frame)
        }
        for file in session.files.values where file.origin != nil {
            let root = session.root(of: file.id)
            guard let base = origins[root.file] else { continue }
            origins[file.id] = Origin(take: base.take, frame: base.frame + root.offset.count)
        }
        let pieces = session.tracks.enumerated().flatMap { order, track in
            track.clips.compactMap { clip in
                origins[clip.file].map { Piece(track: track.id, order: order, clip: clip, origin: $0) }
            }
        }
        .sorted { ($0.clip.start, $0.order) < ($1.clip.start, $1.order) }
        self.origins = origins
        self.pieces = pieces
        sync = Dictionary(grouping: pieces, by: \.origin.take).mapValues(TakeSync.init)
    }

    /// The places that play take frame `frame` of `take`, one for each clip whose take range holds
    /// it, in timeline order. Empty: an edit removed that audio, or the take has none.
    public func timeline(atTake frame: Int, take: Int) -> [Place] {
        playing(atTake: frame, take: take)
            .map { (place: Place(track: $0.track, frame: $0.clip.start + Frames(frame - $0.first)), order: $0.order) }
            .sorted { ($0.place.frame, $0.order) < ($1.place.frame, $1.order) }.map(\.place)
    }

    /// The clips of `take` whose take range holds take frame `frame`, in timeline order, on `track`
    /// or on any track when `track` is nil.
    func playing(atTake frame: Int, take: Int, on track: TrackID? = nil) -> [Piece] {
        pieces.filter {
            $0.origin.take == take && $0.takeRange.contains(frame) && (track == nil || $0.track == track)
        }
    }

    /// The take time of the clip under `frame` on `track`, or nil for a gap or a clip of a file
    /// with no take time.
    public func take(atTimeline frame: Frames, on track: TrackID) -> TakeTime? {
        pieces.first { $0.track == track && $0.clip.range.contains(frame) }.map {
            TakeTime(take: $0.origin.take, frame: $0.first + (frame - $0.clip.start).count)
        }
    }
}

/// The sync state of one take with audio (decision 0061). The shift of a clip is the timeline
/// frame of take time 0. 0 frames of tolerance: a shift that differs by 1 frame is another shift.
/// The reference shift is the shift of the most clip frames (a tie: the shift of the earliest
/// clip). A clip at another shift is a copy (for example a cold open) when the clips at the
/// reference shift on its track play each frame of its take range. A copy is not a break.
public enum TakeSync: Hashable, Sendable {
    /// Every clip of the take that is not a copy has the shift `offset`.
    case inSync(offset: Int)
    /// `from` is the earliest start of a clip that is not a copy and whose shift differs from the
    /// shift of the first such clip of the take; `shifts` counts the shifts of these clips.
    case broken(from: Frames, shifts: Int)

    /// The pieces of one take, in timeline order; never empty.
    fileprivate init(_ pieces: [TakeMap.Piece]) {
        var frames: [Int: Int] = [:]
        for piece in pieces { frames[piece.shift, default: 0] += piece.clip.length.count }
        let reference = pieces.reduce(pieces[0].shift) {
            frames[$1.shift, default: 0] > frames[$0, default: 0] ? $1.shift : $0
        }
        let played = Dictionary(grouping: pieces.filter { $0.shift == reference }, by: \.track)
        let kept = pieces.filter { $0.shift == reference || !Self.play(played[$0.track] ?? [], all: $0) }
        let first = kept[0].shift
        if let other = kept.first(where: { $0.shift != first }) {
            self = .broken(from: other.clip.start, shifts: Set(kept.map(\.shift)).count)
        } else {
            self = .inSync(offset: first)
        }
    }

    /// Whether `pieces`, pieces of one shift in timeline order, play each take frame of `piece`.
    private static func play(_ pieces: [TakeMap.Piece], all piece: TakeMap.Piece) -> Bool {
        let end = piece.takeRange.upperBound
        var next = piece.first
        for other in pieces where other.first <= next {
            next = max(next, other.takeRange.upperBound)
            if next >= end { return true }
        }
        return false
    }

    /// A change of the state of one take.
    public struct Change: Hashable, Sendable {
        public let take: Int
        public let old: TakeSync
        public let new: TakeSync
    }

    /// The one rule of a transition: one entry, in take order, for each take in both lists whose
    /// state changes class or whose `inSync` offset changes. From `broken` to `broken` gives none.
    /// A take in only one list gives none, so a new take or a removed take is no transition.
    public static func change(from old: [Int: TakeSync], to new: [Int: TakeSync]) -> [Change] {
        old.keys.sorted().compactMap { take in
            guard let before = old[take], let after = new[take] else { return nil }
            switch (before, after) {
            case (.broken, .broken): return nil
            case (.inSync(let a), .inSync(let b)) where a == b: return nil
            default: return Change(take: take, old: before, new: after)
            }
        }
    }
}
