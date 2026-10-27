import AppKit
import DirigibleCore
import DirigibleTimeline

/// A drop of audio files from the Finder on the lanes (run 13c, decision 0040). The drag enter
/// reads the files once. Each update and the drop compute the target again from the point; the
/// drop gives the files to the import of the window. The drag holds no file after an exit, a
/// drop, or the end of the drag.
extension TimelineScrollView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        lanes.drop.urls = AppDelegate.audioFiles(on: sender.draggingPasteboard)
        sender.numberOfValidItemsForDrop = lanes.drop.urls.count
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let (target, x, inputs, geometry) = dropPlace(sender) else {
            lanes.drop.hide()
            return []
        }
        let tracks = inputs.session.tracks
        lanes.drop.show(
            lane: target.track.flatMap { id in tracks.firstIndex { $0.id == id } }, x: x, files: lanes.drop.urls.count,
            lanes: tracks.count, laneHeight: inputs.laneHeight,
            newTrackTop: geometry.newTrackTop(lanes: tracks.count, bottom: shown.maxY), shown: shown,
            contrast: lanes.increasesContrast, scale: Double(window?.backingScaleFactor ?? 2))
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { endDrop() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { endDrop() }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { endDrop() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let (urls, place) = (lanes.drop.urls, dropPlace(sender))
        endDrop()
        guard let place else { return false }
        model?.startImport(urls, to: place.target)
        return true
    }

    /// The import target at the point of the drag, the document x of the point, and the drawn
    /// lanes. Nil with no audio file, when the window cannot import (a take, a pending take, or a
    /// running import), or outside the lanes in view (the track headers and the time ruler).
    private func dropPlace(_ sender: any NSDraggingInfo)
        -> (target: ImportTarget, x: Double, inputs: LaneInputs, geometry: LaneGeometry)?
    {
        let point = lanes.convert(sender.draggingLocation, from: nil)
        guard !lanes.drop.urls.isEmpty, model?.canImport == true, shown.contains(point), let inputs = lanes.inputs,
            let geometry = inputs.geometry
        else { return nil }
        let target = geometry.dropTarget(
            x: point.x, y: point.y, files: lanes.drop.urls.count, bottom: shown.maxY, in: inputs.session)
        return (target, Double(point.x), inputs, geometry)
    }

    private func endDrop() {
        lanes.drop.urls = []
        lanes.drop.hide()
    }
}
