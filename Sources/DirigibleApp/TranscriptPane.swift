import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The text of the Transcript tab (decision 0023): read-only, selectable, TextKit 2 only. A key
/// that a read-only text has no use for does what it does with the focus in the lanes.
final class TranscriptTextView: NSTextView {
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    /// What the storage shows: the text value and the lines of the transcripts that did not load.
    struct Shown: Equatable {
        let text: TranscriptText
        let notices: [String]
    }

    weak var model: SessionWindow?
    private(set) var shown: Shown?
    /// The session revision of `shown`. The pane builds again only when it changes.
    private(set) var builtRevision: Int?
    /// The builds and the storage replacements, for the tests (P4b).
    private(set) var builds = 0
    private(set) var replacements = 0
    private var focusPending = false

    /// Builds the text for `session` when `revision` is new, and replaces the storage only when
    /// the value differs from the shown value.
    func update(session: Session, revision: Int) {
        guard builtRevision != revision else { return }
        builtRevision = revision
        builds += 1
        let notices = session.transcriptsNotLoaded.map { L10n.transcriptNotLoaded.format($0.id.number, $0.name) }
        let next = Shown(text: TranscriptText(session: session), notices: notices)
        guard next != shown else { return }
        shown = next
        replacements += 1
        textStorage?.setAttributedString(Self.attributed(next))
    }

    private static func range(_ range: Range<Int>) -> NSRange {
        NSRange(location: range.lowerBound, length: range.count)
    }

    private static func attributed(_ shown: Shown) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for notice in shown.notices {
            out.append(
                NSAttributedString(
                    string: notice + "\n",
                    attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let text = shown.text
        let body = NSMutableAttributedString(
            string: text.string, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        let header = NSMutableParagraphStyle()
        header.lineBreakMode = .byTruncatingMiddle
        header.paragraphSpacing = 2
        header.paragraphSpacingBefore = 8
        for item in text.headers {
            // The paragraph style covers the line break of the header paragraph.
            let paragraph = NSRange(location: item.range.lowerBound, length: item.range.count + 1)
            body.addAttributes(
                [.font: headerFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: header],
                range: paragraph)
        }
        for line in text.backchannels {
            body.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range(line.name))
        }
        out.append(body)
        return out
    }

    /// The text location of the notices, which come before the text of the value.
    private var noticeLength: Int { shown.map { $0.notices.reduce(0) { $0 + $1.utf16.count + 1 } } ?? 0 }

    /// Takes the focus, and puts the insertion point at the first unit of the paragraph of the
    /// playhead (P1). With no unit, the insertion point stays. Waits for the window if there is none.
    func takeFocus() {
        guard let window else {
            focusPending = true
            return
        }
        focusPending = false
        window.makeFirstResponder(self)
        if let frame = model?.studio?.playhead, let start = shown?.text.paragraphStart(at: frame) {
            setSelectedRange(NSRange(location: noticeLength + start, length: 0))
        }
        model?.transcriptFollow.focusRequest = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusPending { Task { @MainActor [weak self] in self?.takeFocus() } }
    }

    // The Edit items send their selector to the first responder (probes E2, E3), so a read-only
    // text view runs the window command (P14, P10).
    override func selectAll(_ sender: Any?) { model?.run(.selectAll) }
    override func copy(_ sender: Any?) { model?.run(.copy) }
    override func cut(_ sender: Any?) { model?.run(.cut) }
    override func paste(_ sender: Any?) { model?.run(.paste) }
    override func delete(_ sender: Any?) { model?.run(.deleteCloseGap) }
}

/// The Transcript tab: the text of the transcripts of the session, for reading.
struct TranscriptPane: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        // Both values are read here, so a new revision or a focus request runs `updateNSView`.
        TranscriptPaneText(
            model: model, studio: studio, revision: studio.sessionRevision,
            wantsFocus: model.transcriptFollow.focusRequest
        )
        .accessibilityIdentifier("transcript.pane")
    }
}

private struct TranscriptPaneText: NSViewRepresentable {
    let model: SessionWindow
    let studio: Studio
    let revision: Int
    let wantsFocus: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = TranscriptTextView(usingTextLayoutManager: true)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel(L10n.inspectorTabTranscript.text)
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptTextView else { return }
        text.model = model
        text.update(session: studio.session, revision: revision)
        if wantsFocus { Task { @MainActor [weak text] in text?.takeFocus() } }
    }
}
