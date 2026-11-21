import DirigibleAudio
import DirigibleCore
import Foundation

/// The clip of a follow track that a refused ripple would have moved over another clip: its track and
/// its start before the edit.
struct FollowOverlap: Hashable {
    let track: TrackID
    let trackName: String
    let start: Frames
    let rate: Int

    /// `table` gives the format of a key: the tests read the tables, which `Bundle.main` lacks.
    func title(table: (L10n) -> String = { $0.text }) -> String { table(.alertFollowOverlapTitle) }

    func body(locale: Locale = .current, table: (L10n) -> String = { $0.text }) -> String {
        String(
            format: table(.alertFollowOverlapBody), locale: locale, trackName,
            SilenceReview.clock(start, rate: rate))
    }
}

/// A question or an error that the window shows.
enum WindowAlert: Hashable {
    case error(StudioError)
    /// The end of an import of several files (run 13c): the error of each file that did not
    /// import, in the drop order, and the names of the files after a stop of the chain.
    case importChain([StudioError], notImported: [String])
    case microphone(MicrophoneAccess)
    /// A ripple would move a clip of a follow track over another clip (decision 0073).
    case followOverlap(FollowOverlap)
    case confirmStopAndClose
    case confirmUnsavedClose
    /// Remove Track of tracks with clips (ui-polish A1). The alert holds the IDs: the binding sets
    /// `alert` to nil before the button action runs.
    case confirmRemoveTracks([TrackID])
    /// The report after an export: the paths of the files that rendered as silence (decision 0003),
    /// and the loudness of an export with a target (decision 0032).
    case exported([String], LoudnessReport?)
    /// The report after a split export whose media was bad (decision 0067): the paths of the media
    /// files, and the names of the part files that have silence from them.
    case exportedSet(media: [String], parts: [String])
    /// Remove Unused Files found no file to move (decision 0047). The scan gives the kept files,
    /// the damaged backups, and the pool entries that are not a regular file.
    case noUnusedFiles(UnusedFiles)
    /// File > Export Transcript wrote no file.
    case transcriptExport(TranscriptExportError)
    /// File > Import Transcript changed nothing: the text of the reason.
    case transcriptImport(String)
    /// A placement made a pool file with no clip: the segment ends before the take playhead.
    case placedWithNoClip(SegmentName)
    /// A job with a model file of the user failed because of the file (C28). Locate... starts
    /// `request` again with a picked file.
    case transcribeFile(StudioError, TranscribeRequest)
    /// The model download got no data (C27). Choose Model File... starts `request` with a picked
    /// file.
    case transcribeNoData(StudioError, TranscribeRequest)
    /// Replace in Save as Template could not move the old template, named here, to the Trash.
    case templateTrash(String)

    /// The alert of a failed transcription job of `request`. Only a fault of the model file of the
    /// user gives Locate...: a missing helper, a helper that does not start, and an engine error
    /// are faults of the install or the audio.
    static func transcribe(_ error: StudioError, _ request: TranscribeRequest) -> WindowAlert {
        guard case .transcription(let fault) = error else { return .error(error) }
        switch fault {
        case .modelDownloadNoData: return .transcribeNoData(error, request)
        case .modelChanged, .modelFile(.unreadable), .modelFile(.refused), .modelFile(.helperStopped),
            .modelFile(.changedDuringCheck):
            guard case .file = request.model else { return .error(error) }
            return .transcribeFile(error, request)
        default: return .error(error)
        }
    }

    /// The alert of a refused edit on `session`, the session before the edit: the follow alert for a
    /// follow overlap, else the error alert.
    static func refusing(_ error: StudioError, in session: Session) -> WindowAlert {
        guard case .session(.followOverlap(let clip, _)) = error, let found = session.clip(clip),
            let track = session.track(found.track)
        else { return .error(error) }
        return .followOverlap(
            FollowOverlap(track: track.id, trackName: track.name, start: found.clip.start, rate: session.sampleRate))
    }

    /// The button beside OK that opens the open panel of a model file, else nil.
    var pickButton: L10n? {
        switch self {
        case .transcribeFile: .alertTranscribeLocate
        case .transcribeNoData: .sheetTranscribeChoose
        default: nil
        }
    }
}
