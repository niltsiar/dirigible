import DirigibleAudio
import DirigibleCore

/// A question or an error that the window shows.
enum WindowAlert: Hashable {
    case error(StudioError)
    /// The end of an import of several files (run 13c): the error of each file that did not
    /// import, in the drop order, and the names of the files after a stop of the chain.
    case importChain([StudioError], notImported: [String])
    case microphone(MicrophoneAccess)
    case confirmStopAndClose
    case confirmUnsavedClose
    /// Remove Track of tracks with clips (ui-polish A1). The alert holds the IDs: the binding sets
    /// `alert` to nil before the button action runs.
    case confirmRemoveTracks([TrackID])
    /// The report after an export: the paths of the files that rendered as silence (decision 0003),
    /// and the loudness of an export with a target (decision 0032).
    case exported([String], LoudnessReport?)
}
