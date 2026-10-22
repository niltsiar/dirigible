import DirigibleCore

/// The rates of one segment, by the rules of decision 0004.
struct RateChoice: Hashable, Sendable {
    /// The nominal rate of the device: the header rate, or the snapped rate of rule 2.
    let nominal: Double
    /// The rate of the CAF frames that finalize converts from.
    let source: Double
    /// The fitted rate, or the header rate with no usable fit.
    let measured: Double
    /// False when finalize did not trust the fit (the warning mark of 0004).
    let driftCorrected: Bool

    /// `frames` is the frame count of the segment, for the drift limit.
    init(header: CaptureHeader, checkpoints: [Checkpoint], frames: Int) {
        let rate = header.nominalRate
        let fit = fittedRate(checkpoints)
        // Rule 1: the fit is within 1000 ppm of the header rate. Rule 2: of a discrete available
        // rate; the header rate lagged. A continuous range is not a snap target.
        let discrete = header.availableRates.filter { $0.lowerBound == $0.upperBound }.map(\.lowerBound)
        let snap = fit.flatMap { fit in ([rate] + discrete).first { abs(fit - $0) <= $0 * 1e-3 } }
        measured = fit ?? rate
        guard let fit, let snap else {
            // Rule 3, or no usable fit: the header rate, with the warning mark.
            nominal = rate
            source = rate
            driftCorrected = false
            return
        }
        nominal = snap
        driftCorrected = true
        // The fitted rate only when the drift over the segment at the nominal rate passes 1 ms.
        let drift = Double(frames) * abs(1 / snap - 1 / fit)
        source = drift > 1e-3 ? fit : snap
    }
}

/// The slope of the least-squares line through the checkpoints, in file frames per second of
/// host time. Nil when the fit is not usable: fewer than 2 checkpoints, a host span under
/// 0.5 s, or a slope that is not positive.
func fittedRate(_ checkpoints: [Checkpoint]) -> Double? {
    guard let first = checkpoints.first, let last = checkpoints.last,
        nanos(from: first.hostTimeNanos, to: last.hostTimeNanos) >= 500_000_000
    else { return nil }
    let points = checkpoints.map {
        (
            x: Double(nanos(from: first.hostTimeNanos, to: $0.hostTimeNanos)) / 1e9,
            y: Double($0.fileFrame - first.fileFrame)
        )
    }
    let meanX = points.map(\.x).reduce(0, +) / Double(points.count)
    let meanY = points.map(\.y).reduce(0, +) / Double(points.count)
    let covariance = points.map { ($0.x - meanX) * ($0.y - meanY) }.reduce(0, +)
    let variance = points.map { ($0.x - meanX) * ($0.x - meanX) }.reduce(0, +)
    let slope = covariance / variance
    return slope.isFinite && slope > 0 ? slope : nil
}
