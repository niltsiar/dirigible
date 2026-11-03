import AVFoundation

/// Reads the output term of a play start after the engine start: the HAL read on the device
/// output, a manual term on the two manual rendering outputs, and a fake one in tests.
typealias OutputTermRead = @Sendable (AVAudioEngine) -> Result<OutputTerm, OutputTermFault>

/// Why a play start has no output term (decision 0070, **Anchor**).
enum OutputTermFault: Error, Hashable, Sendable {
    /// The play start ended before the read, with this stop; nil when the engine graph did not build.
    case notStarted(PlaybackStop?)
    case read(HALReadFault)
    /// The nominal rate of the device is not `isValidRate`.
    case rate(Double)

    /// The fields of its journal line (decision 0059).
    var journalFields: [(key: String, value: DiagnosticValue)] {
        switch self {
        case .notStarted(let stop):
            return [("fault", .text("not-started")), ("stop", .text(stop.map { "\($0)" } ?? "none"))]
        case .read(let fault):
            var fields: [(key: String, value: DiagnosticValue)] = [
                ("fault", .text("read")), ("property", .text(fourCharacters(fault.selector))),
            ]
            if let status = fault.status { fields.append(("status", .status(status))) }
            return fields
        case .rate(let rate):
            return [("fault", .text("rate")), ("rate", .text("\(rate)"))]
        }
    }
}

/// The output latency of one play start (decision 0070, **Anchor**): the delay from the host time
/// of a node frame to its sound that the HAL reports, and one IO buffer. The playhead, the take
/// anchor, and the journal read this one value.
enum OutputTerm: Hashable, Sendable {
    /// The term of the output device, in device frames.
    case device(Device)
    /// The term of an output with no device, or of a play whose read failed, in session frames.
    case manual(Int)

    /// The four parts of the term of an output device, at the nominal rate of the device.
    struct Device: Hashable, Sendable {
        let latency: UInt32
        let streamLatency: UInt32
        let safetyOffset: UInt32
        let bufferFrames: UInt32
        let rate: Double
        let uid: String

        /// Nil when `rate` is not `isValidRate`, so no conversion divides by 0 or traps.
        init?(
            latency: UInt32, streamLatency: UInt32, safetyOffset: UInt32, bufferFrames: UInt32, rate: Double,
            uid: String
        ) {
            guard isValidRate(rate) else { return nil }
            (self.latency, self.streamLatency, self.safetyOffset) = (latency, streamLatency, safetyOffset)
            (self.bufferFrames, self.rate, self.uid) = (bufferFrames, rate, uid)
        }

        /// The sum of the four parts.
        var frames: Int { Int(latency) + Int(streamLatency) + Int(safetyOffset) + Int(bufferFrames) }
    }

    func nanos(sessionRate: Int) -> UInt64 {
        switch self {
        case .device(let device): UInt64((Double(device.frames) * 1e9 / device.rate).rounded())
        case .manual(let frames): UInt64((Double(frames) * 1e9 / Double(sessionRate)).rounded())
        }
    }

    func sessionFrames(sessionRate: Int) -> Int {
        switch self {
        case .device(let device): Int((Double(device.frames) * Double(sessionRate) / device.rate).rounded())
        case .manual(let frames): frames
        }
    }
}
