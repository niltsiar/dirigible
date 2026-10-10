import CoreAudio
import DirigibleCore

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
    /// The listen IOProc of a Listener (decision 0044): as `attach`, with the rate and IsAlive
    /// listeners, the IO buffer size of the device, and its nominal rate, read after the listener
    /// adds. No default, so each fake names it.
    var attachListen:
        @Sendable (_ input: ListenInput) throws(HALError) -> (inputBlock: Int, rate: Double, detach: Detach)
    /// The app source of `bundleID` as the system shows it now, with reads only (decision 0030).
    var lookUpApp: @Sendable (_ bundleID: String, _ layout: ChannelLayout) -> AppFound? = { _, _ in nil }
    /// A tap of the processes of `found` and its private aggregate: the aggregate object ID, its
    /// facts, and the teardown of both.
    var makeTap:
        @Sendable (_ found: AppFound) throws(HALError) -> (id: AudioObjectID, device: InputDevice, teardown: Detach) =
            { _ throws(HALError) in throw .status(kAudioHardwareUnsupportedOperationError) }
    /// The name of an app, else its bundle ID.
    var appName: @Sendable (_ bundleID: String) -> String = { $0 }
    /// True when a device with `uid` is in the device list (an output device too).
    var deviceExists: @Sendable (_ uid: String) -> Bool = { _ in true }
    /// True when the transport type of the device is virtual (a loopback device), or when the read
    /// fails: then the loopback rule of the speaker guard applies (fail closed).
    var isVirtual: @Sendable (_ id: AudioObjectID) -> Bool = { _ in false }
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
        return visibleInputs(
            ((try? readArray(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []).compactMap(read))
    }

    /// The object ID and the facts of the device with `uid`. Nil when the UID is not present
    /// (noErr and device 0, probe P2) or a read fails ('!obj').
    static func lookUp(uid: String) -> (id: AudioObjectID, device: InputDevice)? {
        guard let id = objectID(uid: uid), let device = read(id) else { return nil }
        return (id, device)
    }

    /// The object ID of the device with `uid`, of any direction. Nil when the UID is not present.
    static func objectID(uid: String) -> AudioObjectID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), qualifier,
                &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
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

func propertyAddress(
    _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<Value>(
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

func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func readArray<Element>(
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
        watchDevices: { writer in watchLive(writer) },
        attachListen: { input throws(HALError) in try attachListenLive(input) },
        lookUpApp: { bundleID, layout in DirigibleAudio.lookUpApp(bundleID, layout: layout) },
        makeTap: { found throws(HALError) in
            guard #available(macOS 14.2, *) else { throw .status(kAudioHardwareUnsupportedOperationError) }
            return try DirigibleAudio.makeTap(found)
        },
        appName: { DirigibleAudio.appName($0) }, deviceExists: { InputDevice.objectID(uid: $0) != nil },
        isVirtual: { device in
            isVirtualTransport(
                device, transport: { try? readValue($0, kAudioDevicePropertyTransportType, as: UInt32.self) },
                subdevices: {
                    try? readArray($0, kAudioAggregateDevicePropertyActiveSubDeviceList, as: AudioObjectID.self)
                })
        })
}

/// True when the transport of `device` is virtual, or when it is an aggregate with a virtual
/// active subdevice. A failed read counts as virtual (fail closed).
func isVirtualTransport(
    _ device: AudioObjectID, transport: (AudioObjectID) -> UInt32?, subdevices: (AudioObjectID) -> [AudioObjectID]?
) -> Bool {
    switch transport(device) {
    case kAudioDeviceTransportTypeVirtual, nil: true
    case kAudioDeviceTransportTypeAggregate:
        subdevices(device).map { $0.contains { isVirtualTransport($0, transport: transport, subdevices: subdevices) } }
            ?? true
    default: false
    }
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

/// The system properties that a writer listens to: the device list, and for an app writer also
/// the process list and the default output (decision 0030). Each posts `.devicesChanged`.
private func systemProperties(app: Bool) -> [AudioObjectPropertyAddress] {
    [propertyAddress(kAudioHardwarePropertyDevices)]
        + (app
            ? [
                propertyAddress(kAudioHardwarePropertyProcessObjectList),
                propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            ] : [])
}

private func watchLive(_ writer: DeviceWriter) -> Detach {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let client = ClientData(pointer: Unmanaged.passRetained(WriterBox(writer)).toOpaque())
    var added: [AudioObjectPropertyAddress] = []
    for property in systemProperties(app: writer.app != nil) {
        var address = property
        if AudioObjectAddPropertyListener(system, &address, deviceListListener, client.pointer) == noErr {
            added.append(property)
        }
    }
    // No listener: the retry of a lost device still runs each 1 s.
    guard !added.isEmpty else {
        Unmanaged<WriterBox>.fromOpaque(client.pointer).release()
        return { true }
    }
    // The box stays for the process life: a call in progress during the removal can use it
    // after the removal returns (decision 0013).
    let listening = added
    return {
        var clean = true
        for property in listening {
            var address = property
            clean =
                AudioObjectRemovePropertyListener(system, &address, deviceListListener, client.pointer) == noErr
                && clean
        }
        return clean
    }
}
