import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// The result of the last Level Over Time, for its banner: the clips that got a ride, the clips
/// with no level to measure, and the largest gain of the rides in whole dB, with its sign.
struct RideResult: Equatable {
    let leveled: Int
    let unmeasured: Int
    let gain: Int
}

extension RideResult {
    init(_ report: RideReport) {
        self.init(
            leveled: report.leveled.count, unmeasured: report.unmeasured.count,
            gain: Int((report.largestGain?.dB ?? 0).rounded()))
    }
}

/// The result of the last Level Over Time, the session revision after it, and the number of its
/// run, so each run gives a new banner key.
struct RideReportShown: Equatable {
    let result: RideResult
    let revision: Int
    let press: Int
}

/// Tools > Level Over Time (Shift-Command-L) and Tools > Remove Level Over Time. Neither opens a
/// sheet.
extension SessionWindow {
    /// Rides the clips of the selection, whatever their track roles, as one undo step. A selection
    /// with no clip beeps. With a dialog, it does nothing. The banner Cancel shows no alert, and
    /// VoiceOver says the cancel text.
    func levelOverTime() async {
        guard importJob == nil, !dialogShowing, let studio = idleStudio else { return }
        let clips = denoiseClips(in: studio.session)
        guard !clips.isEmpty else { return beep() }
        rideReport = nil
        commitDrafts()
        do throws(StudioError) {
            let report = try await studio.levelOverTime(Set(clips), agent: nil)
            let result = RideResult(report)
            guard result.leveled > 0 || result.unmeasured > 0 else { return }
            ridePresses += 1
            rideReport = RideReportShown(result: result, revision: studio.sessionRevision, press: ridePresses)
        } catch .rideCancelled {
            chrome?.announce(L10n.rideCanceled.text, .medium)
        } catch {
            alert = .error(error)
        }
    }

    /// Removes the ride of the clips that `removeRideTarget` names, as one undo step. A selection
    /// with no ridden clip beeps.
    func removeLevelOverTime() {
        guard importJob == nil, !dialogShowing, let studio = idleStudio else { return }
        let target = removeRideTarget(in: studio.session)
        guard !target.clips.isEmpty else { return beep() }
        do throws(StudioError) {
            try studio.removeLevelOverTime(target.clips, in: target.range, agent: nil)
        } catch {
            alert = .error(error)
        }
    }

    /// The ridden clips that Remove Level Over Time acts on, and the time range. A selection with
    /// a time range gives the range and the ridden clips of its tracks (all tracks with none) that
    /// play the range widened by the 500 ms ramp of the remove. Another selection gives its clips
    /// of Auto Level and no range.
    func removeRideTarget(in session: Session) -> (clips: Set<ClipID>, range: Range<Frames>?) {
        let ridden = { (clips: Set<ClipID>) in
            clips.filter { session.clip($0)?.clip.ride.isEmpty == false }
        }
        guard case .range(let marks) = timeline.selection, let low = marks.inPoint, let high = marks.outPoint,
            low < high
        else {
            return (ridden(timeline.selection.clipsToLevel(in: session) ?? []), nil)
        }
        let widened = max(0, low - session.gainRamp)..<(high + session.gainRamp)
        let tracks = session.tracks.filter { marks.tracks.isEmpty || marks.tracks.contains($0.id) }
        let touching = Set(tracks.flatMap { $0.clips.filter { widened.overlaps($0.range) }.map(\.id) })
        return (ridden(touching), low..<high)
    }
}
