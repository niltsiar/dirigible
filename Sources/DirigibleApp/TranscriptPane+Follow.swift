import AppKit
import DirigibleCore
import DirigibleTimeline

/// The click and Return in a header (run transcript-1, landing 2, criteria P5, P21).
extension TranscriptTextView {
    /// A click at `point` (view coordinates) puts the playhead at the start of the unit under it.
    /// A header, a track name, and the space after a paragraph do not seek. The click makes no range.
    func click(at point: NSPoint) {
        guard let unit = unit(at: point) else { return }
        model?.transport(.seek(.frame(unit.frames.lowerBound)))
    }

    /// The unit that has a line fragment at `point`. The point past the end of a line gives the
    /// character before it, so the line fragment decides.
    private func unit(at point: NSPoint) -> TranscriptText.Unit? {
        guard let text = shown?.text else { return nil }
        let index = characterIndexForInsertion(at: point) - noticeLength
        return [index, index - 1].lazy.compactMap { text.unit(atTextLocation: $0) }
            .first { unit in segmentFrames(of: unit.text).contains { $0.contains(point) } }
    }

    /// Return with the insertion point in a header puts the playhead at the first unit of its
    /// paragraph. False when the key is not for the pane: the caller runs the lanes action.
    func returnInHeader() -> Bool {
        let selection = selectedRange()
        guard window?.firstResponder === self, selection.length == 0,
            let text = shown?.text, selection.location >= noticeLength,
            let unit = text.headerUnit(atTextLocation: selection.location - noticeLength)
        else { return false }
        model?.transport(.seek(.frame(unit.frames.lowerBound)))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }
}
