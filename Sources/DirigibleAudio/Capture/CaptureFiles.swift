import DirigibleCore
import Foundation

extension UnusedFiles {
    /// The scan of decision 0047, with the capture files of each free capture as `.capture` items.
    package init(
        scanningWithCaptures session: Session, keptBy keepers: [Session], keptFiles: [String] = [], in package: URL
    )
        throws(UnusedFilesError)
    {
        self = try UnusedFiles(scanning: session, keptBy: keepers, keptFiles: keptFiles, in: package)
            .listingCaptureFiles(captureFilePaths, in: package)
    }
}

/// The capture files of `capture` relative to the package: the CAF, then the sidecar, in
/// `Capture/` (decision 0004). A capture ID of `session.xml` that is not a segment stem gives
/// none, so no ID names a path outside `Capture/`.
func captureFilePaths(_ capture: CaptureID) -> [String] {
    guard let segment = SegmentName(stem: capture.rawValue) else { return [] }
    return [segment.cafName, segment.sidecarName].map { "\(captureFolderName)/\($0)" }
}
