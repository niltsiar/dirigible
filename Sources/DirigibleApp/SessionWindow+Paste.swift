import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// A paste from the one clipboard of the app (decision 0042). The same package pastes at once, as
/// before; another package runs as a blocking studio run with the banner of an import.
extension SessionWindow {
    /// Paste and Insert. With no clipboard, or no target, nothing. During a take or a run, nothing at
    /// once (`idleStudio`). `.unselected` goes to the studio only for a range with no selected
    /// track: new tracks for another package, the source tracks for the same package. A file that
    /// an undo removed beeps; another refusal shows its alert. After the paste, the selection is
    /// the pasted range, or the pasted clips for a set excerpt.
    func paste(insert: Bool) {
        guard let studio = idleStudio, let clipboard = app?.clipboard else { return }
        let target: PasteTarget
        if case .range(let marks) = timeline.selection, marks.tracks.isEmpty {
            target = .unselected
        } else if let ids = timeline.selection.pasteTracks(for: clipboard.excerpt, in: studio.session) {
            target = .tracks(ids)
        } else {
            return
        }
        let at = studio.playhead
        do throws(StudioError) {
            if let pasted = try studio.pasteInPlace(clipboard, at: at, on: target, insert: insert) {
                select(pasted, of: clipboard, at: at, in: studio)
                return
            }
        } catch {
            return refused(error)
        }
        let source = app?.studio(of: clipboard.origin)
        // A blocking run: a typed name that waits for it is lost (run 13c, plan gate 2 item 1).
        commitDrafts()
        importJob = ImportJob(visible: false)
        let wait = bannerWait
        let shown = Task { [weak self] in
            await wait()
            guard let self, !Task.isCancelled, importJob != nil else { return }
            importJob?.visible = true
            chrome?.announce(
                L10n.pasteBanner.format(clipboard.package.deletingPathExtension().lastPathComponent), .high)
        }
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                let pasted = try await studio.pasteAcross(clipboard, from: source, at: at, on: target, insert: insert) {
                    [weak self] in self?.importProgressed($0)
                }
                shown.cancel()
                if self?.importJob?.visible == true { self?.chrome?.announce(L10n.pasteDone.text, .high) }
                self?.select(pasted, of: clipboard, at: at, in: studio)
            } catch {
                shown.cancel()
                self?.refused(error)
            }
            self?.importJob = nil
        }
    }

    /// The selection after a paste: the pasted range, or the pasted clips for a set excerpt. At
    /// another rate the range has the scaled length, which does not depend on the file lengths.
    private func select(
        _ pasted: (clips: [ClipID], tracks: [TrackID]), of clipboard: Clipboard, at: Frames, in studio: Studio
    ) {
        guard !pasted.clips.isEmpty else { return }
        let rate = studio.session.sampleRate
        let excerpt =
            clipboard.excerpt.sampleRate == rate
            ? clipboard.excerpt : clipboard.excerpt.resampled(to: rate, lengths: [:])
        timeline.selection = Selection(pasted: pasted.clips, of: excerpt, at: at, on: pasted.tracks)
    }

    /// A refused paste: a beep for a file that an undo removed or a ripple under a pending or split
    /// take, nothing for a cancel, else the alert.
    private func refused(_ error: StudioError) {
        switch error {
        case .session(.unknownFile), .rippleBlocked: beep()
        case .paste(.cancelled, _): break
        default: alert = .error(error)
        }
    }
}
