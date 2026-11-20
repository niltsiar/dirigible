import Accelerate
import DirigibleCore
import Foundation

/// The 0076 lag of a clip and its drift points, from one read (decision 0077, D6).
struct DriftMeasure {
    let sync: SyncResult
    /// By clip frame.
    let points: [DriftPoint]
}

/// The seconds of a cell of the clip and of its window (decision 0077, D6).
private let cellSeconds = 60
private let windowSeconds = 10
/// A window searches the reference this many seconds on each side of the expected lag.
private let searchSeconds = 60
/// A run of this many windows with no match, or a run at the clip start or end, gets one search
/// over the whole span. A run at an end has no point after it to place the line there.
private let lostRunCount = 3
/// The fine step correlates blocks of this many seconds. Across a 10 s window the lag moves by up to
/// 10 ms at `DriftRatio.limit`, and one correlation of the whole window peaks at the lag of its
/// loudest part, not at the lag of its center.
private let blockSeconds = 1
/// A block whose fine peak is under the peak bar of the 0076 match rule gives no lag.
private let blockPeak = 0.2

/// The drift measure of `clip` against `track` in `span`, a range of `Session.syncSpan` (decision
/// 0077, D6). One read gives the 0076 lag and the 50 ms levels and the 2 kHz reference that the
/// windows search: the loudest 10 s of each 60 s cell of the clip, within 60 s of the 0076 lag, with
/// the 0076 match rule. A run of 3 or more windows with no match, and a run of any length at the
/// clip start or end, gets one search of its loudest window over the whole span, and a match there centers the search of the run. The fine step at the
/// session rate finds the lag of each 1 s block of a matched window, within the window smear at
/// `DriftRatio.limit` of the coarse lag. A point is the mean clip frame of the block centers and the
/// mean lag of the blocks. A silent window gives no point.
func driftMeasure(
    of clip: ClipID, to track: TrackID, in session: Session, package: URL, span: Range<Frames>,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }, open: @escaping MediaOpen = openMedia,
    makeSetup: DFTSetupMake = vDSP_DFT_zrop_CreateSetup
) throws(SyncFailure) -> DriftMeasure {
    guard let (target, _) = session.clip(clip) else { preconditionFailure("syncSpan checks the clip") }
    let rate = session.sampleRate
    let clipLength = target.length.count
    let cells = stride(from: 0, to: clipLength, by: cellSeconds * rate).map {
        $0..<min(clipLength, $0 + cellSeconds * rate)
    }
    let readWork = Double(clipLength + span.upperBound.count - span.lowerBound.count)
    let readShare = readWork / (readWork + Double(cells.count * 2 * windowSeconds * rate))
    let read = try syncRead(
        of: clip, to: track, in: session, package: package, span: span, progress: { progress($0 * readShare) },
        isCancelled: isCancelled, open: open)
    let sync = try read.result(isCancelled: isCancelled, makeSetup: makeSetup)
    let squares = read.windowMeanSquares
    let levelWindow = read.levelWindow
    func level(_ range: Range<Int>) -> Double {
        let windows = range.lowerBound / levelWindow..<min(squares.count, range.upperBound / levelWindow)
        return squares[windows].reduce(0.0) { $0 + Double($1) }
    }
    let windows = cells.compactMap { cell in
        loudestRange(in: cell, length: windowSeconds * rate, windowMeanSquares: squares, window: levelWindow)
    }.filter { level($0) > 0 }
    let factor = matchFactor(rate: rate)
    let reach = searchSeconds * rate
    let block = blockSeconds * rate
    let fineReach = 2 * factor + Int((Double(windowSeconds * rate) * DriftRatio.limit).rounded(.up))
    /// The full-span scores of the whole-span searches, built at the first one: at 3 h of reference
    /// they hold about 512 MiB.
    var fullSpan: (excerptLength: Int, scores: CoarseScores)?

    /// The point of the window `range`, searched at the coarse positions `positions` of its first
    /// frame, or over the whole span when nil; nil when it fails the match rule or no block reaches
    /// `blockPeak`.
    func search(_ range: Range<Int>, at positions: ClosedRange<Int>?) throws(SyncFailure) -> DriftPoint? {
        if isCancelled() { throw .cancelled }
        let frames = try read.clipFrames(range)
        var decimator = Decimator(factor: factor)
        let excerpt = frames.withUnsafeBufferPointer { decimator.feed($0) }
        let last = read.reference2k.count - excerpt.count
        guard !excerpt.isEmpty, last >= 0 else { return nil }
        let wanted = positions ?? 0...last
        guard wanted.overlaps(0...last) else { return nil }
        let searched = wanted.clamped(to: 0...last)
        let coarse: CoarseScores
        if positions == nil, let fullSpan, fullSpan.excerptLength == excerpt.count {
            coarse = fullSpan.scores
        } else {
            let reference = Array(read.reference2k[searched.lowerBound..<searched.upperBound + excerpt.count])
            guard
                let scores = CoarseScores(
                    reference: reference, excerptLength: excerpt.count, separation: matchSeparation(rate: rate),
                    makeSetup: makeSetup)
            else { throw .read(POSIXError(.ENOMEM)) }
            coarse = scores
            if positions == nil { fullSpan = (excerpt.count, scores) }
        }
        let (position, score) = coarse.match(excerpt)
        guard score.isMatch else { return nil }
        if isCancelled() { throw .cancelled }
        let start = (searched.lowerBound + position) * factor
        let low = max(0, start - fineReach)
        let fine = try read.referenceFrames(low..<min(read.spanLength, start + range.count + fineReach))
        let high = low + fine.count
        var (centers, lags): ([Double], [Double]) = ([], [])
        for first in stride(from: 0, through: range.count - block, by: block) {
            let from = max(low, start + first - fineReach)
            let to = min(high, start + first + block + fineReach)
            guard to - from > block else { continue }
            let (shift, peak) = fineShift(
                Array(frames[first..<first + block]), in: Array(fine[from - low..<to - low]))
            guard peak >= blockPeak else { continue }
            centers.append(Double(range.lowerBound + first) + Double(block) / 2)
            lags.append(Double(from + shift - range.lowerBound - first))
        }
        guard !lags.isEmpty else { return nil }
        let count = Double(lags.count)
        return DriftPoint(
            clipFrame: centers.reduce(0, +) / count, lag: Double(read.move(0).count) + lags.reduce(0, +) / count)
    }
    /// The coarse positions within `reach` of the first frame of `range` after a move by `move`. The
    /// search cuts them to the reference.
    func positions(of range: Range<Int>, around move: Frames) -> ClosedRange<Int> {
        let expected = read.lag(move) + range.lowerBound
        return (expected - reach) / factor...(expected + reach) / factor
    }

    var points: [DriftPoint?] = []
    for (index, range) in windows.enumerated() {
        points.append(try search(range, at: positions(of: range, around: sync.lag)))
        progress(readShare + (1 - readShare) * Double(index + 1) / Double(windows.count))
    }
    var first = 0
    while first < windows.count {
        guard points[first] == nil else {
            first += 1
            continue
        }
        var end = first
        while end < windows.count, points[end] == nil { end += 1 }
        if end - first >= lostRunCount || first == 0 || end == windows.count,
            let loudest = (first..<end).max(by: { level(windows[$0]) < level(windows[$1]) }),
            let center = try search(windows[loudest], at: nil)
        {
            let move = Frames(Int(center.lag.rounded()))
            for index in first..<end {
                points[index] = try search(windows[index], at: positions(of: windows[index], around: move))
            }
        }
        first = end
    }
    return DriftMeasure(sync: sync, points: points.compactMap { $0 })
}

/// The sub-window of the cut scan, its step, and the score that a line needs to win it (decision
/// 0077, D8), in seconds and as a normalized correlation.
private let cutWindowSeconds = 0.2
private let cutStepSeconds = 0.02
private let cutWinScore = 0.5
/// The cut scan reads the clip and the reference in blocks of this many steps.
private let cutBlockSteps = 3000

/// The clip frame of the cut between each two segments of `fit`, a fit of the `driftMeasure` points
/// of `clip` against `track` (decision 0077, D8). Between the last point of a segment and the first
/// point of the next, 200 ms sub-windows at 20 ms steps score the two lines at the session rate; a
/// line wins a sub-window with the larger normalized correlation at its lag, when that is 0.5 or more.
/// The cut is the step boundary with the fewest wins on the wrong side, and the middle of the tied
/// boundaries, so a cut in silence falls inside the silence. `isCancelled` is read before each block.
func driftCuts(
    of clip: ClipID, to track: TrackID, in session: Session, package: URL, fit: DriftFit,
    isCancelled: () -> Bool = { false }, open: @escaping MediaOpen = openMedia
) throws(SyncFailure) -> [Int] {
    guard let (target, _) = session.clip(clip) else { preconditionFailure("syncSpan checks the clip") }
    let rate = session.sampleRate
    let (clipReader, referenceReader) = syncReaders(of: clip, to: track, in: session, package: package, open: open)
    let length = Int(cutWindowSeconds * Double(rate))
    let step = Int(cutStepSeconds * Double(rate))
    return try zip(fit.segments, fit.segments.dropFirst()).map { pair throws(SyncFailure) -> Int in
        let (before, after) = pair
        let low = Int(fit.points[before.pointRange.upperBound].clipFrame.rounded())
        let high = Int(fit.points[after.pointRange.lowerBound].clipFrame.rounded())
        let offsets = [before.offset, after.offset]
        func lag(_ line: Int, _ clipFrame: Int) -> Int {
            Int((offsets[line] + fit.slope * Double(clipFrame)).rounded())
        }
        var winners: [(center: Int, line: Int?)] = []
        for block in stride(from: low, to: high - length, by: cutBlockSteps * step) {
            if isCancelled() { throw .cancelled }
            let starts = Array(stride(from: block, to: min(high - length, block + cutBlockSteps * step), by: step))
            let end = starts[starts.count - 1] + length
            let clipFrames = try renderMono(
                clipReader, target.start + Frames(block)..<target.start + Frames(end), rate: rate)
            let references = try (0..<2).map { line throws(SyncFailure) -> (first: Int, frames: [Float]) in
                let first = target.start.count + block + min(lag(line, block), lag(line, end)) - 1
                let last = target.start.count + end + max(lag(line, block), lag(line, end)) + 1
                return (first, try renderPadded(referenceReader, first..<last, rate: rate))
            }
            for start in starts {
                let center = start + length / 2
                let scores = (0..<2).map { line in
                    let (first, frames) = references[line]
                    let at = target.start.count + start + lag(line, center) - first
                    return correlation(clipFrames, at: start - block, frames, at: at, count: length)
                }
                let line = scores[1] > scores[0] ? 1 : 0
                winners.append((center, scores[line] >= cutWinScore ? line : nil))
            }
        }
        // The wrong wins at boundary k: line 1 wins before it, and line 0 wins at or after it.
        var wrong = winners.filter { $0.line == 0 }.count
        var (fewest, tied) = (Int.max, (first: high, last: high))
        for index in 0...winners.count {
            let boundary = index < winners.count ? winners[index].center : high
            if wrong < fewest {
                fewest = wrong
                tied = (boundary, boundary)
            } else if wrong == fewest {
                tied.last = boundary
            }
            if index < winners.count {
                if winners[index].line == 0 { wrong -= 1 }
                if winners[index].line == 1 { wrong += 1 }
            }
        }
        return (tied.first + tied.last) / 2
    }
}

/// The mono mix of session frames `range`, with silence for the frames under frame 0.
private func renderPadded(_ reader: MixReader, _ range: Range<Int>, rate: Int) throws(SyncFailure) -> [Float] {
    let first = max(0, range.lowerBound)
    guard first < range.upperBound else { return [Float](repeating: 0, count: range.count) }
    let frames = try renderMono(reader, Frames(first)..<Frames(range.upperBound), rate: rate)
    return [Float](repeating: 0, count: first - range.lowerBound) + frames
}

/// The normalized correlation of `count` frames of `a` from `aStart` and of `b` from `bStart`: 0 when
/// `a` is silent or the energy of `b` is under 1e-4 of the energy of `a`, as the 0076 match.
private func correlation(_ a: [Float], at aStart: Int, _ b: [Float], at bStart: Int, count: Int) -> Double {
    var (dot, aEnergy, bEnergy): (Float, Float, Float) = (0, 0, 0)
    a.withUnsafeBufferPointer { a in
        b.withUnsafeBufferPointer { b in
            let (x, y) = (a.baseAddress! + aStart, b.baseAddress! + bStart)
            vDSP_dotpr(x, 1, y, 1, &dot, vDSP_Length(count))
            vDSP_svesq(x, 1, &aEnergy, vDSP_Length(count))
            vDSP_svesq(y, 1, &bEnergy, vDSP_Length(count))
        }
    }
    guard aEnergy > 0, Double(bEnergy) >= 1e-4 * Double(aEnergy) else { return 0 }
    return Double(dot) / (Double(aEnergy) * Double(bEnergy)).squareRoot()
}
