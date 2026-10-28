import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// Tools > Reduce Noise... (decision 0054): the item opens the sheet; its Reduce Noise button is a
/// blocking studio run with the banner of an import after 0.5 s, as a split. Each clip that the
/// treatment of the sheet accepts moves onto a new file, in one undo entry.
extension SessionWindow {
    /// The clips of the selection by the rule of Auto Level (decision 0031), whatever their role,
    /// in track order and then in clip order. An empty selection has none.
    func denoiseClips(in session: Session) -> [ClipID] {
        guard let selected = timeline.selection.clipsToLevel(in: session) else { return [] }
        return session.tracks.flatMap { $0.clips.map(\.id) }.filter(selected.contains)
    }

    /// Opens the sheet on the clips of the selection. A selection with no clip beeps.
    func reduceNoise() {
        guard importJob == nil, denoiseDraft == nil, let studio = idleStudio else { return }
        let clips = denoiseClips(in: studio.session)
        guard !clips.isEmpty else { return beep() }
        commitDrafts()
        denoiseDraft = DenoiseDraft(
            clips: Set(clips), in: studio.session, defaults: app?.defaults, region: Locale.current.region)
    }

    /// Cancel of the sheet: stops the preview and closes the sheet. No clip changes.
    func cancelDenoise() {
        studio?.stopEffectPreview()
        denoiseDraft = nil
    }

    /// Preview of the sheet: loops the first clip that the treatment of `draft` accepts. With no
    /// such clip, or with both check boxes off, it stops the preview. A fault closes the sheet and
    /// shows its alert, because an alert waits behind a sheet.
    func previewDenoise(_ draft: DenoiseDraft, listen: Listen) async {
        guard let studio = idleStudio else { return }
        guard let request = draft.request, let clip = draft.previewClip(in: studio.session)
        else { return studio.stopEffectPreview() }
        do throws(StudioError) {
            try await studio.startEffectPreview(request, of: clip, listen: listen)
        } catch {
            cancelDenoise()
            alert = .error(error)
        }
    }

    /// Reduce Noise of the sheet: closes it and renders the clips that the treatment accepts, with
    /// the values of the sheet kept for the next open. A render that runs past the banner wait
    /// shows the banner with the progress and Cancel. A cancel changes no clip, shows no alert,
    /// and VoiceOver reads the cancel text; another error shows its alert. At the end, a result
    /// banner shows until the next change of the session: "Nothing to change." when each clip
    /// needed no render (decision 0057).
    func applyDenoise(_ draft: DenoiseDraft) {
        guard importJob == nil, let studio = idleStudio, let request = draft.request else { return }
        let clips = draft.accepted(in: studio.session)
        guard !clips.isEmpty else { return }
        cancelDenoise()
        draft.remember(in: app?.defaults)
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
                let report = try await studio.renderClips(clips, request: request) {
                    [weak self] in
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
        guard !report.clips.isEmpty || !report.unchanged.isEmpty else { return }
        denoisePresses += 1
        denoiseReport = DenoiseReportShown(
            clips: report.clips.count, decibels: report.treatment.noise?.decibels, hum: report.treatment.hum != nil,
            revision: revision, press: denoisePresses)
    }
}
