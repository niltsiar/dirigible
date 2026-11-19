import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// The lag of a sync (decision 0076): the output of `syncLag` only.
public struct SyncResult: Hashable, Sendable {
    /// The move of the clip start in session frames.
    public let lag: Frames
    public let score: MatchScore
    public let drift: SyncDrift

    /// True when `spread` is over 20 ms at `rate`: then each result text gives the lag change
    /// (decision 0076, **Surface**).
    public static func spreadIsNotable(_ spread: Frames, rate: Int) -> Bool { spread.count * 1000 > 20 * rate }
}

/// The spread of the excerpt lags of a sync, or why the drift was not measured (decision 0076,
/// **Excerpts**).
public enum SyncDrift: Hashable, Sendable {
    /// The largest minus the smallest lag of the 2 or 3 excerpts that match.
    case spread(Frames)
    /// The clip is under 60 s, so it has one excerpt.
    case clipTooShort
    /// The clip has 3 excerpts and only one matched.
    case onePartMatched
}

/// Why `syncLag` gives no lag (decision 0076).
public enum SyncFailure: Error, Hashable, Sendable {
    /// No excerpt passed the match rule; `best` is the excerpt score with the largest peak.
    case noMatch(best: MatchScore)
    /// A file that the sync reads is missing or unreadable, so its clips would read as silence.
    case file(FileID, MediaFault)
    case cancelled
    /// No free descriptor or no memory, with its errno.
    case read(POSIXError)
}

/// The lag that moves `clip` onto its audio on `track` in `span`, a range of `Session.syncSpan`
/// (decision 0076, **Shared read** and **Streamed read**). The clip and the track are in
/// `session`. It checks the files that it reads first, then reads the 50 ms levels of the clip,
/// streams the reference mix through the decimator, and matches the excerpts. The reference is
/// the mix of `track` with mute and solo ignored; the clip is the clip alone, with its gain,
/// fades, and envelope. A `.short` file reads the frames that exist. `isCancelled` is read before
/// each second of audio and before each fine read. It blocks, so never call it on the main actor.
public func syncLag(
    of clip: ClipID, to track: TrackID, in session: Session, package: URL, span: Range<Frames>,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
) throws(SyncFailure) -> SyncResult {
    try syncLag(
        of: clip, to: track, in: session, package: package, span: span, progress: progress,
        isCancelled: isCancelled, open: openMedia)
}

/// `syncLag` with the open of each file and the make of each DFT setup, so that a test gives one that
/// fails.
func syncLag(
    of clip: ClipID, to track: TrackID, in session: Session, package: URL, span: Range<Frames>,
    progress: (Double) -> Void, isCancelled: () -> Bool, open: @escaping MediaOpen,
    makeSetup: DFTSetupMake = vDSP_DFT_zrop_CreateSetup
) throws(SyncFailure) -> SyncResult {
    let read = try syncRead(
        of: clip, to: track, in: session, package: package, span: span, progress: progress,
        isCancelled: isCancelled, open: open)
    return try read.result(isCancelled: isCancelled, makeSetup: makeSetup)
}

/// The read that `syncLag` and `driftMeasure` share (decision 0076, **Streamed read**; decision
/// 0077, D6): the 50 ms levels of the clip and the 2 kHz reference of the span, from one stream of
/// each, and the readers of the reads at the session rate.
struct SyncRead {
    let clipStart: Frames
    let clipLength: Int
    let span: Range<Frames>
    let rate: Int
    /// Window w holds the mean square of clip frames from w x `levelWindow`.
    let windowMeanSquares: [Float]
    let reference2k: [Float]
    let clipReader: MixReader
    let referenceReader: MixReader

    /// The frames of one 50 ms level window.
    static func levelWindow(rate: Int) -> Int { max(1, rate / 20) }

    var levelWindow: Int { Self.levelWindow(rate: rate) }
    var spanLength: Int { span.upperBound.count - span.lowerBound.count }

    /// The mono frames of clip `range`, from the clip start.
    func clipFrames(_ range: Range<Int>) throws(SyncFailure) -> [Float] {
        try renderMono(
            clipReader, clipStart + Frames(range.lowerBound)..<clipStart + Frames(range.upperBound), rate: rate)
    }

    /// The mono frames of reference `range`, from the span start.
    func referenceFrames(_ range: Range<Int>) throws(SyncFailure) -> [Float] {
        try renderMono(
            referenceReader, span.lowerBound + Frames(range.lowerBound)..<span.lowerBound + Frames(range.upperBound),
            rate: rate)
    }

    /// The move of the clip start when reference frame `lag` of the span plays clip frame 0.
    func move(_ lag: Int) -> Frames { span.lowerBound + Frames(lag) - clipStart }

    /// The reference frame of the span that plays clip frame 0 after a move of the clip start by `move`.
    func lag(_ move: Frames) -> Int { (clipStart + move - span.lowerBound).count }

    /// The match of decision 0076 on the excerpts of the clip. `isCancelled` is read before each fine read.
    func result(isCancelled: () -> Bool, makeSetup: DFTSetupMake) throws(SyncFailure) -> SyncResult {
        let match = try waveformMatch(
            clipLength: clipLength, windowMeanSquares: windowMeanSquares, rate: rate, reference2k: reference2k,
            referenceLength: spanLength,
            clipFrames: { range throws(SyncFailure) in
                if isCancelled() { throw .cancelled }
                return try clipFrames(range)
            },
            referenceFrames: { range throws(SyncFailure) in
                if isCancelled() { throw .cancelled }
                return try referenceFrames(range)
            },
            makeSetup: makeSetup)
        switch match {
        case .match(let lag, let score, let drift):
            return SyncResult(lag: move(lag), score: score, drift: drift)
        case .noMatch(let best):
            throw .noMatch(best: best)
        case .noMemory:
            throw .read(POSIXError(.ENOMEM))
        }
    }
}

/// The readers of a sync: the clip alone on its track, and the mix of `track`, both in
/// `Session.syncSource`.
func syncReaders(
    of clip: ClipID, to track: TrackID, in session: Session, package: URL, open: @escaping MediaOpen
) -> (clip: MixReader, reference: MixReader) {
    guard let (_, home) = session.clip(clip) else { preconditionFailure("syncSpan checks the clip") }
    let read = session.syncSource(clip)
    let chunk = LevelSeries.window(rate: session.sampleRate).count * 20
    return (
        MixReader(package: package, session: read, tracks: [home], open: open, span: chunk),
        MixReader(package: package, session: read, tracks: [track], open: open, span: chunk)
    )
}

/// The files check and the two streams of a sync. `progress` goes from 0 to 1 over the streams.
func syncRead(
    of clip: ClipID, to track: TrackID, in session: Session, package: URL, span: Range<Frames>,
    progress: (Double) -> Void, isCancelled: () -> Bool, open: @escaping MediaOpen
) throws(SyncFailure) -> SyncRead {
    guard let (target, home) = session.clip(clip) else { preconditionFailure("syncSpan checks the clip") }
    let read = session.syncSource(clip)
    let spanLength = span.upperBound.count - span.lowerBound.count
    guard let source = ExportSource(range: span, tracks: [home, track]) else {
        throw .noMatch(best: MatchScore(peak: 0, ratio: 0))
    }
    let faults: [FileID: MediaFault]
    do throws(POSIXError) { faults = try checkMedia(read, package: package, source: source, open: open) } catch {
        throw .read(error)
    }
    try refuse(faults)
    let rate = session.sampleRate
    let clipShare = Double(target.length.count) / Double(max(1, target.length.count + spanLength))
    let (clipReader, referenceReader) = syncReaders(
        of: clip, to: track, in: session, package: package, open: open)
    let window = SyncRead.levelWindow(rate: rate)
    var (squares, sum, filled): ([Float], Double, Int) = ([], 0, 0)
    squares.reserveCapacity(target.length.count / window + 1)
    try scanMono(
        clipReader, rate: rate, end: read.end, range: target.range, progress: { progress($0 * clipShare) },
        isCancelled: isCancelled,
        sink: { samples in
            for sample in samples {
                sum += Double(sample) * Double(sample)
                filled += 1
                if filled == window {
                    squares.append(Float(sum / Double(window)))
                    (sum, filled) = (0, 0)
                }
            }
        })
    if filled > 0 { squares.append(Float(sum / Double(filled))) }
    var decimator = Decimator(factor: matchFactor(rate: rate))
    var reference2k: [Float] = []
    reference2k.reserveCapacity(spanLength / decimator.factor + 1)
    try scanMono(
        referenceReader, rate: rate, end: read.end, range: span,
        progress: { progress(clipShare + $0 * (1 - clipShare)) }, isCancelled: isCancelled,
        sink: { samples in reference2k += decimator.feed(samples) })
    return SyncRead(
        clipStart: target.start, clipLength: target.length.count, span: span, rate: rate,
        windowMeanSquares: squares, reference2k: reference2k, clipReader: clipReader,
        referenceReader: referenceReader)
}

/// Refuses the first missing or unreadable file of `faults`; a short file reads what exists.
private func refuse(_ faults: [FileID: MediaFault]) throws(SyncFailure) {
    for (file, fault) in faults.sorted(by: { $0.key < $1.key }) {
        switch fault {
        case .missing, .unreadable: throw .file(file, fault)
        case .short: continue
        }
    }
}

/// `scanMix` of `range`, which gives `sink` the mono mix of each chunk, then the faults of the read.
private func scanMono(
    _ reader: MixReader, rate: Int, end: Frames, range: Range<Frames>, progress: (Double) -> Void,
    isCancelled: () -> Bool, sink: (UnsafeBufferPointer<Float>) -> Void
) throws(SyncFailure) {
    var mono = [Float](repeating: 0, count: LevelSeries.window(rate: rate).count * 20)
    do throws(POSIXError) {
        _ = try scanMix(
            reader, rate: rate, end: end, range: range, silence: nil,
            sink: { buffer in
                mono.withUnsafeMutableBufferPointer { mono in
                    downmix(buffer, into: mono.baseAddress!)
                    sink(UnsafeBufferPointer(rebasing: mono[0..<Int(buffer.frameLength)]))
                }
            }, progress: progress, isCancelled: isCancelled)
    } catch {
        throw error.code == .ECANCELED ? .cancelled : .read(error)
    }
    try refuse(reader.faults)
}

/// The mono mix of `range` at the session rate, then the faults of the read.
func renderMono(_ reader: MixReader, _ range: Range<Frames>, rate: Int) throws(SyncFailure) -> [Float] {
    let count = range.upperBound.count - range.lowerBound.count
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
    else { throw .read(POSIXError(.ENOMEM)) }
    reader.render(range, into: buffer)
    if let error = reader.openError { throw .read(error) }
    try refuse(reader.faults)
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer { downmix(buffer, into: $0.baseAddress!) }
    return out
}

/// The mean of the two channels of `buffer` into `out`, which holds its frames.
private func downmix(_ buffer: AVAudioPCMBuffer, into out: UnsafeMutablePointer<Float>) {
    var half: Float = 0.5
    vDSP_vasm(
        buffer.floatChannelData![0], 1, buffer.floatChannelData![1], 1, &half, out, 1,
        vDSP_Length(buffer.frameLength))
}
