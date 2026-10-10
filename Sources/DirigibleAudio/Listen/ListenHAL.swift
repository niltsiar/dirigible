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

/// A raw pointer that a `@Sendable` detach captures. The HAL owns what it points to.
private struct ListenClient: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

/// The live listen attach (decision 0044): it checks the virtual format (packed float32), reads
/// the IO buffer size, creates the listen IOProc with the ring context, adds the rate and IsAlive
/// listeners with `input` as client data, and starts. The errors are those of `DeviceHAL.attach`.
func attachListenLive(_ input: ListenInput) throws(HALError) -> (inputBlock: Int, detach: Detach) {
    let id = input.id
    for stream in try readArray(
        id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, as: AudioStreamID.self)
    {
        let format = try readValue(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsPacked != 0
        else { throw .unsupportedFormat }
    }
    let inputBlock = Int(try readValue(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self))
    var procID: AudioDeviceIOProcID?
    var status = AudioDeviceCreateIOProcID(id, ListenRing.ioProc, input.ring.context, &procID)
    guard status == noErr, let procID else { throw .status(status) }

    // Each listener holds one retain of the input, released only after its removal returns noErr.
    let client = ListenClient(pointer: Unmanaged.passUnretained(input).toOpaque())
    var listening: [AudioObjectPropertyAddress] = []
    for property in listenProperties where status == noErr {
        var address = property
        _ = Unmanaged.passRetained(input)
        status = AudioObjectAddPropertyListener(id, &address, listenListener, client.pointer)
        if status == noErr {
            listening.append(property)
        } else {
            Unmanaged<ListenInput>.fromOpaque(client.pointer).release()
        }
    }
    if status == noErr { status = AudioDeviceStart(id, procID) }
    let added = listening
    let detach: Detach = {
        var clean = AudioDeviceStop(id, procID) == noErr
        clean = AudioDeviceDestroyIOProcID(id, procID) == noErr && clean
        for property in added {
            var address = property
            if AudioObjectRemovePropertyListener(id, &address, listenListener, client.pointer) == noErr {
                Unmanaged<ListenInput>.fromOpaque(client.pointer).release()
            } else {
                clean = false
            }
        }
        return clean
    }
    guard status == noErr else { throw detach() ? .undone(status) : .undoFailed }
    return (inputBlock, detach)
}
