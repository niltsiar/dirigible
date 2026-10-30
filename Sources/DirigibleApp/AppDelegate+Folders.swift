import DirigibleAudio
import Foundation

extension AppDelegate {
    /// The list of active recordings and the peak cache of the app with `bundleID`, in the folders
    /// `support` and `caches`. An executable with no Info.plist (`swift run DirigibleApp`) has no
    /// bundle ID and gets the folders of the real app.
    nonisolated static func folders(bundleID: String?, support: URL, caches: URL) -> (recordings: URL, peakCache: URL) {
        let id = bundleID ?? "com.delineas.dirigible"
        return (ActiveRecordings.file(bundleID: id, support: support), PeakFile.folder(bundleID: id, caches: caches))
    }
}
