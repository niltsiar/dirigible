import AppKit

/// A drag of audio files from the Finder over the lanes (run 13c). It holds the files of the drag
/// from the drag enter to the end of the drag session.
final class LaneDrop {
    /// The audio files of the drag: the files of `AppDelegate.importTypes`, in the drag order.
    var urls: [URL] = []
}
