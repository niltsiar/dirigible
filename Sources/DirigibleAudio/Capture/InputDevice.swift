import DirigibleCore

/// The device facts that a sidecar header stores. The failable init is the boundary: a rate
/// that is not `isValidRate`, a negative latency, no buffers, or a UID with a scalar that
/// is not `isStorableInSession` gives nil (a changed UID would not match `Route.deviceUID`).
/// Such scalars in the name become spaces, so `Session.addCapture` never refuses the name.
public struct InputDevice: Hashable, Sendable {
    public let uid: String
    public let name: String
    public let nominalRate: Double
    let availableRates: [ClosedRange<Double>]
    /// The channel count of each buffer of an input record.
    let channelsPerBuffer: [Int]
    /// In device frames.
    let latency: Int

    init?(
        uid: String, name: String, nominalRate: Double, availableRates: [ClosedRange<Double>],
        channelsPerBuffer: [Int], latency: Int
    ) {
        guard uid.unicodeScalars.allSatisfy(\.isStorableInSession), isValidRate(nominalRate),
            availableRates.allSatisfy(isValidRange), !channelsPerBuffer.isEmpty,
            channelsPerBuffer.allSatisfy({ $0 > 0 }), (0...Int(Int32.max)).contains(latency),
            // The sidecar stores each text with a UInt16 byte count.
            uid.utf8.count <= UInt16.max, name.utf8.count <= UInt16.max, availableRates.count <= UInt16.max
        else { return nil }
        self.uid = uid
        self.name = String(
            String.UnicodeScalarView(name.unicodeScalars.map { $0.isStorableInSession ? $0 : " " }))
        self.nominalRate = nominalRate
        self.availableRates = availableRates
        self.channelsPerBuffer = channelsPerBuffer
        self.latency = latency
    }

    public var channelCount: Int { channelsPerBuffer.reduce(0, +) }

    /// The latency in nanoseconds at the nominal rate. It is signed and holds no host time.
    var latencyNanos: Int64 { Int64((Double(latency) * 1e9 / nominalRate).rounded()) }

    /// The same device with `name`: the app name of an app source.
    func named(_ name: String) -> InputDevice {
        InputDevice(
            uid: uid, name: name, nominalRate: nominalRate, availableRates: availableRates,
            channelsPerBuffer: channelsPerBuffer, latency: latency) ?? self
    }

    /// The device of a monitor writer before its first lookup (decision 0015): one buffer with
    /// `channels` channels. The first attach takes the facts of the found device. A monitor
    /// writes no sidecar, so these facts never reach a file.
    static func placeholder(uid: String, channels: Int) -> InputDevice? {
        InputDevice(
            uid: uid, name: uid, nominalRate: 48_000, availableRates: [], channelsPerBuffer: [channels], latency: 0)
    }
}

/// 1 Hz to 10 MHz. Finalize divides by a rate. The device writer rounds it to whole frames per
/// second, so a rate under 0.5 gives a checkpoint step of 0 that never ends, and NaN or a rate
/// past `Int64.max` traps. It also fills a gap of up to 2 s with silence.
func isValidRate(_ rate: Double) -> Bool { (1...10_000_000).contains(rate) }

func isValidRange(_ range: ClosedRange<Double>) -> Bool {
    isValidRate(range.lowerBound) && isValidRate(range.upperBound)
}

/// One ring record of decision 0004 as a value. capture-live builds it from the ring bytes.
/// `buffers[i]` holds `frameCount x channelsPerBuffer[i]` interleaved samples.
struct InputRecord: Sendable {
    let sampleTime: Double
    let hostTimeNanos: UInt64
    let frameCount: Int
    /// The nominal rate of the device when the record was made: a hint (decision 0004).
    let nominalRate: Double
    var buffers: [[Float]]

    /// The boundary of the device writer: nil when the rate is not `isValidRate` or the sample
    /// time is not finite. When the hint of a ring record is bad, capture-live gives the rate of
    /// the open segment.
    init?(sampleTime: Double, hostTimeNanos: UInt64, frameCount: Int, nominalRate: Double, buffers: [[Float]]) {
        guard sampleTime.isFinite, isValidRate(nominalRate) else { return nil }
        self.sampleTime = sampleTime
        self.hostTimeNanos = hostTimeNanos
        self.frameCount = frameCount
        self.nominalRate = nominalRate
        self.buffers = buffers
    }

    /// The channel count of each buffer, from its sample count: the layout of the record. A
    /// buffer whose sample count is not a multiple of `frameCount` does not match it.
    var channelsPerBuffer: [Int] { buffers.map { frameCount > 0 ? $0.count / frameCount : 0 } }
}
