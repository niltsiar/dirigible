import AppKit
import DirigibleCore
import SwiftUI

/// A Finder drop of audio files on a session with no tracks (run empty-drop-lane-click, decision
/// 0040). The empty content has no lanes to take the drag, so this view hosts it and takes the
/// drag over the whole area, also over the text and the buttons. A drop makes one new track for
/// each file, each clip at frame 0, through the import of the window. The drag holds no file after
/// an exit, a drop, or the end of the drag.
final class EmptyDropView: NSView {
    private weak var model: SessionWindow?
    private var urls: [URL] = []

    init<Content: View>(model: SessionWindow, content: Content) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
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
        accepts ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { urls = [] }
    override func draggingEnded(_ sender: any NSDraggingInfo) { urls = [] }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { urls = [] }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = urls
        urls = []
        guard !files.isEmpty, let model, model.canImport else { return false }
        model.startImport(files, to: ImportTarget(track: nil, start: .zero))
        return true
    }

    /// There is an audio file in the drag and the window can import.
    private var accepts: Bool { !urls.isEmpty && model?.canImport == true }
}

/// The empty content of a session, with the file drop of `EmptyDropView` around it.
struct EmptyDropHost<Content: View>: NSViewRepresentable {
    let model: SessionWindow
    let content: Content

    func makeNSView(context: Context) -> EmptyDropView { EmptyDropView(model: model, content: content) }
    func updateNSView(_ view: EmptyDropView, context: Context) { view.update(content: content) }
}
