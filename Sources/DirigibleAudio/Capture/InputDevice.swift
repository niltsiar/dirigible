import DirigibleCore

/// The device facts that a sidecar header stores. The failable init is the boundary: a rate
/// that is not finite and positive, a negative latency, no buffers, or a UID with a scalar that
/// is not `isStorableInSession` gives nil (a changed UID would not match `Route.deviceUID`).
/// Such scalars in the name become spaces, so `Session.addCapture` never refuses the name.
struct InputDevice: Hashable, Sendable {
    let uid: String
    let name: String
    let nominalRate: Double
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

    var channelCount: Int { channelsPerBuffer.reduce(0, +) }
}

/// Finite and positive: finalize divides by a rate.
func isValidRate(_ rate: Double) -> Bool { rate.isFinite && rate > 0 }

func isValidRange(_ range: ClosedRange<Double>) -> Bool {
    isValidRate(range.lowerBound) && isValidRate(range.upperBound)
}

/// One ring record of decision 0004 as a value. capture-live builds it from the ring bytes.
/// `buffers[i]` holds `frameCount x channelsPerBuffer[i]` interleaved samples when the record
/// matches the device layout.
struct InputRecord: Sendable {
    var sampleTime: Double
    var hostTimeNanos: UInt64
    var frameCount: Int
    /// The nominal rate of the device when the record was made: a hint (decision 0004).
    var nominalRate: Double
    var buffers: [[Float]]
}
