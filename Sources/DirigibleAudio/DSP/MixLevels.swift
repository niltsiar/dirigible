import AVFoundation
import Accelerate
import DirigibleCore

/// The heard stereo mix of `range` of `session`, as a stereo export of that range (decision 0062):
/// the values of `MixMeasure` of the frames of `range` exactly, and the window levels of the
/// range on the grid of `LevelSeries`. Mute and solo count (decision 0039): `tracks` nil is each
/// heard track. A missing, short, or unreadable file is silence there, and `unread` names it,
/// sorted. `progress` gets the fraction done. `isCancelled` is read before each second of audio; a
/// cancel throws `ECANCELED`. No free descriptor throws its errno. It blocks, so never call it on
/// the main actor.
public func measureMix(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(POSIXError) -> (measure: MixMeasure, series: LevelSeries, unread: [FileID]) {
    let reader = MixReader(package: package, session: session, tracks: tracks)
    var meter = RangeMeter(sampleRate: session.sampleRate)
    let series = try scanMix(
        reader, rate: session.sampleRate, end: session.end, range: range, silence: nil, sink: { meter.feed($0) },
        progress: progress, isCancelled: isCancelled)
    return (meter.result(), series, reader.faults.keys.sorted())
}

/// The window levels of the mix of `tracks` (nil: every track) in `range` of `session`, on the
/// grid of `LevelSeries` (decision 0062): the read of `silences`, `nearest_pause`, and the duck.
/// The clip gain, the fades, the envelope, and the track gain count; mute and solo do not, as
/// for the duck and Auto Level (decision 0039): `MixReader` reads a copy of the session with
/// the flags off. With `silence`, the scan reads past each edge of `range` until the run of
/// windows at or under `silence` dBFS that crosses the edge ends, or the session edge, so each
/// silence that meets `range` has its whole extent; nil reads `range` only. A missing, short, or
/// unreadable file is silence there, and `unread` names it, sorted. `progress` gets the fraction
/// of `range` done. `isCancelled` is read before each second of audio; a cancel throws
/// `ECANCELED`. No free descriptor throws its errno. It blocks, so never call it on the main actor.
public func mixLevels(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>, silence: Gain?,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(POSIXError) -> (series: LevelSeries, unread: [FileID]) {
    var copy = session
    let all = session.tracks.map(\.id)
    // Each ID is in the session, so neither edit can throw.
    try? copy.setMuted(false, tracks: all)
    try? copy.setSoloed(false, tracks: all)
    let reader = MixReader(package: package, session: copy, tracks: tracks)
    let series = try scanMix(
        reader, rate: session.sampleRate, end: session.end, range: range, silence: silence, sink: { _ in },
        progress: progress, isCancelled: isCancelled)
    return (series, reader.faults.keys.sorted())
}

/// The one chunk loop of the reads and the duck. It renders the mix of `reader` in chunks of 20
/// windows of 50 ms from the grid window of `range.lowerBound` up to the grid frame after
/// `range.upperBound`, or up to `end` (the session end) when that comes first, and gives `sink`
/// the frames of `range` only. With `silence`, while the edge window is at or under `silence`
/// dBFS, it renders one more chunk past that edge, up to a chunk with a louder window, frame 0,
/// or `end`. The window level is the mean of the L and R mean squares and the largest absolute
/// sample. A buffer that does not allocate throws `ENOMEM`.
private func scanMix(
    _ reader: MixReader, rate: Int, end: Frames, range: Range<Frames>, silence: Gain?,
    sink: (AVAudioPCMBuffer) -> Void, progress: (Double) -> Void, isCancelled: () -> Bool
) throws(POSIXError) -> LevelSeries {
    let window = max(1, rate / 20)
    let chunk = window * 20
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
        let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))
    else { throw POSIXError(.ENOMEM) }
    let first = range.lowerBound.count / window * window
    let last = min(
        (range.upperBound.count + window - 1) / window * window, max(range.upperBound.count, end.count))
    var levels: [WindowLevel] = []
    levels.reserveCapacity((last - first + window - 1) / window)
    let total = Double(max(1, last - first))
    /// Renders `frames` into `buffer` and gives the levels of its windows.
    func chunkLevels(_ frames: Range<Int>) throws(POSIXError) -> [WindowLevel] {
        if isCancelled() { throw POSIXError(.ECANCELED) }
        reader.render(Frames(frames.lowerBound)..<Frames(frames.upperBound), into: buffer)
        if let error = reader.openError { throw error }
        return windowLevels(of: buffer, window: window)
    }
    var start = first
    while start < last {
        let stop = min(start + chunk, last)
        levels += try chunkLevels(start..<stop)
        let (low, high) = (max(start, range.lowerBound.count), min(stop, range.upperBound.count))
        if low == start, high == stop {
            sink(buffer)
        } else if low < high {
            for channel in 0..<2 {
                part.floatChannelData![channel].update(
                    from: buffer.floatChannelData![channel] + (low - start), count: high - low)
            }
            part.frameLength = AVAudioFrameCount(high - low)
            sink(part)
        }
        start = stop
        progress(Double(start - first) / total)
    }
    var (low, high) = (first, last)
    if let silence, let firstLevel = levels.first, let lastLevel = levels.last {
        let limit = LevelSeries.limit(silence)
        var before: [[WindowLevel]] = []
        var quiet = firstLevel.meanSquare <= limit
        while quiet, low > 0 {
            let part = try chunkLevels(max(0, low - chunk)..<low)
            (low, quiet) = (max(0, low - chunk), part.allSatisfy { $0.meanSquare <= limit })
            before.append(part)
        }
        quiet = lastLevel.meanSquare <= limit
        while quiet, high < end.count {
            let part = try chunkLevels(high..<min(high + chunk, end.count))
            (high, quiet) = (min(high + chunk, end.count), part.allSatisfy { $0.meanSquare <= limit })
            levels += part
        }
        levels = before.reversed().flatMap { $0 } + levels
    }
    // The loops give one level for each window of the grid range.
    return LevelSeries(range: Frames(low)..<Frames(high), window: Frames(window), levels: levels)!
}

/// The level of each window of `buffer` from its first frame; the last window can be short.
private func windowLevels(of buffer: AVAudioPCMBuffer, window: Int) -> [WindowLevel] {
    let frames = Int(buffer.frameLength)
    let (left, right) = (buffer.floatChannelData![0], buffer.floatChannelData![1])
    return stride(from: 0, to: frames, by: window).map { first in
        let count = vDSP_Length(min(window, frames - first))
        var (leftSum, rightSum, leftPeak, rightPeak): (Float, Float, Float, Float) = (0, 0, 0, 0)
        vDSP_svesq(left + first, 1, &leftSum, count)
        vDSP_svesq(right + first, 1, &rightSum, count)
        vDSP_maxmgv(left + first, 1, &leftPeak, count)
        vDSP_maxmgv(right + first, 1, &rightPeak, count)
        return WindowLevel(meanSquare: (leftSum + rightSum) / Float(2 * Int(count)), peak: max(leftPeak, rightPeak))
    }
}
