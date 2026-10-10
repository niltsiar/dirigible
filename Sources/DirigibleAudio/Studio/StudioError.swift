import DirigibleCore

public enum StudioError: Error, Hashable, Sendable {
    /// A take records or finalizes, a new take waits for a pending take, an export or an import
    /// runs, or `settle()` runs.
    case busy
    /// Another studio or the CLI has the package.
    case locked
    /// The armed track has no route.
    case noRoute(TrackID)
    /// The route of the armed track names a device that is not in the list.
    case deviceMissing(TrackID)
    /// The route of the armed track names a channel that the device does not have.
    case channelOutOfRange(TrackID)
    /// Two armed tracks route the same device channel, or the same app: the first track and the
    /// second.
    case channelInUse(TrackID, TrackID)
    /// An armed track has an app route, and this macOS has no process taps (14.0 and 14.1).
    case appSourcesUnavailable
    case session(SessionError)
    case file(SessionFileError)
    case finalize(FinalizeError)
    /// A placement refused the segment (decision 0021). Nothing changed.
    case segment(SegmentName, SegmentFault)
    /// The front end requests the access and starts again (decision 0013).
    case microphoneAccess(MicrophoneAccess)
    /// Less than 1 GB is free (decision 0004).
    case diskLow
    /// A placement needs `needed` free bytes, the WAV and the 1 GB margin, and the volume has
    /// `free` (decision 0021). Nothing changed.
    case placementSpace(needed: Int64, free: Int64)
    /// The export failed or was cancelled (decision 0019).
    case export(ExportError)
    /// A take in another studio ended the export (decision 0019). No file was made.
    case exportYielded
    /// The import failed or was cancelled (decision 0040).
    case audioImport(ImportError)
    /// A take in another studio ended the import of `file` (decisions 0019 and 0040). The session
    /// did not change.
    case importYielded(file: String)
    /// A paste from the package named `source` failed or was cancelled (decision 0042). The session
    /// did not change.
    case paste(PasteError, source: String)
    /// A take in another studio ended the paste from the package named `source` (decisions 0019
    /// and 0042). The session did not change.
    case pasteYielded(source: String)
    /// A ripple under a pending or split take (decision 0037). Nothing changed.
    case rippleBlocked
}
