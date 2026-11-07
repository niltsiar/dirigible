import DirigibleCore
import Foundation

/// The fixed settings of a level ride. The command has no control.
struct LevelRide: Hashable, Sendable {
    static let standard = LevelRide()
    /// The window of the computed gain: the speech steps from k - 7 to k + 7, 1.5 s centred. A
    /// window of k - 5 to k + 5 moves the gain by 0.56 dB between 0.33 s words.
    let windowHalfSteps = 7
    /// A step more than this many LU under the reference of its measure span is a pause step.
    let gateDepth = 15.0
    /// The largest boost and the largest cut in dB.
    let maxBoost = 6.0
    let maxCut = 6.0
    /// The centred moving average of the gain, over the steps from k - 5 to k + 5.
    let smoothingHalfSteps = 5
}

/// The ride of one run of clips of one file, by the curve rule of `LevelRide.gains` for each
/// measure span. `stepMeanSquares` holds the K-weighted, channel-summed mean square of each 100 ms
/// step of the run (`LoudnessMeter.stepMeanSquares`); step i covers the run frames
/// [i x `stepFrames`, (i + 1) x `stepFrames`). Each clip gives its span in run frames and its clip
/// gain. Nil when no measure span has a reference, so the run makes no file. Else the curve of the
/// run and the indices of the clips whose measure span has no reference: they get 0 dB.
func rideCurve(
    stepMeanSquares: [Double], stepFrames: Int, clips: [(span: Range<Int>, gain: Gain)]
) -> (curve: GainCurve, unmeasured: [Int])? {
    var spans: [(steps: Range<Int>, dB: [Double])] = []
    var unmeasured: [Int] = []
    var measured = false
    for span in measureSpans(clips) {
        // Only the steps that lie in the span count: a step that crosses an edge reads a handle.
        let first = (span.frames.lowerBound + stepFrames - 1) / stepFrames
        let steps = first..<max(first, min(span.frames.upperBound / stepFrames, stepMeanSquares.count))
        if let gains = LevelRide.standard.gains(Array(stepMeanSquares[steps])) {
            spans.append((steps, gains))
            measured = true
        } else {
            unmeasured += span.clips
            if !steps.isEmpty { spans.append((steps, Array(repeating: 0, count: steps.count))) }
        }
    }
    guard measured else { return nil }
    let dB = stepMeanSquares.indices.map { runGain(at: $0, spans: spans) }
    return (GainCurve(dB: dB, stepFrames: stepFrames), unmeasured.sorted())
}

/// The measure spans of `clips`, in frame order: the spans of clips with equal clip gains that
/// touch or overlap merge into one, so a split or a duplicated clip keeps one reference.
private func measureSpans(_ clips: [(span: Range<Int>, gain: Gain)]) -> [(frames: Range<Int>, clips: [Int])] {
    var spans: [(frames: Range<Int>, clips: [Int])] = []
    for indices in Dictionary(grouping: clips.indices, by: { clips[$0].gain }).values {
        for index in indices.sorted(by: { clips[$0].span.lowerBound < clips[$1].span.lowerBound }) {
            let span = clips[index].span
            if let last = spans.last, last.frames.upperBound >= span.lowerBound,
                clips[last.clips[0]].gain == clips[index].gain
            {
                spans[spans.count - 1] = (
                    last.frames.lowerBound..<max(last.frames.upperBound, span.upperBound), last.clips + [index]
                )
            } else {
                spans.append((span, [index]))
            }
        }
    }
    return spans.sorted { ($0.frames.lowerBound, $0.frames.upperBound) < ($1.frames.lowerBound, $1.frames.upperBound) }
}

/// The gain of run step `step`. In one span: its gain. In several spans (clips with other clip
/// gains that overlap): the mean of their gains, each weighted by the depth of the step in its
/// span, so the gain blends linearly over the shared steps. Outside every span: the gain of the
/// nearest span edge step.
private func runGain(at step: Int, spans: [(steps: Range<Int>, dB: [Double])]) -> Double {
    let centre = Double(step) + 0.5
    var (sum, weights) = (0.0, 0.0)
    for span in spans where span.steps.contains(step) {
        let weight = min(centre - Double(span.steps.lowerBound), Double(span.steps.upperBound) - centre)
        sum += weight * span.dB[step - span.steps.lowerBound]
        weights += weight
    }
    if weights > 0 { return sum / weights }
    let nearest = spans.min {
        distance(step, $0.steps) < distance(step, $1.steps)
    }!
    return step < nearest.steps.lowerBound ? nearest.dB[0] : nearest.dB[nearest.dB.count - 1]
}

private func distance(_ step: Int, _ steps: Range<Int>) -> Int {
    step < steps.lowerBound ? steps.lowerBound - step : step - steps.upperBound + 1
}

extension LevelRide {
    /// The final gain of each step of one measure span (`meanSquares`), or nil when the span has
    /// no reference. The steps of the rule:
    /// 1. A pause step has a mean square more than `gateDepth` under the reference R.
    /// 2. The computed gain c(k) is R minus the power mean of the speech steps of the window,
    ///    clamped; none when the window has no speech step.
    /// 3. The held value h(k) is the raw gain of the last speech step at or before k (0 before).
    /// 4. The raw gain r(k) is c(k) for a speech step, min(c(k), h(k)) for a pause step, or h(k).
    /// 5. The smoothed gain s(k) is the mean of r over the smoothing window; a pause step then
    ///    gets min(s(k), h(k)).
    /// 6. One offset o restores R; the gain is s(k) + o, clamped.
    func gains(_ meanSquares: [Double]) -> [Double]? {
        guard let reference = Loudness(blocks: blocks(meanSquares)).integrated?.value else { return nil }
        let gate = Loudness.meanSquare(reference - gateDepth)
        let speech = meanSquares.map { $0 >= gate }
        var raw: [Double] = []
        var held: [Double] = []
        var last = 0.0
        for step in meanSquares.indices {
            var (sum, count) = (0.0, 0)
            for index in window(step, windowHalfSteps, meanSquares.count) where speech[index] {
                sum += meanSquares[index]
                count += 1
            }
            let computed = count > 0 ? clamp(reference - Loudness.lufs(sum / Double(count))) : nil
            if speech[step], let computed {
                last = computed
                raw.append(computed)
            } else {
                raw.append(computed.map { min($0, last) } ?? last)
            }
            held.append(last)
        }
        let smoothed = meanSquares.indices.map { step in
            let steps = window(step, smoothingHalfSteps, raw.count)
            let mean = raw[steps].reduce(0, +) / Double(steps.count)
            return speech[step] ? mean : min(mean, held[step])
        }
        let ridden = zip(meanSquares, smoothed).map { $0 * pow(10, $1 / 10) }
        let offset = reference - (Loudness(blocks: blocks(ridden)).integrated?.value ?? reference)
        return smoothed.map { clamp($0 + offset) }
    }

    private func clamp(_ dB: Double) -> Double { min(max(dB, -maxCut), maxBoost) }

    /// The steps from `step - half` to `step + half` that are in 0..<count.
    private func window(_ step: Int, _ half: Int, _ count: Int) -> ClosedRange<Int> {
        max(0, step - half)...min(count - 1, step + half)
    }

    /// The 400 ms blocks of BS.1770-5, one at each step: the mean of 4 steps.
    private func blocks(_ meanSquares: [Double]) -> [Double] {
        let size = LoudnessMeter.blockSteps
        guard meanSquares.count >= size else { return [] }
        return (size - 1..<meanSquares.count).map { (end: Int) -> Double in
            let first = end - size + 1
            return meanSquares[first...end].reduce(0, +) / Double(size)
        }
    }
}
