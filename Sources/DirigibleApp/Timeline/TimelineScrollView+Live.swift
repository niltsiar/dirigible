import AppKit
import DirigibleAudio
import DirigibleCore

/// What the live draw reads apart from the bins and the head: the take, the finalize, and the
/// state of each armed track while the take records. A change draws the lanes in view again.
struct LiveKey: Equatable {
    var take: Int?
    var finalizing = false
    var states: [TrackID: LiveTrack.State] = [:]

    init() {}

    @MainActor init(_ studio: Studio) {
        guard let live = studio.transport.liveTake else { return }
        (take, finalizing) = (live.take, live.finalizing)
        if !live.finalizing { states = studio.liveStates }
    }
}

extension TimelineScrollView {
    /// True from a new epoch until SwiftUI gives the session of the Studio. The hand-off changes
    /// the session in the same turn as the epoch, and SwiftUI gives the new session later. A draw
    /// before it shows neither the live region nor the clips, so the tick and each draw wait.
    var handOffWaits: Bool {
        guard let studio else { return false }
        return studio.liveEpoch != liveSeen.epoch && source?.session != studio.session
    }

    /// The live rule of a tick (live take view, decision 0022). A new store version (an append)
    /// marks the columns from the lowest added frame to the head. A tick with no new version
    /// draws nothing, also when the head moved (probe P1: rate bin). A new epoch (a take start,
    /// the hand-off, a finalize error) or a new live key draws the lanes in view once.
    func liveTick(head: Frames?) {
        guard let studio else { return }
        let key = LiveKey(studio)
        let (version, epoch) = (studio.liveVersion, studio.liveEpoch)
        if epoch != liveSeen.epoch || key != liveSeen.key {
            guard !handOffWaits else { return }
            _ = studio.takeLiveAddedFrom()
            liveSeen = (version, epoch, key)
            lanes.liveChanged(head: head)
            lanes.setAccessibilityValue(
                key.take.map { (key.finalizing ? L10n.takeFinishing : .takeRecording).format($0) })
        } else if version != liveSeen.version, let head {
            liveSeen.version = version
            lanes.liveMoved(head: head, from: studio.takeLiveAddedFrom())
        }
    }
}
