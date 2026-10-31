import Accelerate
import Foundation

/// Moves the word ends of one piece to the pauses of its audio (decision 0065, D7): the token end
/// times of whisper.cpp miss C24. Times are ticks of 10 ms, and tick k is the frame of the 160
/// samples from k * 160 at 16 kHz.
enum WordEnds {
    static let samplesPerTick = 160
    /// A pause is at least 0.20 s under the floor.
    static let shortestGap = 20
    /// A word may take only a gap within 1.0 s of its token end, and an empty-interval word ends at
    /// most 1.0 s after its start.
    static let bandTicks = 100
    static let missCost = 30
    static let punctuatedMissCost = 100

    /// Each word with start < end, never a zero length. A word that takes a gap ends at the gap
    /// start; the word after it starts at the gap end. A word whose end is then not after its start
    /// keeps its token times and gives its gap back. A word that still has end <= start (an empty
    /// token interval) ends at the first quiet frame after its start, capped at the next word start,
    /// at its start + 1.0 s, and at the piece end, or one tick after its start when that cap is not
    /// after it.
    static func place(_ words: [TimedWord], samples: [Float], band: Int? = bandTicks) -> [TimedWord] {
        let levels = levels(of: samples)
        let floor = floor(of: levels)
        let gaps = gaps(in: levels, floor: floor)
        let taken = alignment(of: words, to: gaps, band: band)
        var placed: [TimedWord] = []
        var previousGap: Int?
        for (word, gap) in zip(words, taken) {
            var out = word
            var gap = gap
            if let previousGap { out.start = gaps[previousGap].upperBound }
            if let gap { out.end = gaps[gap].lowerBound }
            if out.end <= out.start {
                out = word
                gap = nil
            }
            placed.append(out)
            previousGap = gap
        }
        for k in placed.indices where placed[k].end <= placed[k].start {
            let start = placed[k].start
            let next = k + 1 < placed.count ? placed[k + 1].start : Int.max
            let cap = min(levels.count, start + bandTicks, next)
            if cap > start {
                let quiet = levels.indices.dropFirst(max(start + 1, 0)).first { levels[$0] <= floor } ?? levels.count
                placed[k].end = min(quiet, cap)
            } else {
                placed[k].end = start + 1
            }
        }
        return placed
    }

    /// The peak of each frame in dBFS, and -200 for a frame of zeros.
    static func levels(of samples: [Float]) -> [Double] {
        samples.withUnsafeBufferPointer { all in
            stride(from: 0, to: all.count, by: samplesPerTick).map { first in
                var peak: Float = 0
                vDSP_maxmgv(all.baseAddress! + first, 1, &peak, vDSP_Length(min(samplesPerTick, all.count - first)))
                return peak > 0 ? 20 * log10(Double(peak)) : -200
            }
        }
    }

    /// max(-40 dBFS, the 20th percentile of the frame peaks + 6 dB).
    static func floor(of levels: [Double]) -> Double {
        guard !levels.isEmpty else { return -40 }
        return max(-40, levels.sorted()[levels.count / 5] + 6)
    }

    /// Runs of frames at or under the floor of at least 0.20 s, after the first loud frame.
    static func gaps(in levels: [Double], floor: Double) -> [Range<Int>] {
        var gaps: [Range<Int>] = []
        var k = 0
        while k < levels.count {
            guard levels[k] <= floor else {
                k += 1
                continue
            }
            var j = k
            while j < levels.count && levels[j] <= floor { j += 1 }
            if j - k >= shortestGap && k > 0 { gaps.append(k..<j) }
            k = j
        }
        return gaps
    }

    static func distance(_ tick: Int, _ gap: Range<Int>) -> Int {
        tick < gap.lowerBound ? gap.lowerBound - tick : max(0, tick - gap.upperBound)
    }

    /// The gap index that each word takes, or nil: dynamic programming over the words and the gaps,
    /// both in time order, each gap to at most one word. A word that takes a gap costs the distance
    /// from its token end to the gap; a word with no gap costs 0.3 s, or 1.0 s when its text ends in
    /// punctuation (whisper.cpp writes one at a pause it hears). With a band, a gap farther than the
    /// band from the token end is not allowed.
    static func alignment(of words: [TimedWord], to gaps: [Range<Int>], band: Int? = bandTicks) -> [Int?] {
        enum Step { case miss, gap, carry }
        let n = words.count
        let m = gaps.count
        let width = m + 1
        var best = [Int](repeating: .max, count: (n + 1) * width)
        var back = [Step](repeating: .miss, count: (n + 1) * width)
        for j in 0...m { best[j] = 0 }
        for i in 1..<(n + 1) {
            let word = words[i - 1]
            let miss = ",.?!;:".contains(word.text.last ?? " ") ? punctuatedMissCost : missCost
            for j in 0...m {
                let cell = i * width + j
                best[cell] = best[cell - width] + miss
                back[cell] = .miss
                guard j >= 1 else { continue }
                let d = distance(word.end, gaps[j - 1])
                if band.map({ d <= $0 }) ?? true, best[cell - width - 1] + d < best[cell] {
                    best[cell] = best[cell - width - 1] + d
                    back[cell] = .gap
                }
                if best[cell - 1] < best[cell] {
                    best[cell] = best[cell - 1]
                    back[cell] = .carry
                }
            }
        }
        var taken = [Int?](repeating: nil, count: n)
        var i = n
        var j = m
        while i > 0 {
            switch back[i * width + j] {
            case .carry:
                j -= 1
                continue
            case .gap:
                taken[i - 1] = j - 1
                j -= 1
            case .miss: break
            }
            i -= 1
        }
        return taken
    }
}
