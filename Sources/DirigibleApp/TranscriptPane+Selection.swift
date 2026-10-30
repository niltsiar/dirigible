import AppKit
import DirigibleCore
import DirigibleTimeline

/// Select and cut by words (run transcript-1, landing 2, criteria P7 to P10, P16). The timeline
/// selection is the one source of the range: a user selection in the pane writes it, and a change
/// by any other writer clears the pane selection and shows as a tint.
extension TranscriptTextView {
    /// Every selection path comes here (U47). A selection of one character or more snaps to whole
    /// units in one range and writes the timeline range on all tracks; with no unit in it, it
    /// clears the range. A caret and a selection that the pane sets itself write nothing.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let spans = ranges.map(\.rangeValue)
        let (lower, upper) = (spans.map(\.location).min() ?? 0, spans.map(NSMaxRange).max() ?? 0)
        guard !selfSelecting, upper > lower, let text = currentText, let session = model?.studio?.session else {
            return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        }
        let value = max(0, lower - noticeLength)..<max(0, upper - noticeLength)
        guard let snapped = text.snapped(value), let frames = text.frames(inText: value) else {
            super.setSelectedRanges(
                [NSValue(range: NSRange(location: lower, length: 0))], affinity: affinity,
                stillSelecting: stillSelecting)
            return writeRange(.none)
        }
        let range = NSRange(location: noticeLength + snapped.lowerBound, length: snapped.count)
        super.setSelectedRanges([NSValue(range: range)], affinity: affinity, stillSelecting: stillSelecting)
        writeRange(
            .range(
                Marks(inPoint: frames.lowerBound, outPoint: frames.upperBound, tracks: Set(session.tracks.map(\.id))))
        )
    }

    private func writeRange(_ selection: Selection) {
        wrote = selection
        if model?.timeline.selection != selection { model?.timeline.selection = selection }
    }

    /// Shows the timeline selection: a change that the pane did not write clears the pane
    /// selection, and the range tints its units.
    func show(_ selection: Selection) {
        guard selection != shownSelection else { return }
        shownSelection = selection
        if selection != wrote, selectedRange().length > 0 {
            selfSelecting = true
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            selfSelecting = false
            wrote = nil
            moveEnds = nil
        }
        tint()
    }

    /// Tints each unit of a range track whose midpoint is inside the range (P9), with the
    /// selection color of the lanes. A rendering attribute changes no text and no selection.
    func tint() {
        guard let manager = textLayoutManager else { return }
        manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
        guard let text = shown?.text, let session = model?.studio?.session,
            let range = shownSelection?.marks?.selection(in: session)
        else { return }
        for run in text.tintRuns(range.range, tracks: Set(range.tracks)) {
            guard let span = textRange(of: run) else { continue }
            manager.addRenderingAttribute(
                .backgroundColor, value: NSColor.unemphasizedSelectedContentBackgroundColor, for: span)
        }
    }

    // MARK: Key moves (P8)

    /// Shift-Left (-1) and Shift-Right (+1) with the focus in the pane: the active end of the
    /// selection moves by one unit.
    func moveSelectionEnd(by step: Int) { moveEnd { $0 + step } }

    override func moveUpAndModifySelection(_ sender: Any?) {
        guard let text = currentText else { return super.moveUpAndModifySelection(sender) }
        moveEnd { text.previousSentenceBoundary(before: $0) }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        guard let text = currentText else { return super.moveDownAndModifySelection(sender) }
        moveEnd { text.nextSentenceBoundary(after: $0) }
    }

    /// Moves the active end to the unit boundary that `move` gives, and says the word count. A
    /// move that leaves no unit puts the insertion point there and clears the range.
    private func moveEnd(_ move: (Int) -> Int) {
        guard let text = currentText, !text.units.isEmpty else { return }
        let selected = selectedRange()
        let ends: (anchor: Int, active: Int)
        if let last = moveEnds, last.range == selected {
            ends = (last.anchor, last.active)
        } else {
            let start = max(0, selected.location - noticeLength)
            let units = text.unitIndexes(touching: start..<start + selected.length)
            ends = (units.lowerBound, selected.length > 0 ? units.upperBound : units.lowerBound)
        }
        let anchor = ends.anchor
        let active = min(max(0, move(ends.active)), text.units.count)
        let (low, high) = (min(anchor, active), max(anchor, active))
        if low == high {
            let location =
                low < text.units.count ? text.units[low].text.lowerBound : text.units[low - 1].text.upperBound
            setSelectedRange(NSRange(location: noticeLength + location, length: 0))
            writeRange(.none)
        } else {
            let start = text.units[low].text.lowerBound
            setSelectedRange(
                NSRange(location: noticeLength + start, length: text.units[high - 1].text.upperBound - start))
        }
        moveEnds = (anchor, active, selectedRange())
        scrollRangeToVisible(selectedRange())
        announced = high - low
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: L10n.transcriptSelected.format(high - low),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    // MARK: Copy and Cut (P16, P10)

    /// Copy of the window, and the words of the range as plain text on the pasteboard.
    override func copy(_ sender: Any?) {
        let words = rangeText()
        model?.run(.copy)
        if let words { put(words) }
    }

    /// Cut of the window (a ripple of all tracks), and the words of the range as plain text on the
    /// pasteboard. A refused Cut makes no edit and writes no text.
    override func cut(_ sender: Any?) {
        guard let model, let studio = model.studio else { return }
        let (words, revision) = (rangeText(), studio.sessionRevision)
        model.run(.cut)
        if let words, studio.sessionRevision != revision { put(words) }
    }

    /// The text of the units that the timeline range tints, or nil with no range or no such unit.
    private func rangeText() -> String? {
        guard let text = currentText, let model, let session = model.studio?.session,
            let range = model.timeline.selection.marks?.selection(in: session)
        else { return nil }
        return text.copyText(range.range, tracks: Set(range.tracks))
    }

    private func put(_ words: String) {
        pasteboard.clearContents()
        pasteboard.setString(words, forType: .string)
    }
}
