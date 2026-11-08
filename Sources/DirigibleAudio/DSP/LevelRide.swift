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

/// The ride layer of one measure group, one gain in dB for each 100 ms step: median(0, a, b) of
/// two readings of the curve rule. b is the curve of the source steps; a is the curve as the
/// envelope plays them (`heardGains`; `envelopeDB` holds the envelope gain at each step centre). So
/// a manual lift or cut and a duck dip are not ridden twice. Nil when a reading has no reference:
/// silence, under 400 ms, or an envelope that mutes the group.
func rideLayer(stepMeanSquares: [Double], envelopeDB: [Double]) -> [Double]? {
    let ride = LevelRide.standard
    guard let b = ride.gains(stepMeanSquares),
        let a = ride.heardGains(stepMeanSquares: stepMeanSquares, envelopeDB: envelopeDB)
    else { return nil }
    return rideLayer(a: a.dB, b: b.dB)
}

/// median(0, a, b) at each step.
func rideLayer(a: [Double], b: [Double]) -> [Double] {
    zip(a, b).map { max(min($0, $1), min(max($0, $1), 0)) }
}

extension LevelRide {
    /// The curve of one measure group: the reference R in LUFS, the offset o of step 6 in dB, and
    /// the final gain of each step in dB.
    struct Curve: Hashable, Sendable {
        let reference: Double
        let offset: Double
        let dB: [Double]
    }

    /// Reading a of the ride layer: the curve of the steps times 10^(E/10), E = `envelopeDB`. R and
    /// o count only the blocks whose four steps have E >= G - 0.25 dB, G the mode block gain, so a
    /// cut in the envelope does not set the reference. With no envelope point, each block counts.
    /// Precondition: one envelope gain for each step.
    func heardGains(stepMeanSquares: [Double], envelopeDB: [Double]) -> Curve? {
        precondition(stepMeanSquares.count == envelopeDB.count, "one envelope gain for each step")
        let floor = Self.modeBlockGain(envelopeDB) - 0.25
        let heard = zip(stepMeanSquares, envelopeDB).map { $0 * pow(10, $1 / 10) }
        return gains(heard, counting: envelopeDB.map { $0 >= floor })
    }

    /// The mode block gain G of the envelope gains of the steps: the gain of a 400 ms block is the
    /// lowest gain of its four steps; the bins are 0.5 dB wide and centred on multiples of 0.5 dB;
    /// G is the centre of the bin with the most blocks, and of two such bins the higher one. 0 with
    /// no block.
    static func modeBlockGain(_ envelopeDB: [Double]) -> Double {
        let size = LoudnessMeter.blockSteps
        guard envelopeDB.count >= size else { return 0 }
        var counts: [Double: Int] = [:]
        for end in size - 1..<envelopeDB.count {
            counts[(envelopeDB[end - size + 1...end].min()! * 2).rounded() / 2, default: 0] += 1
        }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }!.key
    }

    /// The curve of one measure group (`meanSquares`), or nil when the group has no reference.
    /// With `counted`, R and o count only the blocks whose four steps are counted: when those
    /// blocks give no reference, R counts every block, and when their ridden blocks give no
    /// loudness, o counts every ridden block. The steps of the rule:
    /// 1. A pause step has a mean square more than `gateDepth` under the reference R.
    /// 2. The computed gain c(k) is R minus the power mean of the speech steps of the window,
    ///    clamped; none when the window has no speech step.
    /// 3. The held value h(k) is the raw gain of the last speech step at or before k (0 before).
    /// 4. The raw gain r(k) is c(k) for a speech step, min(c(k), h(k)) for a pause step, or h(k).
    /// 5. The smoothed gain s(k) is the mean of r over the smoothing window; a pause step then
    ///    gets min(s(k), h(k)).
    /// 6. One offset o restores R; the gain is s(k) + o, clamped.
    func gains(_ meanSquares: [Double], counting counted: [Bool]? = nil) -> Curve? {
        guard let whole = Loudness(blocks: blocks(meanSquares)).integrated?.value else { return nil }
        let reference =
            counted.flatMap { Loudness(blocks: blocks(meanSquares, counting: $0)).integrated?.value } ?? whole
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
        let level =
            counted.flatMap { Loudness(blocks: blocks(ridden, counting: $0)).integrated?.value }
            ?? Loudness(blocks: blocks(ridden)).integrated?.value ?? reference
        let offset = reference - level
        return Curve(reference: reference, offset: offset, dB: smoothed.map { clamp($0 + offset) })
    }

    private func clamp(_ dB: Double) -> Double { min(max(dB, -maxCut), maxBoost) }

    /// The steps from `step - half` to `step + half` that are in 0..<count.
    private func window(_ step: Int, _ half: Int, _ count: Int) -> ClosedRange<Int> {
        max(0, step - half)...min(count - 1, step + half)
    }

    /// The 400 ms blocks of BS.1770-5, one at each step: the mean of 4 steps. With `counted`, only
    /// the blocks whose 4 steps are counted.
    private func blocks(_ meanSquares: [Double], counting counted: [Bool]? = nil) -> [Double] {
        let size = LoudnessMeter.blockSteps
        guard meanSquares.count >= size else { return [] }
        return (size - 1..<meanSquares.count).compactMap { (end: Int) -> Double? in
            let steps = end - size + 1...end
            if let counted, counted[steps].contains(false) { return nil }
            return meanSquares[steps].reduce(0, +) / Double(size)
        }
    }
}
