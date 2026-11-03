import DirigibleCore
import Foundation

/// The capture files of `capture` relative to the package: the CAF, then the sidecar, in
/// `Capture/` (decision 0004). The prune of decision 0047 lists and moves these. A capture ID of
/// `session.xml` that is not a segment stem gives none, so no ID names a path outside `Capture/`.
package func captureFilePaths(_ capture: CaptureID) -> [String] {
    guard let segment = SegmentName(stem: capture.rawValue) else { return [] }
    return ["caf", "sidecar"].map { "\(captureFolderName)/\(segment.stem).\($0)" }
}
