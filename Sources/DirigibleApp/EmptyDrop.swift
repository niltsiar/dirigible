import AppKit
import DirigibleCore
import SwiftUI

/// A Finder drop of audio files on a session with no tracks (run empty-drop-lane-click, decision
/// 0040). The empty content has no lanes to take the drag, so this view hosts it and takes the
/// drag over the whole area, also over the text and the buttons. A drop makes one new track for
/// each file, each clip at frame 0, through the import of the window. The drag holds no file after
/// an exit, a drop, or the end of the drag. During an accepted drag, an accent outline and fill
/// over the whole area carry the 13c label of the new tracks. The cue is layers, made once, with no
/// implicit action.
final class EmptyDropView: NSView {
    private weak var model: SessionWindow?
    private var urls: [URL] = []
    let cue = CALayer()
    let cueLabel = CATextLayer()
    /// The lines of the cue are 2 pt, else 1 pt.
    var increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private var palette = LanePalette.light {
        didSet { setColors() }
    }

    init<Content: View>(model: SessionWindow, content: Content) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        cue.zPosition = 5
        cue.isHidden = true
        cue.cornerRadius = 8
        cueLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        cueLabel.fontSize = 12
        cueLabel.alignmentMode = .center
        cueLabel.truncationMode = .end
        cue.addSublayer(cueLabel)
        layer?.addSublayer(cue)
        setColors()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The content in the hosting view, after SwiftUI updates it.
    func update<Content: View>(content: Content) {
        (subviews.first as? NSHostingView<Content>)?.rootView = content
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        urls = AppDelegate.audioFiles(on: sender.draggingPasteboard)
        sender.numberOfValidItemsForDrop = urls.count
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard accepts else {
            setCue(visible: false)
            return []
        }
        setCue(visible: true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { endDrop() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { endDrop() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { endDrop() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = urls
        endDrop()
        guard !files.isEmpty, let model, model.canImport else { return false }
        model.startImport(files, to: ImportTarget(track: nil, start: .zero))
        return true
    }

    /// There is an audio file in the drag and the window can import.
    private var accepts: Bool { !urls.isEmpty && model?.canImport == true }

    private func endDrop() {
        urls = []
        setCue(visible: false)
    }

    private func setCue(visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if visible {
            cue.borderWidth = increasesContrast ? 2 : 1
            let label = LaneDrop.label(files: urls.count)
            // A new string renders the text again, so only a new count sets it.
            if cueLabel.string as? String != label { cueLabel.string = label }
            cueLabel.contentsScale = window?.backingScaleFactor ?? 2
        }
        cue.isHidden = !visible
        CATransaction.commit()
    }

    private func setColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (cue.borderColor, cue.backgroundColor) = (cgColor(palette.outline), palette.dropFill)
        cueLabel.foregroundColor = cgColor(palette.label)
        CATransaction.commit()
    }

    @objc private func displayOptionsChanged() {
        increasesContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cue.frame = bounds
        cueLabel.frame = CGRect(x: 12, y: bounds.height - 28, width: max(0, bounds.width - 24), height: 16)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = LanePalette.pick(for: effectiveAppearance)
    }
}

/// The empty content of a session, with the file drop of `EmptyDropView` around it.
struct EmptyDropHost<Content: View>: NSViewRepresentable {
    let model: SessionWindow
    let content: Content

    func makeNSView(context: Context) -> EmptyDropView { EmptyDropView(model: model, content: content) }
    func updateNSView(_ view: EmptyDropView, context: Context) { view.update(content: content) }
}
