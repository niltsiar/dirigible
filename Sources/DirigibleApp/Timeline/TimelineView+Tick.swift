import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

extension TimelineScrollView {
    /// Moves the playhead line, or the record head line during a take (`taking`), and draws the
    /// live take. During play and during a take, the follow can turn the page. A play start, a
    /// take start, a shuttle change, or a move of the playhead while stopped with no take (a
    /// seek) ends a hold and shows the head when it is off the page. A head move in a take is not
    /// a seek. The end of a take (the hand-off or a finalize error) moves only the line and keeps
    /// the view. The first tick only takes the state.
    func tick(playhead: Double, playback: Playback, taking: Bool = false) {
        let previous = last
        last = (playhead, playback, taking)
        if taking, let rate = source?.session.sampleRate {
            // The lanes grow a minute at a time, before the follow, so each turn has room.
            let minute = 60 * rate
            holdEnd(Frames((Int(playhead + visibleFrames) / minute + 1) * minute))
        } else if previous?.taking == true {
            // The session can end before the right edge: keep it, so the clip view keeps the origin.
            holdEnd(Frames(Int(origin + visibleFrames)))
        }
        lanes.movePlayhead(to: playhead, taking: taking)
        moveHead()
        overview?.movePlayhead(to: playhead)
        liveTick(head: taking ? Frames(Int(playhead)) : nil)
        guard let model, let previous, taking || !previous.taking else { return }
        let started = taking ? !previous.taking : playback != .stopped && playback != previous.playback
        let seeked = !taking && playback == .stopped && playhead != previous.playhead
        guard taking || playback != .stopped || seeked else { return }
        var state = model.timeline
        if started || seeked { state.followHeld = false }
        let direction: Shuttle.Direction
        if case .playing(let shuttle) = playback { direction = shuttle.direction } else { direction = .forward }
        let turn = state.follow(
            playhead: Frames(Int(playhead)), origin: origin, frames: visibleFrames, direction: direction)
        // Only a change: a write of the model makes SwiftUI update the views that read it.
        if state.followHeld != model.timeline.followHeld { model.timeline.followHeld = state.followHeld }
        if state.headLeftView != model.timeline.headLeftView { model.timeline.headLeftView = state.headLeftView }
        if let turn, liveScrollOrigin == nil { scroll(toFrame: turn) }
    }
}
