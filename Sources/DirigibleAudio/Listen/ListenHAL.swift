import CoreAudio

/// One appearance of a listened device, from a successful attach to its detach (decision 0044),
/// as `DeviceInput` of a take. A device that comes back gets a new input with a new ring. It
/// holds the Listener weakly, so a kept input never keeps the Listener alive. Set in `init` only.
final class ListenInput: @unchecked Sendable {
    let id: AudioObjectID
    let ring: ListenRing
    weak var listener: Listener?

    init(id: AudioObjectID, ring: ListenRing, listener: Listener) {
        self.id = id
        self.ring = ring
        self.listener = listener
    }
}

/// The properties that each listen appearance listens to.
private let listenProperties = [
    propertyAddress(kAudioDevicePropertyNominalSampleRate),
    propertyAddress(kAudioDevicePropertyDeviceIsAlive),
]

/// The listener of one listen appearance. Its client data is the `ListenInput`.
private let listenListener: AudioObjectPropertyListenerProc = { id, count, addresses, clientData in
    guard let clientData else { return noErr }
    let input = Unmanaged<ListenInput>.fromOpaque(clientData).takeUnretainedValue()
    for address in UnsafeBufferPointer(start: addresses, count: Int(count)) {
        switch address.mSelector {
        case kAudioDevicePropertyNominalSampleRate:
            guard let rate = try? readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) else {
                continue
            }
            input.listener?.post(.rate(rate), from: input)
        case kAudioDevicePropertyDeviceIsAlive:
            let alive = (try? readValue(id, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self)) == 1
            input.listener?.post(.alive(alive), from: input)
        default:
            continue
        }
    }
    return noErr
}

/// The live listen attach (decision 0044): it checks the virtual format (packed float32), reads
/// the IO buffer size, creates the listen IOProc with the ring context, adds the rate and IsAlive
/// listeners with `input` as client data, reads the nominal rate, and starts. The errors are those
/// of `DeviceHAL.attach`.
func attachListenLive(_ input: ListenInput) throws(HALError) -> (inputBlock: Int, rate: Double, detach: Detach) {
    let id = input.id
    try checkFloatInput(id)
    let inputBlock = Int(try readValue(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self))
    var rate = 0.0
    let detach = try attachIOProc(
        id, ioProc: ListenRing.ioProc, context: input.ring.context, client: input, properties: listenProperties,
        listener: listenListener
    ) {
        // After the listener adds: a rate change from now on calls the rate listener.
        guard let read = try? readValue(id, kAudioDevicePropertyNominalSampleRate, as: Float64.self) else {
            return kAudioHardwareUnspecifiedError
        }
        rate = read
        return noErr
    }
    return (inputBlock, rate, detach)
}
