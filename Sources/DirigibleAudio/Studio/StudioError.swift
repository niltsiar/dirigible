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
    /// A split export refused its targets or found no split point before its first write, or it
    /// stopped or failed after it (decision 0067). A split export never throws `.export` or
    /// `.exportYielded`; `exportStop` gives the cause of a stop.
    case exportParts(ExportPartsError)
    /// A preset set refused its targets or a rate before its first write, or it stopped or failed
    /// after it (decision 0080). A preset set never throws `.export` or `.exportYielded`;
    /// `exportStop` gives the cause of a stop.
    case exportPresets(ExportPresetsError)
    /// A stem export refused its folder before its job, or refused, stopped, or failed in its job.
    /// A stem export never throws `.export` or `.exportYielded`; `exportStop` gives the cause of a
    /// stop.
    case exportStems(ExportStemsError)
    /// A template copy (Save as Template, or a new session from a template) refused or stopped:
    /// `.cancelled` when a take start in its own studio, `settle()`, or Cancel ended it (decision 0079).
    case template(TemplateError)
    /// A take in another studio, or the take disk check of another studio, ended a template copy
    /// (decision 0079). Nothing was made.
    case templateYielded
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
    /// A session import from the package named `source` failed or was cancelled (decision 0075).
    /// The session did not change.
    case sessionImport(SessionImportError, source: String)
    /// A take in another studio ended the session import from the package named `source`
    /// (decisions 0019 and 0075). The session did not change.
    case sessionImportYielded(source: String)
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
    /// The banner Cancel or a cancel of the caller ended a Level Over Time. No ride changed.
    case rideCancelled
    /// A Level Over Time could not open an audio file: no free descriptor, with its errno.
    case rideRead(Int32)
    /// A source file of a Level Over Time is missing, short, or unreadable (also a NaN or an
    /// infinity in it). No ride changed.
    case rideFault(FileID, MediaFault)
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
    /// Match Voice found less than 10 s of gated voice on `side`: `seconds` is the voice found,
    /// in whole seconds rounded down, so it is never 10 (decision 0074). No track changed.
    case tooLittleVoice(side: MatchSide, seconds: Int)
    /// Match Voice leaves out music and effects tracks and the track of the reference clip, and no
    /// target track was left. No track changed.
    case noTargetTrack
    /// The range of a Match Voice is empty or not inside the reference clip, whose timeline frames
    /// are `clip`. No track changed.
    case rangeOutsideReference(clip: Range<Frames>)
    /// The banner Cancel or a cancel of the caller ended a Match Voice. No track changed.
    case matchCancelled
    /// A Match Voice could not open an audio file: no free descriptor, with its errno.
    case matchRead(Int32)
    /// A source file of a Match Voice is missing, short, or unreadable (also a NaN or an infinity
    /// in it). No track changed.
    case matchFault(FileID, MediaFault)
    /// No excerpt of the clip matched the reference track (decision 0076); `best` is the best
    /// excerpt score. No clip moved.
    case syncNoMatch(best: MatchScore)
    /// A file of a sync is missing or unreadable, so its clips would read as silence. No clip moved.
    case syncFile(FileID, MediaFault)
    /// A sync could not read an audio file: no free descriptor or no memory, with its errno.
    case syncRead(Int32)
    /// The banner Cancel or a cancel of the caller ended a sync. No clip moved.
    case syncCancelled
    /// The writer of the named device or app did not stop by the stop deadline (decision 0030).
    /// The take stays pending with its audio on disk, and Retry Finalize waits for it again.
    case writerDidNotStop(String)
    /// The output latency of the playback device did not read, so a pre-roll take did not start
    /// (decision 0070). Nothing changed.
    case outputTermUnavailable
    /// The take play of a pre-roll take stopped at its start with this stop, so the take did not
    /// start (decision 0070). Nothing changed.
    case preRollStopped(PlaybackStop)
    /// Another process, or a window of the store that the user opened, holds the lock of the
    /// Favorites store (decision 0081). The store did not change.
    case favoritesLocked
    /// The store `session.xml` does not read as a session of this build: a parse error, a model
    /// error, or a newer version; nil for a store that holds a take. The store did not change.
    case favoritesDamaged(SessionFileError?)
    /// Another read or write fault of the Favorites store. The store did not change.
    case favoritesFile(SessionFileError)
    /// A copy into the Favorites store failed, or the disk of the store is full; `.cancelled` for a
    /// Cancel of the add. The store did not change.
    case favoritesCopy(PasteError)
    /// A take in another studio stopped the add to Favorites (decision 0019).
    case favoritesYielded
}
