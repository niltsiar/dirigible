import AppKit
import DirigibleCore
import DirigibleTimeline

/// A drop of audio files from the Finder on the lanes (run 13c, decision 0040). The drag enter
/// reads the files once. Each update and the drop compute the target again from the point; the
/// drop gives the files to the import of the window. The drag holds no file after an exit, a
/// drop, or the end of the drag.
extension TimelineScrollView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let types = AppDelegate.importTypes.map(\.identifier)
        lanes.drop.urls =
            sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: types]
            ) as? [URL] ?? []
        sender.numberOfValidItemsForDrop = lanes.drop.urls.count
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropTarget(sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { endDrop() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { endDrop() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { endDrop() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let (urls, target) = (lanes.drop.urls, dropTarget(sender))
        endDrop()
        guard let target else { return false }
        model?.startImport(urls, to: target)
        return true
    }

    /// The import target at the point of the drag. Nil with no audio file, when the window cannot
    /// import (a take, a pending take, or a running import), or outside the lanes in view (the
    /// track headers and the time ruler).
    private func dropTarget(_ sender: any NSDraggingInfo) -> ImportTarget? {
        let point = lanes.convert(sender.draggingLocation, from: nil)
        guard !lanes.drop.urls.isEmpty, model?.canImport == true, shown.contains(point), let inputs = lanes.inputs,
            let geometry = inputs.geometry
        else { return nil }
        return geometry.dropTarget(
            x: point.x, y: point.y, files: lanes.drop.urls.count, bottom: shown.maxY, in: inputs.session)
    }

    private func endDrop() { lanes.drop.urls = [] }
}
