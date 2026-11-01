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
    /// A stereo split failed or was cancelled (decision 0053). The session did not change.
    case split(SplitError)
    /// A take in another studio ended a stereo split (decisions 0019 and 0053). The session did not
    /// change.
    case splitYielded
    /// A clip render failed or was cancelled (decision 0054). The session did not change.
    case clipRender(ClipRenderError)
    /// A take in another studio ended a clip render (decisions 0019 and 0054). The session did not
    /// change.
    case clipRenderYielded
    /// A ripple under a pending or split take (decision 0037). Nothing changed.
    case rippleBlocked
    /// The artwork import refused the image or failed (decision 0045). The session did not change.
    case artwork(ArtworkError)
    /// Remove Unused Files could not scan or save (decision 0047). No file moved.
    case unusedFiles(UnusedFilesError)
    /// The user or the caller cancelled a level (decision 0049). No gain changed.
    case levelCancelled
    /// The user or the caller cancelled a duck (decision 0060). No envelope changed.
    case duckCancelled
    /// A take start ended an agent read by time (decision 0062).
    case readYielded
    /// The close of the window (`settle()`) ended an agent read by time (decision 0062).
    case readClosed
    /// A transcription job failed (decision 0065). The session did not change.
    case transcription(TranscribeError)
    /// A take start in this or another studio ended a transcription job (decision 0065). The
    /// session did not change.
    case transcriptionYielded
    /// The banner Cancel, a cancel of the caller, or the close of the window ended a transcription
    /// job (decision 0065). The session did not change.
    case transcriptionCancelled
    /// A duck could not open an audio file: no free descriptor, with its errno (decision 0016).
    case duckRead(Int32)
    /// The banner Cancel or a cancel of the caller ended a silence scan (decision 0066).
    case silencesCancelled
    /// A silence scan could not open an audio file: no free descriptor, with its errno (decision
    /// 0066).
    case silencesRead(Int32)
    /// The tracks or the pool files changed after the silence scan, so Apply changed nothing. The
    /// window shows such a list as out of date, with Apply off, until the user scans again (decision
    /// 0066).
    case silencesStale
    /// Files of a silence scan are missing, short, or unreadable: their clips would read as
    /// silence, so the scan gives no row (decisions 0062 and 0066).
    case silencesFaults([FileID: MediaFault])
    /// The writer of the named device or app did not stop by the stop deadline (decision 0030).
    /// The take stays pending with its audio on disk, and Retry Finalize waits for it again.
    case writerDidNotStop(String)
}
