import AppKit
import Foundation

@testable import DirigibleApp

/// The pasteboard of the fake drags. A test writes it and enters the drag with no await between.
@MainActor let dropBoard = NSPasteboard.withUniqueName()

/// A drag of `urls` at the lane point `point` of `view`.
@MainActor func fileDrag(_ urls: [URL], at point: NSPoint, in view: TimelineScrollView) -> FakeDrag {
    dropBoard.clearContents()
    dropBoard.writeObjects(urls.map { $0 as NSURL })
    return FakeDrag(dropBoard, at: view.lanes.convert(point, to: nil))
}

/// A drag that AppKit would give, with a pasteboard and a window point only (probe P5).
@MainActor final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    var numberOfValidItemsForDrop = 0

    init(_ pasteboard: NSPasteboard, at point: NSPoint) { (draggingPasteboard, draggingLocation) = (pasteboard, point) }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// A 16-bit WAV of 1 s of silence at 48 kHz with `channels` channels.
func writeSilentWAV(_ url: URL, channels: Int) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let bytes = 48_000 * channels * 2
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(channels))
    append(UInt32(48_000))
    append(UInt32(48_000 * channels * 2))
    append(UInt16(channels * 2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(bytes))
    data.append(Data(count: bytes))
    try data.write(to: url)
}

extension LaneDrop {
    /// No layer of the drop cue shows.
    var cueHidden: Bool { [tint, line, row, text].allSatisfy(\.isHidden) }
}
