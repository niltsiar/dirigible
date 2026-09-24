/// The rates of one segment, by the rules of decision 0004.
struct RateChoice: Hashable, Sendable {
    /// The nominal rate of the device: the header rate.
    let nominal: Double
    /// The rate of the CAF frames that finalize converts from.
    let source: Double
    /// The fitted rate, or the header rate with no usable fit.
    let measured: Double
    /// False when finalize did not trust the fit (the warning mark of 0004).
    let driftCorrected: Bool

    init(header: CaptureHeader, checkpoints: [Checkpoint]) {
        let rate = header.nominalRate
        let fit = fittedRate(checkpoints)
        nominal = rate
        source = rate
        measured = fit ?? rate
        // Rule 1: the fit is within 1000 ppm of the header rate. Rules 2 and 3 come in slice 7;
        // until then, any other fit takes the rule 3 path.
        driftCorrected = fit.map { abs($0 - rate) <= rate * 1e-3 } ?? false
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
