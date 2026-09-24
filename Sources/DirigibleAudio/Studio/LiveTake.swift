import DirigibleCore

/// The state of one armed track during a take.
public struct LiveTrack: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case recording
        case deviceLost
    }

    public var state: State
    public var droppedFrames: Int
}

/// The test seam of the live take (decision 0013): closures and values, no protocol. `live`
/// calls the system.
struct CaptureEnvironment: Sendable {
    var hal: DeviceHAL
    /// A running device with no valid record for this long is lost (the watchdog).
    var silenceLimit: Duration

    static let live = CaptureEnvironment(hal: .live, silenceLimit: .seconds(2))
}
