import DirigibleCore
import DirigibleTimeline

/// Edit > Duplicate (Command-D, decision 0053): one `Session.duplicate` of the selection.
extension SessionWindow {
    /// What Duplicate copies, when it can run: an idle studio, no run of the window, and a range on a
    /// track or a clip set with a live clip. Nil otherwise. It reads no clipboard.
    var duplicateSource: Selection.DuplicateSource? {
        guard importJob == nil, let studio = idleStudio else { return nil }
        return timeline.selection.duplicateSource(in: studio.session)
    }

    /// Duplicate: one edit, so one undo entry. The copy goes after the source, over the audio that is
    /// there, and nothing moves. The copy becomes the selection, so the next Duplicate makes a third
    /// copy after it. VoiceOver says "Duplicated.". With no source, nothing.
    func runDuplicate() {
        guard let source = duplicateSource else { return }
        let copy = edit(ripple: false) { session throws(SessionError) in try source.duplicate(&session) }
        guard let copy else { return }
        timeline.selection = copy
        chrome?.announce(L10n.duplicateDone.text, .high)
    }
}
