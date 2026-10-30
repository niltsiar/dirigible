import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The text of the Transcript tab (decision 0023): read-only, selectable, TextKit 2 only. A key
/// that a read-only text has no use for does what it does with the focus in the lanes.
final class TranscriptTextView: NSTextView {
    nonisolated static var headerFont: NSFont { NSFont.systemFont(ofSize: 11, weight: .semibold) }
    nonisolated static var bodyFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize) }

    /// What the storage shows: the text value and the lines of the transcripts that did not load.
    struct Shown: Equatable, Sendable {
        let text: TranscriptText
        let notices: [String]
    }

    /// A value built off the main actor for the session revision `revision`.
    struct Built {
        let revision: Int
        let shown: Shown
        let attributed: NSAttributedString
    }

    weak var model: SessionWindow?
    private(set) var shown: Shown?
    /// The session revision of `shown`. The pane builds again only when it changes.
    private(set) var builtRevision: Int?
    /// The revision of the last applied build: equal to `builtRevision` when no build is pending.
    private(set) var shownRevision: Int?
    /// The builds and the storage replacements, for the tests (P4b).
    private(set) var builds = 0
    private(set) var replacements = 0
    private var focusPending = false
    /// The underline layers of the current units (P4): one for each line fragment of a unit.
    private(set) var underlines: [CALayer] = []
    private var spareUnderlines: [CALayer] = []
    /// The text ranges of the marked units, in the text of the value.
    private var marked: [Range<Int>] = []
    private var markedFrame: Frames?
    /// True with Increase Contrast: the underline is 3 pt (P4).
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        didSet { if increaseContrast != oldValue { styleUnderlines() } }
    }
    /// The focus came before the build of its revision: the apply puts the insertion point.
    private var caretPending = false

    /// Builds the text for `session` off the main actor when `revision` is new (P13), then applies it.
    func update(session: Session, revision: Int) {
        guard begin(revision: revision) else { return }
        let notices = session.transcriptsNotLoaded.map { L10n.transcriptNotLoaded.format($0.id.number, $0.name) }
        Task { [weak self] in
            let built = await Self.build(session, notices: notices, revision: revision)
            self?.apply(built)
        }
    }

    /// Counts a build for a new `revision`. False when the revision is the built one.
    func begin(revision: Int) -> Bool {
        guard builtRevision != revision else { return false }
        builtRevision = revision
        builds += 1
        return true
    }

    @concurrent nonisolated static func build(_ session: Session, notices: [String], revision: Int) async
        -> sending Built
    {
        let shown = Shown(text: TranscriptText(session: session), notices: notices)
        return Built(revision: revision, shown: shown, attributed: attributed(shown))
    }

    /// Replaces the storage with `built` only when its revision is still the built one and its
    /// value differs from the shown value. An older build is dropped.
    func apply(_ built: Built) {
        guard built.revision == builtRevision else { return }
        shownRevision = built.revision
        defer { if caretPending { placeCaret() } }
        guard built.shown != shown, let storage = textStorage else { return }
        shown = built.shown
        replacements += 1
        // A replace in a storage that holds text inserts each attribute run apart (290 ms at 27 000
        // units, P13); an insert into an empty storage takes 7 ms.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        storage.append(built.attributed)
        storage.endEditing()
        if let frame = markedFrame { marked = built.shown.text.units(at: frame).map(\.text) }
        placeUnderlines()
    }

    nonisolated private static func range(_ range: Range<Int>) -> NSRange {
        NSRange(location: range.lowerBound, length: range.count)
    }

    nonisolated private static func attributed(_ shown: Shown) -> NSAttributedString {
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
        placeCaret()
        model?.transcriptFollow.focusRequest = false
    }

    /// Puts the insertion point at the first unit of the paragraph of the playhead, or waits for
    /// the apply while a build is pending.
    private func placeCaret() {
        caretPending = shownRevision != builtRevision
        guard !caretPending else { return }
        if let frame = model?.studio?.playhead, let start = shown?.text.paragraphStart(at: frame) {
            setSelectedRange(NSRange(location: noticeLength + start, length: 0))
        }
    }

    // MARK: The current unit (P4)

    /// Marks the units that hold `frame` with an underline under each line fragment. A tick with
    /// the same units changes nothing; a tick with other units moves layer frames, never the text.
    func highlight(frame: Frames) {
        markedFrame = frame
        let ranges = shown?.text.units(at: frame).map(\.text) ?? []
        guard ranges != marked else { return }
        marked = ranges
        placeUnderlines()
    }

    private func placeUnderlines() {
        let frames = marked.flatMap { segmentFrames(of: $0) }
        while underlines.count > frames.count { spareUnderlines.append(underlines.removeLast()) }
        while underlines.count < frames.count {
            let layer = spareUnderlines.popLast() ?? Self.underlineLayer()
            underlines.append(layer)
        }
        for (layer, segment) in zip(underlines, frames) {
            layer.frame = CGRect(x: segment.minX, y: segment.maxY + 1, width: segment.width, height: underlineWidth)
            if layer.superlayer == nil { self.layer?.addSublayer(layer) }
        }
        for layer in spareUnderlines { layer.removeFromSuperlayer() }
        styleUnderlines()
    }

    private var underlineWidth: Double { increaseContrast ? 3 : 2 }

    /// Sets the color and the width again. The color is the core of the playhead of the lanes.
    private func styleUnderlines() {
        let color = PlayheadColors(appearance: effectiveAppearance, taking: false).core
        for layer in underlines {
            layer.backgroundColor = color
            layer.cornerRadius = underlineWidth / 2
            layer.frame.size.height = underlineWidth
        }
    }

    private static func underlineLayer() -> CALayer {
        let layer = CALayer()
        layer.actions = [
            "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull(),
        ]
        return layer
    }

    /// The line fragments of the text range `range` of the value, in the coordinates of the view.
    private func segmentFrames(of range: Range<Int>) -> [CGRect] {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return [] }
        let offset = noticeLength + range.lowerBound
        guard let start = content.location(manager.documentRange.location, offsetBy: offset),
            let end = content.location(start, offsetBy: range.count),
            let span = NSTextRange(location: start, end: end)
        else { return [] }
        var found: [CGRect] = []
        manager.enumerateTextSegments(in: span, type: .standard, options: []) { _, frame, _, _ in
            found.append(frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        return found
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleUnderlines()
    }

    @objc private func displayOptionsChanged(_ note: Notification) {
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        styleUnderlines()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !marked.isEmpty { placeUnderlines() }
    }

    /// The scroll view with the text view of the pane, as the Transcript tab shows it.
    static func scrollView() -> NSScrollView {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayOptionsChanged), name: NSColor.systemColorsDidChangeNotification,
            object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
        if studio.session.transcriptNames.isEmpty {
            empty
        } else {
            // Both values are read here, so a new revision or a focus request runs `updateNSView`.
            TranscriptPaneText(
                model: model, studio: studio, revision: studio.sessionRevision,
                wantsFocus: model.transcriptFollow.focusRequest
            )
            .accessibilityIdentifier("transcript.pane")
        }
    }

    /// With no transcript: the title, the file types, and a button with the state of the menu item (P2).
    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(L10n.transcriptEmptyTitle.key).font(.title3).foregroundStyle(.tertiary)
            Text(L10n.transcriptEmptyHint.key).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(L10n.menuFileImportTranscript.key) { model.run(.importTranscript) }
                .controlSize(.small).disabled(!model.isOn(.importTranscript))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptPaneText: NSViewRepresentable {
    let model: SessionWindow
    let studio: Studio
    let revision: Int
    let wantsFocus: Bool

    func makeNSView(context: Context) -> NSScrollView { TranscriptTextView.scrollView() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptTextView else { return }
        text.model = model
        model.transcriptFollow.pane = text
        text.update(session: studio.session, revision: revision)
        if wantsFocus { Task { @MainActor [weak text] in text?.takeFocus() } }
    }
}
