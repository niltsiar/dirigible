import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// A paste from the one clipboard of the app (decision 0042). The same package pastes at once, as
/// before; another package runs as a blocking studio run with the banner of an import.
extension SessionWindow {
    /// Paste, Insert, Replace, and Paste to Fill Selection, by `mode`. With no clipboard, or no
    /// target, nothing. During a take or a run, nothing at once (`idleStudio`). `.unselected` goes
    /// to the studio only for a range with no selected track: new tracks for another package, the
    /// source tracks for the same package, and a new last track for a source track that is gone.
    /// Paste and Insert give a new last track to each lane past the last track; Replace and Paste to
    /// Fill Selection refuse too few tracks. A file that an undo removed beeps; another refusal shows
    /// its alert. What follows a paste is `finish`.
    func paste(mode: PasteMode) {
        guard let studio = idleStudio, let clipboard = app?.clipboard else { return }
        let target: PasteTarget
        if case .range(let marks) = timeline.selection, marks.tracks.isEmpty {
            target = .unselected
        } else if let ids = timeline.selection.pasteTracks(for: clipboard.excerpt, in: studio.session) {
            switch mode {
            case .over, .insert: target = .extending(ids)
            case .replace, .fill: target = .tracks(ids)
            }
        } else {
            return
        }
        do throws(StudioError) {
            if let pasted = try studio.pasteInPlace(clipboard, mode: mode, on: target) {
                finish(pasted, of: clipboard, mode: mode, in: studio)
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
                let pasted = try await studio.pasteAcross(clipboard, from: source, mode: mode, on: target) {
                    [weak self] in self?.importProgressed($0)
                }
                shown.cancel()
                self?.finish(pasted, of: clipboard, mode: mode, in: studio)
            } catch {
                shown.cancel()
                self?.refused(error)
            }
            self?.importJob = nil
        }
    }

    /// The end of a paste. After a Paste or an Insert, the selection is the pasted range, or the
    /// pasted clips for a set excerpt, and a run that showed its banner is announced as done. After a
    /// Replace, the selection is the new range, the playhead is at its start, and VoiceOver hears
    /// the length. After a fill, the range stays and VoiceOver hears the length and the clip count.
    /// At another rate the range has the scaled length, which does not depend on the file lengths.
    private func finish(
        _ pasted: (clips: [ClipID], tracks: [TrackID]), of clipboard: Clipboard, mode: PasteMode, in studio: Studio
    ) {
        let rate = studio.session.sampleRate
        let excerpt =
            clipboard.excerpt.sampleRate == rate
            ? clipboard.excerpt : clipboard.excerpt.resampled(to: rate, lengths: [:])
        switch mode {
        case .over(let at), .insert(let at):
            if importJob?.visible == true { chrome?.announce(L10n.pasteDone.text, .high) }
            guard !pasted.clips.isEmpty else { return }
            timeline.selection = Selection(pasted: pasted.clips, of: excerpt, at: at, on: pasted.tracks)
        case .replace(let range):
            let start = range.lowerBound
            timeline.selection = .range(
                Marks(inPoint: start, outPoint: start + excerpt.length, tracks: Set(pasted.tracks)))
            Task { await studio.perform(.seek(.frame(start))) }
            chrome?.announce(Self.replacedText(clipboard: excerpt.length, rate: rate), .high)
        case .fill(let range):
            chrome?.announce(Self.filledText(range: range, rate: rate, clips: pasted.clips.count), .high)
        }
    }

    /// A refused paste: a beep for a file that an undo removed or a ripple under a pending or split
    /// take, nothing for a cancel, else the alert.
    private func refused(_ error: StudioError) {
        switch error {
        case .session(.unknownFile), .rippleBlocked: beep()
        case .paste(.cancelled, _): break
        default: alert = studio.map { .refusing(error, in: $0.session) } ?? .error(error)
        }
    }
}
