import CoreAudio
import DirigibleCore

/// The live peaks of the takes (live take view). Not observed: the timeline reads the version and
/// the epoch at each display tick, so a report does not make SwiftUI compare the bins.
struct LiveStore {
    /// The bins of each armed track of the take, until the hand-off or a finalize error.
    var tracks: [TrackID: LivePeaks] = [:]
    /// The track of each arm of the take. `stop` empties `armed`; this map stays, so the final
    /// drains find their tracks.
    var arms: [Int: TrackID] = [:]
    /// The bins of each take file after its hand-off, and the timeline frame of its file frame 0
    /// at the hand-off. An entry stays until a later hand-off finds its file peaks ready or
    /// unavailable, or its file out of the session.
    var files: [FileID: (peaks: LivePeaks, anchor: Frames)] = [:]
    /// One more for each add that wrote bins.
    var version = 0
    /// One more for each other change: a take start, a hand-off, and a finalize error.
    var epoch = 0
    /// The host time of the stop of the take that finalizes. Nil at other times.
    var stopHostNanos: UInt64?
}

extension Studio {
    public var liveVersion: Int { live.version }
    public var liveEpoch: Int { live.epoch }

    public func livePeaks(of track: TrackID) -> LivePeaks? { live.tracks[track] }

    public func livePeaks(file: FileID) -> (peaks: LivePeaks, anchor: Frames)? { live.files[file] }

    /// The file map: the live peaks of each take file after its hand-off, with its anchor.
    public var liveFiles: [FileID: (peaks: LivePeaks, anchor: Frames)] { live.files }

    /// The lowest session frame that an add touched since the last call, over all tracks of the
    /// take (F1). The call clears it, so the timeline draws each late span once.
    public func takeLiveAddedFrom() -> Frames? {
        let lowest = live.tracks.values.compactMap { peaks in peaks.addedFrom.map { peaks.origin + $0 } }.min()
        // A copy of the keys only: an iterator of the dictionary would hold its storage, and the
        // next add would copy the bins.
        for track in Array(live.tracks.keys) { live.tracks[track]?.addedFrom = nil }
        return lowest
    }

    /// The record head now.
    public func liveHead() -> Frames? { liveHead(atHostNanos: hostNanosNow()) }

    /// The record head at host time `time`: the take playhead plus the time since the take start
    /// while the take records. While the take that this studio stopped finalizes, it is the
    /// larger of the head at the stop and the last covered frame, so the head takes the tail of
    /// the final drains. Nil at other times, also during a retry of the finalize.
    public func liveHead(atHostNanos time: UInt64) -> Frames? {
        guard let recording = session.recording else { return nil }
        func head(_ time: UInt64) -> Frames {
            let since = Double(nanos(from: recording.takeStartHostTimeNanos, to: time))
            return recording.playheadFrame + Frames(Int((since * Double(session.sampleRate) / 1e9).rounded()))
        }
        switch transport {
        case .recording: return head(time)
        case .finalizing:
            guard let stop = live.stopHostNanos else { return nil }
            let covered = live.tracks.values.compactMap { peaks in
                peaks.covered.last.map { $0.upperBound + peaks.origin }
            }
            return max(head(stop), covered.max() ?? .zero)
        default: return nil
        }
    }

    /// Adds the written span of one arm to the bins of its track. `apply(.levels)` calls it for
    /// each arm; the bench of the timeline calls it directly. `now` is the host time of the call.
    func addLive(track: TrackID, level: ArmLevel, latencyNanos: Int64, now: UInt64) {
        guard let span = level.written else { return }
        let added = live.tracks[track]?.add(
            peak: level.peak, rms: level.rms, span: span, latencyNanos: latencyNanos, now: now)
        if added == true { live.version += 1 }
    }

    /// At the take start: new bins for each armed track and a new arm map. The file map stays.
    func beginLive(_ started: StartedTake) {
        let recording = started.session.recording
        live.tracks = Dictionary(
            uniqueKeysWithValues: started.routes.map {
                (
                    $0.track,
                    LivePeaks(
                        origin: recording?.playheadFrame ?? .zero,
                        startHostNanos: recording?.takeStartHostTimeNanos ?? 0, rate: started.session.sampleRate)
                )
            })
        live.arms = Dictionary(uniqueKeysWithValues: started.routes.map { ($0.arm, $0.track) })
        live.stopHostNanos = nil
        live.epoch += 1
    }

    /// At the stop: the head freezes at this host time until the hand-off or a finalize error.
    func stopLive() {
        live.stopHostNanos = hostNanosNow()
    }

    /// A finalize error: the bins of the take go. The file map stays.
    func dropLiveTake() {
        live.tracks = [:]
        live.stopHostNanos = nil
        live.epoch += 1
    }

    /// The hand-off of a finalize that succeeds, before the session changes to `finalized`. Each
    /// new file gets the bins of its track and the anchor `clip.start - clip.offset` of its first
    /// clip. The entries whose file peaks are ready or unavailable, or whose file is not in
    /// `finalized`, go.
    func handOffLive(_ finalized: Session) {
        live.files = live.files.filter { id, _ in
            guard finalized.files[id] != nil else { return false }
            switch peaks[id] {
            case .ready, .unavailable: return false
            case .computing, nil: return true
            }
        }
        for track in finalized.tracks {
            guard let peaks = live.tracks[track.id] else { continue }
            for clip in track.clips where session.files[clip.file] == nil && live.files[clip.file] == nil {
                live.files[clip.file] = (peaks, clip.start - clip.offset)
            }
        }
        live.tracks = [:]
        live.stopHostNanos = nil
        live.epoch += 1
    }
}

/// The host clock of the take anchor (`prepareTake`), in nanoseconds.
func hostNanosNow() -> UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }
