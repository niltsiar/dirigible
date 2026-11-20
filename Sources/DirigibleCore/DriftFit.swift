/// A measured point of a clip against its reference: the clip frame of a window center and the
/// lag of that window, in frames at the session rate.
public struct DriftPoint: Equatable, Sendable {
    public var clipFrame: Double
    public var lag: Double

    public init(clipFrame: Double, lag: Double) {
        self.clipFrame = clipFrame
        self.lag = lag
    }
}

/// The cause of a fit that gives no line (decision 0077, D7).
public enum DriftFitFailure: Error, Equatable, Sendable {
    case tooFewPoints
    /// The lag jumps between two lines that overlap in time.
    case twoLines
    case tooManyOutliers
    /// An end point that a pause of the recorder explains is off its line.
    case endOutlier
    /// A later segment has less lag than an earlier one. A pause only adds lag.
    case lagStepsBack
    case rateOutOfRange
}

/// One clock rate for the clip and one offset for each segment: a pause of the recorder starts a
/// segment. The lag at clip frame `c` in a segment is `offset + slope x c` (decision 0077, D7).
public struct DriftFit: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let offset: Double
        /// The first and the last inlier of the segment, as indexes into `points`.
        public let pointRange: ClosedRange<Int>
    }

    /// The points that the fit read, by clip frame.
    public let points: [DriftPoint]
    /// Lag frames for each clip frame.
    public let slope: Double
    public let segments: [Segment]
    /// Indexes into `points`.
    public let outliers: [Int]
    /// The largest residual in frames of an inlier or of the first or the last point. An end point
    /// that is a lone outlier counts here, so a small step at an end shows in the result.
    public let worstResidual: Double

    static let minPoints = 5
    static let maxOutlierShare = 0.30
    static let minSplitGapMs = 50.0
    /// A cluster of 2 points is a segment when it is more than this far from each segment of 3 or
    /// more points. A pitch period of a low voice is about 12.5 ms.
    static let pairGapMs = 20.0
    static let minToleranceMs = 1.0
    /// Scales a median absolute deviation to a standard deviation.
    static let madScale = 1.4826

    /// Points must have distinct clip frames and finite values. Throws the cause of a fit with no line.
    public init(points input: [DriftPoint], sampleRate: Double) throws(DriftFitFailure) {
        let points = input.sorted { $0.clipFrame < $1.clipFrame }
        let n = points.count
        guard n >= Self.minPoints else { throw .tooFewPoints }
        let frames = sampleRate / 1000
        let (groups, gap) = try Self.segmentGroups(of: points, frames: frames)

        var pairSlopes: [Double] = []
        for group in groups {
            for (x, i) in group.enumerated() {
                for j in group[(x + 1)...] {
                    pairSlopes.append((points[j].lag - points[i].lag) / (points[j].clipFrame - points[i].clipFrame))
                }
            }
        }
        let slope = median(pairSlopes)
        let offsets = groups.map { group in median(group.map { points[$0].lag - slope * points[$0].clipFrame }) }
        func residual(_ i: Int, _ k: Int) -> Double { points[i].lag - slope * points[i].clipFrame - offsets[k] }

        let tolerance = max(
            Self.minToleranceMs * frames,
            4 * Self.madScale * median(groups.enumerated().flatMap { k, group in group.map { abs(residual($0, k)) } }))
        let inliers = groups.enumerated().map { k, group in group.filter { abs(residual($0, k)) <= tolerance } }
        let kept = Set(inliers.joined())
        guard Double(n - kept.count) <= Self.maxOutlierShare * Double(n) else { throw .tooManyOutliers }
        // A pause skips source audio, so the lag after it is larger.
        let firstUnder = !kept.contains(0) && residual(0, 0) < -gap
        let lastOver = !kept.contains(n - 1) && residual(n - 1, groups.count - 1) > gap
        guard !firstUnder, !lastOver else { throw .endOutlier }

        let live = inliers.filter { !$0.isEmpty }
        var covariance = 0.0
        var variance = 0.0
        for group in live {
            let meanFrame = mean(group.map { points[$0].clipFrame })
            let meanLag = mean(group.map { points[$0].lag })
            for i in group {
                covariance += (points[i].clipFrame - meanFrame) * (points[i].lag - meanLag)
                variance += (points[i].clipFrame - meanFrame) * (points[i].clipFrame - meanFrame)
            }
        }
        let fitSlope = variance > 0 ? covariance / variance : slope
        guard abs(fitSlope) < DriftRatio.limit else { throw .rateOutOfRange }
        let fitOffsets = live.map { group in mean(group.map { points[$0].lag - fitSlope * points[$0].clipFrame }) }

        var worst = 0.0
        func line(_ i: Int, _ k: Int) -> Double { abs(points[i].lag - fitSlope * points[i].clipFrame - fitOffsets[k]) }
        for (k, group) in live.enumerated() { for i in group { worst = max(worst, line(i, k)) } }
        worst = max(worst, line(0, 0), line(n - 1, live.count - 1))

        self.points = points
        self.slope = fitSlope
        self.segments = zip(live, fitOffsets).map { Segment(offset: $1, pointRange: $0[0]...$0[$0.count - 1]) }
        self.outliers = points.indices.filter { !kept.contains($0) }
        self.worstResidual = worst
    }

    /// Rules 2 to 5 of decision 0077, D7: the groups of point indexes that are segments, by time, and
    /// the split gap in frames.
    private static func segmentGroups(
        of points: [DriftPoint], frames: Double
    ) throws(DriftFitFailure) -> ([[Int]], Double) {
        let n = points.count
        let slope0 = median(zip(points, points.dropFirst()).map { ($1.lag - $0.lag) / ($1.clipFrame - $0.clipFrame) })
        let d = points.map { $0.lag - slope0 * $0.clipFrame }
        let local = d.indices.map { abs(d[$0] - median(d[max(0, $0 - 1)...min(n - 1, $0 + 1)])) }
        let gap = max(minSplitGapMs * frames, 6 * madScale * median(local))

        let order = d.indices.sorted { (d[$0], $0) < (d[$1], $1) }
        var clusters = [[order[0]]]
        for (a, b) in zip(order, order.dropFirst()) {
            if d[b] - d[a] > gap { clusters.append([]) }
            clusters[clusters.count - 1].append(b)
        }
        let big = clusters.filter { $0.count >= 3 }.map { $0.sorted() }
        var groups = big
        for pair in clusters.filter({ $0.count == 2 }).map({ $0.sorted() }) where !big.isEmpty {
            let center = median(pair.map { d[$0] })
            if big.allSatisfy({ abs(center - median($0.map { d[$0] })) > pairGapMs * frames }) {
                groups.append(pair)
            }
        }
        // Every point is an outlier: no group has 3 points or a pair that stands apart.
        guard !groups.isEmpty else { throw .tooManyOutliers }
        groups.sort { $0[0] < $1[0] }
        for (a, b) in zip(groups, groups.dropFirst()) where a[a.count - 1] > b[0] { throw .twoLines }
        // Clusters are more than the split gap apart, so a lower later group steps back by more.
        for (a, b) in zip(groups, groups.dropFirst()) where median(b.map { d[$0] }) < median(a.map { d[$0] }) {
            throw .lagStepsBack
        }
        return (groups, gap)
    }
}

private func median(_ values: some Collection<Double>) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

private func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
