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

    /// The top of the visible text, in the coordinates of the text.
    var scrollOrigin: Double { Double(enclosingScrollView?.contentView.bounds.origin.y ?? 0) }

    /// Scrolls the first current unit to about one third from the top (P4). The scroll is the
    /// follow's own: it does not turn the follow off.
    func scrollToCurrent() {
        guard let scroll = enclosingScrollView,
            let target = marked.lazy.compactMap({ self.segmentFrames(of: $0).first }).first
        else { return }
        let clip = scroll.contentView
        let most = max(0, frame.height - clip.bounds.height)
        moveScroll(to: min(max(0, target.minY - clip.bounds.height / 3), most))
    }

    private func moveScroll(to origin: CGFloat) {
        guard let scroll = enclosingScrollView, abs(scroll.contentView.bounds.origin.y - origin) >= 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: origin))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// A new pane shows the text where the last pane left it, unless the follow is on (P4).
    func restoreScroll() {
        guard !scrollRestored, let follow = model?.transcriptFollow else { return }
        scrollRestored = true
        if follow.isOn {
            scrollToCurrent()
        } else if let origin = follow.scrollOrigin {
            layoutSubtreeIfNeeded()
            moveScroll(to: origin)
        }
    }

    /// A scroll by the user (wheel, trackpad, scroller) turns the follow off.
    @objc func userScrolled() { model?.transcriptFollow.isOn = false }

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase.isEmpty, event.deltaY != 0 || event.scrollingDeltaY != 0 { userScrolled() }
        super.scrollWheel(with: event)
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
