import AVFoundation
import Accelerate
import DirigibleCore

/// The heard stereo mix of `range` of `session`, as a stereo export of that range (decision 0062):
/// the values of `MixMeasure` of the frames of `range` exactly, and the window levels of the
/// range on the grid of `LevelSeries`. Mute and solo count (decision 0039): `tracks` nil is each
/// heard track. A missing, short, or unreadable file is silence there, and `faults` gives its
/// fault. `progress` gets the fraction done. `isCancelled` is read before each second of audio; a
/// cancel throws `ECANCELED`. No free descriptor throws its errno. It blocks, so never call it on
/// the main actor.
public func measureMix(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(POSIXError) -> (measure: MixMeasure, series: LevelSeries, faults: [FileID: MediaFault]) {
    let reader = MixReader(package: package, session: session, tracks: tracks)
    var meter = RangeMeter(sampleRate: session.sampleRate)
    let series = try scanMix(
        reader, rate: session.sampleRate, end: session.end, range: range, silence: nil, sink: { meter.feed($0) },
        progress: progress, isCancelled: isCancelled)
    return (meter.result(), series, reader.faults)
}

/// The window levels of the mix of `tracks` (nil: every track) in `range` of `session`, on the
/// grid of `LevelSeries` (decision 0062): the read of `silences`, `nearest_pause`, and the duck.
/// The clip gain, the fades, the envelope, and the track gain count; mute and solo do not, as
/// for the duck and Auto Level (decision 0039): `MixReader` reads `session.ignoringMuteAndSolo`.
/// With `silence`, the scan reads past each edge of `range` until the run of windows at or under
/// `silence` dBFS that crosses the edge ends, the session edge, or `LevelSeries.edgeWindows`
/// windows past the edge, so each silence that meets `range` has its whole extent up to that
/// limit. A silence that reaches an edge of the series that is not a session edge can go on
/// past the limit. Nil reads `range` only. A missing, short, or unreadable file is silence
/// there, and `faults` gives its fault. `progress` gets the fraction of the most frames that the
/// scan can read. `isCancelled` is read before each second of audio; a cancel throws
/// `ECANCELED`. No free descriptor throws its errno. It blocks, so never call it on the main actor.
public func mixLevels(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>, silence: Gain?,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(POSIXError) -> (series: LevelSeries, faults: [FileID: MediaFault]) {
    try mixLevels(
        of: tracks, in: session, package: package, range: range, silence: silence, progress: progress,
        isCancelled: isCancelled, open: openMedia)
}

/// `mixLevels` with the open of each file, so that `checkedMixLevels` and a test give theirs.
func mixLevels(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>, silence: Gain?,
    progress: (Double) -> Void, isCancelled: () -> Bool, open: @escaping MediaOpen
) throws(POSIXError) -> (series: LevelSeries, faults: [FileID: MediaFault]) {
    let reader = MixReader(package: package, session: session.ignoringMuteAndSolo, tracks: tracks, open: open)
    let series = try scanMix(
        reader, rate: session.sampleRate, end: session.end, range: range, silence: silence, sink: { _ in },
        progress: progress, isCancelled: isCancelled)
    return (series, reader.faults)
}

/// Why `checkedMixLevels` gives no series (decision 0066). Each case keeps the step that stopped.
public enum CheckedReadError: Error, Hashable, Sendable {
    /// The media check found no free descriptor.
    case check(POSIXError)
    /// The read found no free descriptor or no memory, or it was cancelled (`ECANCELED`).
    case read(POSIXError)
    /// A file of the read is missing, short, or unreadable, in the media check or in the read.
    case faults([FileID: MediaFault])
    /// The range is empty or past `Frames.limit`, or `tracks` is empty.
    case badSource
}

/// The window levels of `mixLevels` with the fault rule of decision 0062: the media check of the
/// files of `tracks` in `range` on `Session.ignoringMuteAndSolo`, then the read, then the faults
/// of the read. A fault refuses the levels, because its clips would read as silence. An empty
/// `range`, a `range` past `Frames.limit`, and an empty `tracks` throw `.badSource`. It blocks, so
/// never call it on the main actor.
public func checkedMixLevels(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>, silence: Gain?,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(CheckedReadError) -> LevelSeries {
    try checkedMixLevels(
        of: tracks, in: session, package: package, range: range, silence: silence, progress: progress,
        isCancelled: isCancelled, open: openMedia)
}

/// `checkedMixLevels` with the open of each file, for the media check and the read.
func checkedMixLevels(
    of tracks: Set<TrackID>?, in session: Session, package: URL, range: Range<Frames>, silence: Gain?,
    progress: (Double) -> Void, isCancelled: () -> Bool, open: @escaping MediaOpen
) throws(CheckedReadError) -> LevelSeries {
    guard let source = ExportSource(range: range, tracks: tracks) else { throw .badSource }
    let faults: [FileID: MediaFault]
    do throws(POSIXError) {
        faults = try checkMedia(session.ignoringMuteAndSolo, package: package, source: source, open: open)
    } catch {
        throw .check(error)
    }
    guard faults.isEmpty else { throw .faults(faults) }
    let read: (series: LevelSeries, faults: [FileID: MediaFault])
    do throws(POSIXError) {
        read = try mixLevels(
            of: tracks, in: session, package: package, range: range, silence: silence, progress: progress,
            isCancelled: isCancelled, open: open)
    } catch {
        throw .read(error)
    }
    guard read.faults.isEmpty else { throw .faults(read.faults) }
    return read.series
}

/// The one chunk loop of the reads and the duck. It renders the mix of `reader` in chunks of 20
/// windows of 50 ms from the grid window of `range.lowerBound` up to the grid frame after
/// `range.upperBound`, or up to `end` (the session end) when that comes first, and gives `sink`
/// the frames of `range` only. With `silence`, while the edge window is at or under `silence`
/// dBFS, it renders one more chunk past that edge, up to a chunk with a louder window, frame 0,
/// `end`, or `LevelSeries.edgeWindows` windows past the edge. The window level is the mean of
/// the L and R mean squares and the largest absolute sample. A buffer that does not allocate
/// throws `ENOMEM`.
private func scanMix(
    _ reader: MixReader, rate: Int, end: Frames, range: Range<Frames>, silence: Gain?,
    sink: (AVAudioPCMBuffer) -> Void, progress: (Double) -> Void, isCancelled: () -> Bool
) throws(POSIXError) -> LevelSeries {
    let window = LevelSeries.window(rate: rate).count
    let chunk = window * 20
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
        let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))
    else { throw POSIXError(.ENOMEM) }
    let grid = LevelSeries.grid(of: range, rate: rate, end: end)
    let (first, last) = (grid.lowerBound.count, grid.upperBound.count)
    var levels: [WindowLevel] = []
    levels.reserveCapacity((last - first + window - 1) / window)
    // With `silence`, the edge loops read up to `LevelSeries.edgeWindows` windows past each edge.
    let reach = silence == nil ? 0 : LevelSeries.edgeWindows * window
    let (lowest, highest) = (max(0, first - reach), max(last, min(last + reach, end.count)))
    let total = Double(max(1, highest - lowest))
    var done = 0
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
        (start, done) = (stop, done + stop - start)
        progress(Double(done) / total)
    }
    var (low, high) = (first, last)
    if let silence, let firstLevel = levels.first, let lastLevel = levels.last {
        let limit = LevelSeries.limit(silence)
        var before: [[WindowLevel]] = []
        var quiet = firstLevel.meanSquare <= limit
        while quiet, low > lowest {
            let next = max(lowest, low - chunk)
            let part = try chunkLevels(next..<low)
            (low, quiet, done) = (next, part.allSatisfy { $0.meanSquare <= limit }, done + low - next)
            before.append(part)
            progress(Double(done) / total)
        }
        quiet = lastLevel.meanSquare <= limit
        while quiet, high < highest {
            let next = min(high + chunk, highest)
            let part = try chunkLevels(high..<next)
            (high, quiet, done) = (next, part.allSatisfy { $0.meanSquare <= limit }, done + next - high)
            levels += part
            progress(Double(done) / total)
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
