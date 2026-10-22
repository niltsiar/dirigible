import AVFoundation
import Accelerate
import DirigibleCore

/// The speech runs of a duck (decision 0060), in timeline frames inside `scope`: the mix of the
/// `speech` tracks after the clip gain, the envelope, and the track gain, in 50 ms windows; a window
/// whose RMS level is over `shape.threshold` dBFS is speech, and `shape.merged` joins the runs
/// (U19). Mute and solo do not count, as for Auto Level (0039): `MixReader` reads a
/// copy of the session with the flags off, so `Session.heardTracks(in:)` stays the one heard rule.
/// A missing or unreadable file is silence. `progress` gets the fraction of the scope done.
/// `isCancelled` is read before each second of audio; a cancel throws `ECANCELED`. No free
/// descriptor throws its errno. It blocks, so never call it on the main actor.
public func speechRuns(
    of speech: [TrackID], in session: Session, package: URL, scope: Range<Frames>, shape: DuckShape,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(POSIXError) -> [Range<Frames>] {
    var copy = session
    let all = session.tracks.map(\.id)
    // Each ID is in the session, so neither edit can throw.
    try? copy.setMuted(false, tracks: all)
    try? copy.setSoloed(false, tracks: all)
    let reader = MixReader(package: package, session: copy, tracks: Set(speech))
    let window = max(1, session.sampleRate / 20)
    let chunk = window * 20
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(session.sampleRate), channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))
    else { return [] }
    // The mean square of the threshold: 10^(dBFS / 10).
    let limit = Float(pow(10, shape.threshold.dB / 10))
    let total = Double(max(1, scope.upperBound.count - scope.lowerBound.count))
    var runs: [Range<Frames>] = []
    var open: Int?
    var start = scope.lowerBound.count
    while start < scope.upperBound.count {
        if isCancelled() { throw POSIXError(.ECANCELED) }
        let end = min(start + chunk, scope.upperBound.count)
        reader.render(Frames(start)..<Frames(end), into: buffer)
        if let error = reader.openError { throw error }
        var first = 0
        while first < end - start {
            let count = min(window, end - start - first)
            var (left, right): (Float, Float) = (0, 0)
            vDSP_svesq(buffer.floatChannelData![0] + first, 1, &left, vDSP_Length(count))
            vDSP_svesq(buffer.floatChannelData![1] + first, 1, &right, vDSP_Length(count))
            let frame = start + first
            if (left + right) / Float(2 * count) > limit {
                if open == nil { open = frame }
            } else if let begin = open {
                runs.append(Frames(begin)..<Frames(frame))
                open = nil
            }
            first += count
        }
        start = end
        progress(Double(start - scope.lowerBound.count) / total)
    }
    if let begin = open { runs.append(Frames(begin)..<scope.upperBound) }
    return shape.merged(runs)
}
