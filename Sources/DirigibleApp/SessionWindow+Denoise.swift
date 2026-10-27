import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// Tools > Reduce Noise (decision 0054): a blocking studio run with the banner of an import after
/// 0.5 s, as a split. Each clip of the selection that sits on a track with no role or the dialogue
/// role moves onto a new file with the noise taken out, in one undo entry.
extension SessionWindow {
    static let denoiseTreatment = Treatment(.noise(.standard))

    /// The clips that Reduce Noise takes: the clips of `Selection.clipsToLevel(in:)` on a track whose
    /// role `Treatment.accepts`. An empty selection has none.
    func denoiseClips(in session: Session) -> [ClipID] {
        guard let selected = timeline.selection.clipsToLevel(in: session) else { return [] }
        return session.tracks.filter { Self.denoiseTreatment.accepts($0.role) }
            .flatMap { $0.clips.map(\.id) }.filter(selected.contains)
    }

    /// Reduces the noise of the clips that it takes. A selection with no such clip beeps. A render
    /// that runs past the banner wait shows the banner with the progress and Cancel. A cancel
    /// changes no clip, shows no alert, and VoiceOver reads the cancel text; another error shows
    /// its alert. At the end, a result banner shows until the next change of the session.
    func reduceNoise() {
        guard importJob == nil, let studio = idleStudio else { return }
        let clips = denoiseClips(in: studio.session)
        guard !clips.isEmpty else { return beep() }
        // A blocking run: a typed name that waits for it is lost (run 13c, plan gate 2 item 1).
        commitDrafts()
        importJob = ImportJob(visible: false)
        let wait = bannerWait
        let shown = Task { [weak self] in
            await wait()
            guard let self, !Task.isCancelled, importJob != nil else { return }
            importJob?.visible = true
        }
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                let report = try await studio.renderClips(clips, treatment: Self.denoiseTreatment) { [weak self] in
                    self?.importProgressed($0)
                }
                shown.cancel()
                self?.showDenoiseReport(report, revision: studio.sessionRevision)
            } catch .clipRender(.cancelled) {
                shown.cancel()
                self?.chrome?.announce(L10n.denoiseCanceled.text, .medium)
            } catch {
                shown.cancel()
                self?.alert = .error(error)
            }
            self?.importJob = nil
        }
    }

    private func showDenoiseReport(_ report: ClipRenderReport, revision: Int) {
        guard let noise = report.noise else { return }
        denoisePresses += 1
        denoiseReport = DenoiseReportShown(
            clips: report.clips.count, decibels: noise.decibels, revision: revision, press: denoisePresses)
    }
}
