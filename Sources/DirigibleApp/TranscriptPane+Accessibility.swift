import AppKit
import DirigibleCore
import DirigibleTimeline

/// VoiceOver in the pane (run transcript-1, landing 2, criterion P7): the Headings rotor jumps from
/// paragraph header to paragraph header, and the action Go to Word seeks to the word at the
/// insertion point. A play tick posts no accessibility notification.
extension TranscriptTextView: @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        [NSAccessibilityCustomRotor(rotorType: .heading, itemSearchDelegate: self)]
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let text = shown?.text else { return nil }
        let ranges = text.headers.map { NSRange(location: noticeLength + $0.range.lowerBound, length: $0.range.count) }
        let current = parameters.currentItem?.targetRange.location
        let found: NSRange?
        switch parameters.searchDirection {
        case .next: found = ranges.first { $0.location > (current ?? -1) }
        case .previous: found = ranges.last { $0.location < (current ?? Int.max) }
        @unknown default: found = nil
        }
        guard let found else { return nil }
        let item = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        item.targetRange = found
        return item
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: L10n.transcriptGoToWord.text) { [weak self] in self?.goToWord() ?? false }]
    }

    /// Puts the playhead at the start of the word at the insertion point (also at its end), or of
    /// the first word under a header. False when the insertion point is in no word.
    func goToWord() -> Bool {
        guard let text = currentText else { return false }
        let at = selectedRange().location - noticeLength
        guard
            let unit = text.headerUnit(atTextLocation: at)
                ?? [at, at - 1].lazy.compactMap({ text.unit(atTextLocation: $0) }).first
        else { return false }
        model?.transport(.seek(.frame(unit.frames.lowerBound)))
        return true
    }
}
