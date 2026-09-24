import CoreAudio

/// One appearance of a device, from a successful `attach` to its detach: the object ID and the
/// ring (decision 0013). A device that comes back gets a new `DeviceInput` with a new ring, so a
/// late IOProc call of an old appearance never reaches the ring of a new one. It holds the writer
/// weakly, so a kept input never keeps the writer alive. Set in `init` only.
final class DeviceInput: @unchecked Sendable {
    let id: AudioObjectID
    let ring: CaptureRing
    weak var writer: DeviceWriter?

    init(id: AudioObjectID, ring: CaptureRing, writer: DeviceWriter) {
        self.id = id
        self.ring = ring
        self.writer = writer
    }
}

/// The Core Audio calls of one device writer, as closures: the live value calls Core Audio, and
/// tests give closures. Not a protocol: two values, one type.
struct DeviceHAL: Sendable {
    /// Nil when the UID is not present or a read fails.
    var lookUp: @Sendable (_ uid: String) -> (id: AudioObjectID, device: InputDevice)?
    /// Creates the IOProc with `input.ring.context` and starts the device.
    var attach: @Sendable (_ input: DeviceInput) throws(HALError) -> Detach
}

/// Stops the device and destroys the IOProc. True when every call returned noErr. False: a late
/// call can still come, so the caller keeps the ring.
typealias Detach = @Sendable () -> Bool

enum HALError: Error, Hashable, Sendable {
    case status(OSStatus)
    case unsupportedFormat
    case undoFailed
}

extension InputDevice {
    /// The devices with one or more input buffers. HAL reads only: no stream opens, and no
    /// permission prompt shows (probes P2 and P5).
    public static func all() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return (readArray(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self) ?? []).compactMap(read)
    }

    /// The object ID and the facts of the device with `uid`. Nil when the UID is not present
    /// (noErr and device 0, probe P2) or a read fails ('!obj').
    static func lookUp(uid: String) -> (id: AudioObjectID, device: InputDevice)? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier,
                &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown, let device = read(id) else { return nil }
        return (id, device)
    }

    /// The facts of device `id`. Nil when a read fails or the device has no input buffer.
    static func read(_ id: AudioObjectID) -> InputDevice? {
        let input = kAudioObjectPropertyScopeInput
        guard let uid = readString(id, kAudioDevicePropertyDeviceUID),
            let name = readString(id, kAudioObjectPropertyName),
            let rate = readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self),
            let rates = readArray(id, kAudioDevicePropertyAvailableNominalSampleRates, as: AudioValueRange.self),
            let latency = readValue(id, kAudioDevicePropertyLatency, scope: input, as: UInt32.self),
            let safetyOffset = readValue(id, kAudioDevicePropertySafetyOffset, scope: input, as: UInt32.self),
            let streams = readArray(id, kAudioDevicePropertyStreams, scope: input, as: AudioStreamID.self)
        else { return nil }
        let streamLatency = streams.first.flatMap { readValue($0, kAudioStreamPropertyLatency, as: UInt32.self) } ?? 0
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: input)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
            size >= MemoryLayout<AudioBufferList>.size
        else { return nil }
        let configuration = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { configuration.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, configuration) == noErr else { return nil }
        return InputDevice(
            uid: uid, name: name, nominalRate: rate, availableRates: rates,
            streamConfiguration: configuration.assumingMemoryBound(to: AudioBufferList.self), deviceLatency: latency,
            streamLatency: streamLatency, safetyOffset: safetyOffset)
    }

    /// The parse of the HAL property values. The input latency is the device latency, the stream
    /// latency, and the safety offset. Nil when the configuration has no buffer or the values
    /// fail the checks of the main init.
    init?(
        uid: String, name: String, nominalRate: Double, availableRates: [AudioValueRange],
        streamConfiguration: UnsafePointer<AudioBufferList>, deviceLatency: UInt32, streamLatency: UInt32,
        safetyOffset: UInt32
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: streamConfiguration))
        guard availableRates.allSatisfy({ $0.mMinimum <= $0.mMaximum }) else { return nil }
        self.init(
            uid: uid, name: name, nominalRate: nominalRate,
            availableRates: availableRates.map { $0.mMinimum...$0.mMaximum },
            channelsPerBuffer: buffers.map { Int($0.mNumberChannels) },
            latency: Int(deviceLatency) + Int(streamLatency) + Int(safetyOffset))
    }
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func readValue<Value>(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: Value.Type
) -> Value? where Value: BitwiseCopyable {
    var address = propertyAddress(selector, scope: scope)
    var size = UInt32(MemoryLayout<Value>.size)
    let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
    defer { value.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr,
        size == MemoryLayout<Value>.size
    else { return nil }
    return value.pointee
}

private func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

private func readArray<Element>(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: Element.Type
) -> [Element]? where Element: BitwiseCopyable {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
    let capacity = Int(size) / MemoryLayout<Element>.stride
    var status = noErr
    let elements = [Element](unsafeUninitializedCapacity: capacity) { buffer, count in
        if let base = buffer.baseAddress { status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, base) }
        count = status == noErr ? min(capacity, Int(size) / MemoryLayout<Element>.stride) : 0
    }
    return status == noErr ? elements : nil
}
