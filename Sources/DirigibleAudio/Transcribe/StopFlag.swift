import CWhisper

/// The stop flag of one transcription (decision 0065, D6): one `atomic_bool` of `cwhisper_stop.c`.
/// The abort callback of `whisper_full` reads it on the compute thread with no lock, no allocation,
/// and no Swift call. It is `@unchecked Sendable` because it holds a C pointer; the flag is atomic.
public final class StopFlag: @unchecked Sendable {
    private let flag: OpaquePointer

    public init() {
        guard let flag = cwhisper_stop_new() else { fatalError("cwhisper_stop_new: out of memory") }
        self.flag = flag
    }

    deinit { cwhisper_stop_free(flag) }

    /// Any thread can call it.
    public func set() { cwhisper_stop_set(flag) }

    public var isSet: Bool { cwhisper_stop_is_set(flag) }

    /// The `abort_callback` and `abort_callback_user_data` of `whisper_full`. The flag must live
    /// for the whole call.
    var abortCallback: ggml_abort_callback { cwhisper_stop_abort }
    var userData: UnsafeMutableRawPointer { UnsafeMutableRawPointer(flag) }
}
