import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// Edit > Close Gaps, Roll Edit to Playhead, Slip Content Left, and Slip Content Right (decision
/// 0036). None is a ripple, so each runs under a pending or split take. Each is one edit, so one
/// undo entry. A command that changes no clip beeps and makes no undo entry. During a take, nothing.
extension SessionWindow {
    func runTrim(_ command: TimelineCommand, _ studio: Studio) {
        guard canEdit else { return }
        let session = studio.session
        let clips = timeline.selection.selectedClips(in: session).map(\.clip.id)
        switch command {
        case .closeGaps:
            let moved = edit(ripple: false) { s throws(SessionError) in try s.closeGaps(clips) }
            if moved?.isEmpty == true { beep() }
        case .rollToPlayhead:
            let joins = timeline.selection.rollJoins(to: studio.playhead, in: session)
            guard !joins.isEmpty else { return beep() }
            edit(ripple: false) { s throws(SessionError) in
                for join in joins { try s.roll(join.left, by: join.by) }
            }
        case .slipLeft, .slipRight:
            // The audio moves left under the clip when the file offset grows.
            let step = session.editStep
            let delta = command == .slipLeft ? step : .zero - step
            let fits = clips.allSatisfy { (try? session.slipLimits($0))?.contains(delta) == true }
            guard !clips.isEmpty, fits else { return beep() }
            edit(ripple: false) { s throws(SessionError) in try s.slip(clips, by: delta) }
        default: return
        }
    }
}
