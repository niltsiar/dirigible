/// A device fact for the studio. `state` is the state of one track of a take; `status` is the
/// raw OSStatus or errno of a write error, for tests, and never reaches the public API. `levels`
/// comes once per drain: the level of each arm in that drain, the device latency in nanoseconds
/// (latency / nominal rate, signed), and the dropped frames of the device in the take.
enum Report: Sendable {
    case state(take: Int, arm: Int, LiveTrack.State, status: Int32?)
    case levels(take: Int, arms: [Int: ArmLevel], latencyNanos: Int64, droppedFrames: Int)
}

/// The level of one arm in one drain. `peak` is the largest absolute sample and `rms` the largest
/// RMS of a 256-frame block of the records that the drain gave to the tracks (0 with no records).
/// `written` holds the raw host nanoseconds (no latency) of the frames that the writer of the arm
/// wrote to disk in the drain: the smallest start and the largest end. It is nil when the writer
/// wrote nothing. A write error ends it until the next drain, also after a reopen in that drain.
struct ArmLevel: Sendable, Equatable {
    var peak: Float = 0
    var rms: Float = 0
    var written: Range<UInt64>?
}
