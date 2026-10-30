import AVFoundation
import Foundation

/// The value of `DIRIGIBLE_AUDIO_OUTPUT`, read once at the boundary. Only `none` plays to no
/// device; any other value plays to the device, and an unknown one leaves a journal line.
enum AudioOutputSetting: Equatable {
    case device
    case noDevice
    case unknown(String)

    static let variable = "DIRIGIBLE_AUDIO_OUTPUT"
    /// The value of this process, for the live environment.
    static let live = AudioOutputSetting(environment: ProcessInfo.processInfo.environment)

    init(environment: [String: String]) {
        switch environment[Self.variable] {
        case nil, "", "device": self = .device
        case "none": self = .noDevice
        case let value?: self = .unknown(value)
        }
    }
}

/// The paced output (decision 0016, amended): the engine renders offline, and each tick pulls the
/// frames that the host clock owes, so a play moves in real time with no device.
extension Player {
    /// Pulls `elapsed x rate - pulled` frames, in pieces of at most one chunk, and drops the
    /// samples. One tick pulls at most 1 s of frames: when more are due (a system sleep, a debugger
    /// stop), the base moves forward by the rest, and the playhead pauses over the gap as a device
    /// output does. A stop of the refill ends the pull. A failed render returns its stop: the code
    /// of the thrown error, or the status. Runs on the queue of the Player, not on an audio thread.
    func pacedPull() -> PlaybackStop? {
        guard output == .paced, let engine = graph?.engine, engine.isRunning, let base = pacedBase else { return nil }
        let rate = session.sampleRate
        let due = Int((now() - base) / .seconds(1) * Double(rate)) - pacedPulled
        guard due > 0 else { return nil }
        if due > rate { pacedBase = base + .seconds(Double(due - rate) / Double(rate)) }
        if pacedBuffer == nil {
            pacedBuffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(chunk))
        }
        guard let buffer = pacedBuffer else { return nil }
        var left = min(due, rate)
        while left > 0 {
            refill()
            guard stop == nil else { return nil }
            let count = min(left, chunk)
            let status: AVAudioEngineManualRenderingStatus
            do { status = try pacedRender(engine, AVAudioFrameCount(count), buffer) } catch {
                return .outputUnavailable((error as NSError).code)
            }
            guard status == .success else { return .outputUnavailable(status.rawValue) }
            left -= count
            pacedPulled += count
        }
        return nil
    }
}
