import DirigibleCore
import Foundation

/// The clock state of one open segment, and the break rules of decision 0004.
struct Segment {
    /// The sample time and the host time at the start of a record.
    struct Point {
        var sampleTime: Double
        var hostTimeNanos: UInt64
    }

    /// The header rate.
    let rate: Double
    let origin: Point
    /// The record starts of about the last 0.5 s. The first point is at least 0.5 s old when
    /// the segment is that long.
    var window: [Point] = []
    var nextSampleTime: Double
    /// Frames written to each segment so far.
    var fileFrame: Int64 = 0
    var nextCheckpoint: Int64 = 0
    var nextFlush: Int64
    /// The checkpoint of the last record.
    var last: Checkpoint?

    static let windowNanos: Int64 = 500_000_000

    init(first record: InputRecord) {
        rate = record.nominalRate
        origin = Point(sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        nextSampleTime = record.sampleTime
        nextFlush = 5 * Int64(record.nominalRate.rounded())
    }

    /// True when `record` starts a new segment: a new header rate, a backward sample-time jump,
    /// a forward jump of more than 2 s, or a slope change of more than 1%.
    func breaks(at record: InputRecord) -> Bool {
        let jump = record.sampleTime - nextSampleTime
        return record.nominalRate != rate || jump < 0 || jump > 2 * rate
            || slopeChanges(at: Point(sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos))
    }

    /// Compares the sample-time to host-time slope of the last 0.5 s with the two-point slope of
    /// the segment before that window. Both spans are 0.5 s or more, so a host-time jitter of
    /// 200 µs moves each slope by 0.08% at most.
    func slopeChanges(at point: Point) -> Bool {
        guard
            let start = window.last(where: {
                nanos(from: $0.hostTimeNanos, to: point.hostTimeNanos) >= Self.windowNanos
            })
        else { return false }
        let before = nanos(from: origin.hostTimeNanos, to: start.hostTimeNanos)
        guard before >= Self.windowNanos else { return false }
        let running = (start.sampleTime - origin.sampleTime) / Double(before)
        let recent =
            (point.sampleTime - start.sampleTime) / Double(nanos(from: start.hostTimeNanos, to: point.hostTimeNanos))
        return abs(recent / running - 1) > 0.01
    }

    mutating func remember(_ record: InputRecord) {
        let point = Point(sampleTime: record.sampleTime, hostTimeNanos: record.hostTimeNanos)
        window.append(point)
        while window.count > 1, nanos(from: window[1].hostTimeNanos, to: point.hostTimeNanos) >= Self.windowNanos {
            window.removeFirst()
        }
    }
}
