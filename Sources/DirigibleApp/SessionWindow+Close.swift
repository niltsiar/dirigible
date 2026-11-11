import AppKit
import DirigibleAudio

/// The close and the quit of a session window.
extension SessionWindow {
    /// Waits for the open, stops a take, and waits for every write. When the last save failed,
    /// it asks before it closes.
    func close() async {
        if holdsRefusedEpisode() { return }
        commitDrafts()
        alert = nil
        unusedFiles = nil
        denoiseDraft = nil
        repairDraft = nil
        cancelTranscribeSheet()
        closeConsent()
        switch phase {
        case .closing, .closed: return
        case .failed:
            finishClose()
            return
        case .opening, .open: phase = .closing(studio)
        }
        await opening?.value
        guard case .closing(let studio) = phase else { return }
        if let studio {
            // `settle` empties the monitor and listen requests, so the toggles go off too.
            monitoring = false
            listened = []
            await studio.settle()
            if studio.saveError != nil {
                alert = .confirmUnsavedClose
                return
            }
        }
        finishClose()
    }

    /// "Close anyway?": Cancel. The window stays open with the same studio, which keeps its lock.
    /// The close settle started no peak pass, so the files of a finalized take get their peaks now (0017).
    func cancelUnsavedClose() {
        alert = nil
        guard case .closing(let studio?) = phase else { return }
        phase = .open(studio)
        studio.loadPeaks()
    }

    /// For Quit: waits for the open, turns the monitor off, stops a take, and waits for every write.
    func settle() async {
        closeConsent()
        await opening?.value
        commitDrafts()
        monitoring = false
        listened = []
        await studio?.settle()
    }
}
