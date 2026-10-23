import DirigibleCore
import Foundation

/// The speech runs of a duck (decision 0060), in timeline frames inside `scope`: the mix of the
/// `speech` tracks after the clip gain, the envelope, and the track gain, in the 50 ms windows of
/// `mixLevels` (decision 0062); a window whose RMS level is over `shape.threshold` dBFS is
/// speech, the runs are cut to `scope`, and `shape.merged` joins them (U19). Mute and solo do not
/// count, as for Auto Level (0039). A missing, short, or unreadable file is silence there, and
/// `unread` names it, sorted. `progress` gets the fraction of the scope done.
/// `isCancelled` is read before each second of audio; a cancel throws `ECANCELED`. No free
/// descriptor throws its errno. It blocks, so never call it on the main actor.
public func speechRuns(
    of speech: [TrackID], in session: Session, package: URL, scope: Range<Frames>, shape: DuckShape,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(POSIXError) -> (runs: [Range<Frames>], unread: [FileID]) {
    let read = try mixLevels(
        of: Set(speech), in: session, package: package, range: scope, silence: nil, progress: progress,
        isCancelled: isCancelled)
    let runs = read.series.runs(over: shape.threshold).map { $0.clamped(to: scope) }
    return (shape.merged(runs), read.unread)
}
