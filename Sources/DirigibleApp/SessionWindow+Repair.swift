import DirigibleAudio
import DirigibleCore
import Foundation

/// The result of the last Repair Sound, for its banner (decision 0064 D4): the clips that moved,
/// and, for a de-clip, the clips that had a clipped run and the largest level drop of those clips
/// in whole dB.
struct RepairResult: Equatable {
    let clips: Int
    let declip: Bool
    /// True when the request also holds the rumble or the de-ess.
    let others: Bool
    let repaired: Int
    let drop: Int

    init(clips: Int, declip: Bool, others: Bool, repaired: Int, drop: Int) {
        (self.clips, self.declip, self.others, self.repaired, self.drop) = (clips, declip, others, repaired, drop)
    }

    init(_ report: ClipRenderReport) {
        let found = report.repairs.values.filter { $0.runs > 0 }
        self.init(
            clips: report.clips.count, declip: report.treatment.declip != nil,
            others: report.treatment.rumble != nil || report.treatment.deess != nil, repaired: found.count,
            drop: Int((found.map(\.levelDrop).max() ?? 0).rounded()))
    }
}

/// The result of the last Repair Sound, the session revision after it, and the number of its run,
/// so each run gives a new banner key.
struct RepairReportShown: Equatable {
    let result: RepairResult
    let revision: Int
    let press: Int
}

/// Tools > Repair Sound... (decision 0064): the item opens the sheet on the clips of the selection;
/// its Repair button is the blocking run of Reduce Noise.
extension SessionWindow {
    /// Opens the sheet on the clips of the selection, whatever their track roles. A selection with
    /// no clip beeps. With a dialog, it does nothing.
    func repairSound() {
        guard importJob == nil, !dialogShowing, let studio = idleStudio else { return }
        let clips = denoiseClips(in: studio.session)
        guard !clips.isEmpty else { return beep() }
        commitDrafts()
        repairDraft = RepairDraft(clips: clips, sampleRate: studio.session.sampleRate, defaults: app?.defaults)
    }

    /// Cancel of the sheet: stops the preview and closes the sheet. No clip changes.
    func cancelRepair() {
        studio?.stopEffectPreview()
        repairDraft = nil
    }

    /// Preview of the sheet: loops the first clip with the checked repairs. A fault shows in one
    /// line in the sheet, as in Reduce Noise.
    func previewRepair(_ draft: RepairDraft, listen: Listen) async {
        await preview(draft.request, of: draft.previewClip, listen: listen) {
            if self.repairDraft?.previewFault != $0 { self.repairDraft?.previewFault = $0 }
        }
    }

    /// Repair of the sheet: closes it and renders the clips with the checked repairs, with the values
    /// kept for the next open. At the end, a banner names the level drop of a de-clip.
    func applyRepair(_ draft: RepairDraft) {
        guard importJob == nil, let studio = idleStudio, let request = draft.request, !draft.clips.isEmpty else {
            return
        }
        cancelRepair()
        draft.remember(in: app?.defaults)
        render(draft.clips, request: request, studio: studio, canceled: .repairCanceled) {
            [weak self] report, revision in
            guard let self, !report.clips.isEmpty || !report.unchanged.isEmpty else { return }
            denoisePresses += 1
            repairReport = RepairReportShown(
                result: RepairResult(report), revision: revision, press: denoisePresses)
        }
    }
}
