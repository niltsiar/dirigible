import DirigibleCore
import Foundation

/// The take of a device writer: its number, and the `Capture/` folder when a segment opens. The
/// package can move during a take (decision 0014), so the folder is a closure.
struct TakeFiles: Sendable {
    let take: Int
    let folder: @Sendable () throws(SessionFileError) -> URL
}
