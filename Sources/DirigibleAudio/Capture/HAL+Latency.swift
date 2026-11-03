import AVFoundation
import AudioToolbox
import CoreAudio

/// One HAL read that failed: the read, and the status when the read gives one.
struct HALReadFault: Error, Hashable, Sendable {
    /// A read of the latency reader, by its journal name. The device latency and the stream
    /// latency have one selector (`ltnc`), so a selector alone does not name the read.
    enum Read: String, Sendable {
        case currentDevice = "current-device"
        case deviceLatency = "device-latency"
        case streams
        case streamLatency = "stream-latency"
        case safetyOffset = "safety-offset"
        case bufferFrames = "buffer-frames"
        case rate
        case uid

        var selector: AudioObjectPropertySelector {
            switch self {
            case .currentDevice: kAudioOutputUnitProperty_CurrentDevice
            case .deviceLatency: kAudioDevicePropertyLatency
            case .streams: kAudioDevicePropertyStreams
            case .streamLatency: kAudioStreamPropertyLatency
            case .safetyOffset: kAudioDevicePropertySafetyOffset
            case .bufferFrames: kAudioDevicePropertyBufferFrameSize
            case .rate: kAudioDevicePropertyNominalSampleRate
            case .uid: kAudioDevicePropertyDeviceUID
            }
        }
    }

    let read: Read
    let status: OSStatus?
}

/// The HAL property reads of the latency reader, as closures: the live value calls Core Audio, and
/// tests fail one read.
struct LatencyReads: Sendable {
    /// A `UInt32` property of an object in a scope: a latency, the safety offset, or the IO buffer
    /// frame size.
    var number:
        @Sendable (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope) throws(HALError) -> UInt32
    var rate: @Sendable (AudioObjectID) throws(HALError) -> Float64
    /// Nil when the read fails.
    var uid: @Sendable (AudioObjectID) -> String?
    var streams: @Sendable (AudioObjectID, AudioObjectPropertyScope) throws(HALError) -> [AudioStreamID]

    static let live = LatencyReads(
        number: { id, selector, scope throws(HALError) in try readValue(id, selector, scope: scope, as: UInt32.self) },
        rate: { id throws(HALError) in try readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) },
        uid: { readString($0, kAudioDevicePropertyDeviceUID) },
        streams: { id, scope throws(HALError) in
            try readArray(id, kAudioDevicePropertyStreams, scope: scope, as: AudioStreamID.self)
        })
}

/// The latency parts of a device in one scope that the HAL reports, in device frames: the device
/// latency, the latency of its first stream, and the safety offset. The input and the output read
/// them, and each keeps its failure rule: the stream latency has its own result, so the input can
/// read a failed one as 0.
struct LatencyParts {
    let device: UInt32
    /// A failed read, or a device with no stream in the scope (`kAudioDevicePropertyStreams` with
    /// no status).
    let stream: Result<UInt32, HALReadFault>
    let safety: UInt32

    /// The input latency (decision 0004): the three parts with no IO buffer, and a failed stream
    /// latency read as 0.
    var inputFrames: Int { Int(device) + Int((try? stream.get()) ?? 0) + Int(safety) }
}

extension LatencyParts {
    /// A failed read of the device latency, the stream list, or the safety offset throws.
    init(_ id: AudioObjectID, scope: AudioObjectPropertyScope, reads: LatencyReads) throws(HALReadFault) {
        device = try read(.deviceLatency) { selector throws(HALError) in try reads.number(id, selector, scope) }
        let streams = try read(.streams) { _ throws(HALError) in try reads.streams(id, scope) }
        stream = Result { () throws(HALReadFault) in
            guard let first = streams.first else {
                throw HALReadFault(read: .streams, status: nil)
            }
            return try read(.streamLatency) { selector throws(HALError) in
                try reads.number(first, selector, kAudioObjectPropertyScopeGlobal)
            }
        }
        safety = try read(.safetyOffset) { selector throws(HALError) in try reads.number(id, selector, scope) }
    }
}

/// The output term of device `device`, the current device of an engine output unit (decision
/// 0070, **Anchor**): its latency parts in the output scope and its IO buffer frame size at the
/// global scope, at its nominal rate, with its UID. Any failed read, the stream latency too, gives
/// a fault and no term.
func readOutputTerm(device: Result<AudioObjectID, HALReadFault>, reads: LatencyReads) -> Result<
    OutputTerm, OutputTermFault
> {
    do throws(HALReadFault) {
        let id = try device.get()
        let parts = try LatencyParts(id, scope: kAudioObjectPropertyScopeOutput, reads: reads)
        let stream = try parts.stream.get()
        let buffer = try read(.bufferFrames) { selector throws(HALError) in
            try reads.number(id, selector, kAudioObjectPropertyScopeGlobal)
        }
        let rate = try read(.rate) { _ throws(HALError) in try reads.rate(id) }
        guard let uid = reads.uid(id) else { throw HALReadFault(read: .uid, status: nil) }
        guard
            let term = OutputTerm.Device(
                latency: parts.device, streamLatency: stream, safetyOffset: parts.safety, bufferFrames: buffer,
                rate: rate, uid: uid)
        else { return .failure(.rate(rate)) }
        return .success(.device(term))
    } catch {
        return .failure(.read(error))
    }
}

/// The output term of the device that `engine` plays to, read after the engine start.
@Sendable func readOutputTerm(of engine: AVAudioEngine) -> Result<OutputTerm, OutputTermFault> {
    readOutputTerm(device: currentDevice(of: engine.outputNode.audioUnit), reads: .live)
}

/// `kAudioOutputUnitProperty_CurrentDevice` of an output unit.
private func currentDevice(of unit: AudioUnit?) -> Result<AudioObjectID, HALReadFault> {
    let selector = HALReadFault.Read.currentDevice.selector
    guard let unit else { return .failure(HALReadFault(read: .currentDevice, status: nil)) }
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioUnitGetProperty(unit, selector, kAudioUnitScope_Global, 0, &id, &size)
    guard status == noErr, id != kAudioObjectUnknown else {
        return .failure(HALReadFault(read: .currentDevice, status: status))
    }
    return .success(id)
}

/// Runs `body` with the selector of `read`, and gives a fault that names `read`.
private func read<Value>(
    _ read: HALReadFault.Read, _ body: (AudioObjectPropertySelector) throws(HALError) -> Value
) throws(HALReadFault) -> Value {
    do { return try body(read.selector) } catch .status(let status) {
        throw HALReadFault(read: read, status: status)
    } catch {
        throw HALReadFault(read: read, status: nil)
    }
}
