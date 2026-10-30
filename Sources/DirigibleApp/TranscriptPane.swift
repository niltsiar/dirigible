import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The text of the Transcript tab (decision 0023): read-only, selectable, TextKit 2 only. Every key
/// with a menu item does what it does with the focus in the lanes, except Shift-Left and Shift-Right
/// (they move the end of the selection) and Return in a header (it seeks).
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
    /// The shown text, only while it is of the current session revision. After an edit and before
    /// the apply of the rebuild it is nil, so the pane writes no range and no seek from old text.
    var currentText: TranscriptText? {
        guard let revision = model?.studio?.sessionRevision, revision == shownRevision else { return nil }
        return shown?.text
    }
    /// The session revision of `shown`. The pane builds again only when it changes.
    private(set) var builtRevision: Int?
    /// The revision of the last applied build: equal to `builtRevision` when no build is pending.
    private(set) var shownRevision: Int?
    /// The builds and the storage replacements, for the tests (P4b).
    private(set) var builds = 0
    private(set) var replacements = 0
    private var focusPending = false
    /// True while a build runs, and the revision that waits for it to end.
    private var building = false
    private var waiting: (session: Session, notices: [String], revision: Int)?
    /// The observers that the pane added while it shows in a window.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var observerCount: Int { observers.count }
    /// The first apply of a pane puts the scroll position of the last pane back (P4).
    var scrollRestored = false
    /// The underline layers of the current units (P4): one for each line fragment of a unit.
    private(set) var underlines: [CALayer] = []
    private var spareUnderlines: [CALayer] = []
    /// The text ranges of the marked units, in the text of the value.
    private(set) var marked: [Range<Int>] = []
    private var markedFrame: Frames?
    /// True with Increase Contrast: the underline is 3 pt (P4).
    var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        didSet { if increaseContrast != oldValue { styleUnderlines() } }
    }
    /// The focus came before the build of its revision: the apply puts the insertion point.
    private var caretPending = false
    /// The pasteboard of the text of Copy and Cut (P16). A test sets its own.
    var pasteboard = NSPasteboard.general
    /// The word count of the last key move, as VoiceOver says it (P7).
    var announced: Int?
    /// The timeline selection that the pane wrote last, and the one that it shows (P9).
    var wrote: Selection?
    var shownSelection: Selection?
    /// True while the pane sets its own selection: it writes no timeline selection then.
    var selfSelecting = false
    /// The unit boundaries of the last key move and the selection that it made (P8).
    var moveEnds: (anchor: Int, active: Int, range: NSRange)?

    /// Builds the text for `session` off the main actor when `revision` is new (P13), then applies
    /// it. At most one build runs: a revision that arrives during a build waits, and replaces any
    /// revision that waited before it.
    func update(session: Session, revision: Int) {
        guard revision != (waiting?.revision ?? builtRevision) else { return }
        let notices = session.transcriptsNotLoaded.map { L10n.transcriptNotLoaded.format($0.id.number, $0.name) }
        guard !building else {
            waiting = (session, notices, revision)
            return
        }
        start(session, notices: notices, revision: revision)
    }

    private func start(_ session: Session, notices: [String], revision: Int) {
        guard begin(revision: revision) else { return }
        building = true
        Task { [weak self] in
            let built = await Self.build(session, notices: notices, revision: revision)
            self?.finish(built)
        }
    }

    /// Ends a build. With a newer revision waiting, the result is stale: drop it and build the
    /// newer revision. Else apply it.
    private func finish(_ built: Built) {
        building = false
        let next = waiting
        waiting = nil
        if let next, next.revision != built.revision {
            return start(next.session, notices: next.notices, revision: next.revision)
        }
        apply(built)
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
        selfSelecting = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        storage.append(built.attributed)
        storage.endEditing()
        selfSelecting = false
        wrote = nil
        moveEnds = nil
        tint()
        if let frame = markedFrame { marked = built.shown.text.units(at: frame).map(\.text) }
        placeUnderlines()
        restoreScroll()
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
    var noticeLength: Int { shown.map { $0.notices.reduce(0) { $0 + $1.utf16.count + 1 } } ?? 0 }

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
        if model?.transcriptFollow.isOn == true { scrollToCurrent() }
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

    /// The text range `range` of the value, as a range of the layout manager.
    func textRange(of range: Range<Int>) -> NSTextRange? {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
            let start = content.location(manager.documentRange.location, offsetBy: noticeLength + range.lowerBound),
            let end = content.location(start, offsetBy: range.count)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The line fragments of the text range `range` of the value, in the coordinates of the view.
    func segmentFrames(of range: Range<Int>) -> [CGRect] {
        guard let manager = textLayoutManager, let span = textRange(of: range) else { return [] }
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

    private func displayOptionsChanged() {
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { model?.transcriptFollow.scrollOrigin = scrollOrigin }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        guard window != nil else { return }
        observe(NotificationCenter.default, NSColor.systemColorsDidChangeNotification) { $0.displayOptionsChanged() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.displayOptionsChanged()
        }
        observe(NotificationCenter.default, NSScrollView.willStartLiveScrollNotification, enclosingScrollView) {
            $0.userScrolled()
        }
        if focusPending { Task { @MainActor [weak self] in self?.takeFocus() } }
    }

    /// Adds an observer that runs `action` on the main queue while the pane lives, and keeps its
    /// token, so a window change removes this observer and no other.
    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ object: AnyObject? = nil,
        _ action: @escaping @MainActor (TranscriptTextView) -> Void
    ) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    // The Edit items send their selector to the first responder (probes E2, E3), so a read-only
    // text view runs the window command (P14, P10). Copy and Cut are in TranscriptPane+Selection.
    override func selectAll(_ sender: Any?) { model?.run(.selectAll) }
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
            VStack(spacing: 0) {
                followToggle
                // The values are read here, so a new revision, a focus request, or a timeline change
                // runs `updateNSView`.
                TranscriptPaneText(
                    model: model, studio: studio, revision: studio.sessionRevision,
                    wantsFocus: model.transcriptFollow.focusRequest, selection: model.timeline.selection
                )
                .accessibilityIdentifier("transcript.pane")
            }
        }
    }

    /// The state of the follow at all times (P18), apart from View > Automatic Scroll.
    private var followToggle: some View {
        Toggle(
            L10n.transcriptFollow.key,
            isOn: Binding(
                get: { model.transcriptFollow.isOn }, set: { _ in model.toggleTranscriptFollow() })
        )
        .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityIdentifier("transcript.follow")
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
    let selection: Selection

    func makeNSView(context: Context) -> NSScrollView { TranscriptTextView.scrollView() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? TranscriptTextView else { return }
        text.model = model
        model.transcriptFollow.pane = text
        text.update(session: studio.session, revision: revision)
        text.show(selection)
        if wantsFocus { Task { @MainActor [weak text] in text?.takeFocus() } }
    }
}
