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
    /// Checks the virtual format (packed float32), creates the IOProc with `input.ring.context`,
    /// adds the C listeners (rate, stream configuration, IsAlive) with `input` as client data,
    /// and starts. A throw after the IOProc exists first runs the detach: `.undone` when that
    /// detach returns true, `.undoFailed` when it returns false.
    var attach: @Sendable (_ input: DeviceInput) throws(HALError) -> Detach
    /// Adds the device-list listener for the life of the take. Its client data holds the writer
    /// weakly, so a failed removal never keeps the writer alive.
    var watchDevices: @Sendable (_ writer: DeviceWriter) -> Detach
}

/// Stops the device, destroys the IOProc, and removes the listeners. True when every call
/// returned noErr. False: a late call can still come, so the caller keeps the ring and the
/// client data.
typealias Detach = @Sendable () -> Bool

enum HALError: Error, Hashable, Sendable {
    /// No IOProc and no listener exist.
    case status(OSStatus)
    case unsupportedFormat
    /// The attach failed after the IOProc existed, and its detach returned true. A listener call
    /// can still be in progress.
    case undone(OSStatus)
    case undoFailed
}

extension InputDevice {
    /// The devices with one or more input buffers. HAL reads only: no stream opens, and no
    /// permission prompt shows (probes P2 and P5).
    public static func all() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return ((try? readArray(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []).compactMap(read)
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
            let rate = try? readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self),
            let rates = try? readArray(id, kAudioDevicePropertyAvailableNominalSampleRates, as: AudioValueRange.self),
            let latency = try? readValue(id, kAudioDevicePropertyLatency, scope: input, as: UInt32.self),
            let safetyOffset = try? readValue(id, kAudioDevicePropertySafetyOffset, scope: input, as: UInt32.self),
            let streams = try? readArray(id, kAudioDevicePropertyStreams, scope: input, as: AudioStreamID.self),
            let channels = readChannels(id)
        else { return nil }
        let streamLatency = streams.first.flatMap { try? readValue($0, kAudioStreamPropertyLatency, as: UInt32.self) }
        return InputDevice(
            uid: uid, name: name, nominalRate: rate, availableRates: rates, channelsPerBuffer: channels,
            deviceLatency: latency, streamLatency: streamLatency ?? 0, safetyOffset: safetyOffset)
    }

    /// The parse of the HAL property values. The input latency is the device latency, the stream
    /// latency, and the safety offset. Nil when the configuration has no buffer or the values
    /// fail the checks of the main init.
    init?(
        uid: String, name: String, nominalRate: Double, availableRates: [AudioValueRange],
        streamConfiguration: UnsafePointer<AudioBufferList>, deviceLatency: UInt32, streamLatency: UInt32,
        safetyOffset: UInt32
    ) {
        self.init(
            uid: uid, name: name, nominalRate: nominalRate, availableRates: availableRates,
            channelsPerBuffer: channels(of: streamConfiguration), deviceLatency: deviceLatency,
            streamLatency: streamLatency, safetyOffset: safetyOffset)
    }

    private init?(
        uid: String, name: String, nominalRate: Double, availableRates: [AudioValueRange], channelsPerBuffer: [Int],
        deviceLatency: UInt32, streamLatency: UInt32, safetyOffset: UInt32
    ) {
        guard availableRates.allSatisfy({ $0.mMinimum <= $0.mMaximum }) else { return nil }
        self.init(
            uid: uid, name: name, nominalRate: nominalRate,
            availableRates: availableRates.map { $0.mMinimum...$0.mMaximum }, channelsPerBuffer: channelsPerBuffer,
            latency: Int(deviceLatency) + Int(streamLatency) + Int(safetyOffset))
    }
}

private func channels(of configuration: UnsafePointer<AudioBufferList>) -> [Int] {
    UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: configuration)).map { Int($0.mNumberChannels) }
}

/// The channel count of each input buffer of device `id`, or nil when the read fails.
private func readChannels(_ id: AudioObjectID) -> [Int]? {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
        size >= MemoryLayout<AudioBufferList>.size
    else { return nil }
    let configuration = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { configuration.deallocate() }
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, configuration) == noErr else { return nil }
    return channels(of: configuration.assumingMemoryBound(to: AudioBufferList.self))
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func readValue<Value>(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: Value.Type
) throws(HALError) -> Value where Value: BitwiseCopyable {
    var address = propertyAddress(selector, scope: scope)
    var size = UInt32(MemoryLayout<Value>.size)
    let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
    defer { value.deallocate() }
    let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, value)
    guard status == noErr else { throw .status(status) }
    guard size == MemoryLayout<Value>.size else { throw .status(kAudioHardwareBadPropertySizeError) }
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
) throws(HALError) -> [Element] where Element: BitwiseCopyable {
    var address = propertyAddress(selector, scope: scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
    guard status == noErr else { throw .status(status) }
    let capacity = Int(size) / MemoryLayout<Element>.stride
    let elements = [Element](unsafeUninitializedCapacity: capacity) { buffer, count in
        if let base = buffer.baseAddress { status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, base) }
        count = status == noErr ? min(capacity, Int(size) / MemoryLayout<Element>.stride) : 0
    }
    guard status == noErr else { throw .status(status) }
    return elements
}

// MARK: The live HAL (decision 0013). C callbacks only: a block listener cannot be removed from
// Swift (probe P7), and a C function in isolated code stops the process (probe P1b).

extension DeviceHAL {
    static let live = DeviceHAL(
        lookUp: { InputDevice.lookUp(uid: $0) },
        attach: { input throws(HALError) in try attachLive(input) },
        watchDevices: { writer in watchLive(writer) })
}

/// A raw pointer that a `@Sendable` detach captures. The HAL owns what it points to.
private struct ClientData: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

/// The device-list listener's client data: the writer, weakly.
private final class WriterBox: @unchecked Sendable {
    weak var writer: DeviceWriter?
    init(_ writer: DeviceWriter) { self.writer = writer }
}

/// The properties that each appearance listens to.
private let inputProperties = [
    propertyAddress(kAudioDevicePropertyNominalSampleRate),
    propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput),
    propertyAddress(kAudioDevicePropertyDeviceIsAlive),
]

/// The listener of one appearance. Its client data is the `DeviceInput`. The rate goes into the
/// ring of that appearance before the event, so the next record header carries it.
private let inputListener: AudioObjectPropertyListenerProc = { id, count, addresses, clientData in
    guard let clientData else { return noErr }
    let input = Unmanaged<DeviceInput>.fromOpaque(clientData).takeUnretainedValue()
    for address in UnsafeBufferPointer(start: addresses, count: Int(count)) {
        switch address.mSelector {
        case kAudioDevicePropertyNominalSampleRate:
            guard let rate = try? readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) else {
                continue
            }
            input.ring.setRate(rate)
            input.writer?.post(.rate(rate), from: input)
        case kAudioDevicePropertyStreamConfiguration:
            input.writer?.post(.layout(readChannels(id) ?? []), from: input)
        case kAudioDevicePropertyDeviceIsAlive:
            let alive = (try? readValue(id, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self)) == 1
            input.writer?.post(.alive(alive), from: input)
        default:
            continue
        }
    }
    return noErr
}

private let deviceListListener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<WriterBox>.fromOpaque(clientData).takeUnretainedValue().writer?.post(.devicesChanged, from: nil)
    return noErr
}

private func attachLive(_ input: DeviceInput) throws(HALError) -> Detach {
    let id = input.id
    for stream in try readArray(
        id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, as: AudioStreamID.self)
    {
        let format = try readValue(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsPacked != 0
        else { throw .unsupportedFormat }
    }
    input.ring.setRate(try readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self))
    var procID: AudioDeviceIOProcID?
    var status = AudioDeviceCreateIOProcID(id, CaptureRing.ioProc, input.ring.context, &procID)
    guard status == noErr, let procID else { throw .status(status) }

    // Each listener holds one retain of the input, released only after its removal returns noErr.
    let client = ClientData(pointer: Unmanaged.passUnretained(input).toOpaque())
    var listening: [AudioObjectPropertyAddress] = []
    for property in inputProperties where status == noErr {
        var address = property
        _ = Unmanaged.passRetained(input)
        status = AudioObjectAddPropertyListener(id, &address, inputListener, client.pointer)
        if status == noErr {
            listening.append(property)
        } else {
            Unmanaged<DeviceInput>.fromOpaque(client.pointer).release()
        }
    }
    if status == noErr { status = AudioDeviceStart(id, procID) }
    let added = listening
    let detach: Detach = {
        var clean = AudioDeviceStop(id, procID) == noErr
        clean = AudioDeviceDestroyIOProcID(id, procID) == noErr && clean
        for property in added {
            var address = property
            if AudioObjectRemovePropertyListener(id, &address, inputListener, client.pointer) == noErr {
                Unmanaged<DeviceInput>.fromOpaque(client.pointer).release()
            } else {
                clean = false
            }
        }
        return clean
    }
    guard status == noErr else { throw detach() ? .undone(status) : .undoFailed }
    return detach
}

private func watchLive(_ writer: DeviceWriter) -> Detach {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let client = ClientData(pointer: Unmanaged.passRetained(WriterBox(writer)).toOpaque())
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    guard AudioObjectAddPropertyListener(system, &address, deviceListListener, client.pointer) == noErr else {
        // No listener: the retry of a lost device still runs each 1 s.
        Unmanaged<WriterBox>.fromOpaque(client.pointer).release()
        return { true }
    }
    // The box stays for the process life: a call in progress during the removal can use it
    // after the removal returns (decision 0013).
    return {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        return AudioObjectRemovePropertyListener(system, &address, deviceListListener, client.pointer) == noErr
    }
}
