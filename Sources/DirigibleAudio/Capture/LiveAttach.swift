import CoreAudio

/// The format rule of a live attach (decision 0013): linear PCM of packed 32-bit floats. The
/// IOProc copies the input buffers as they are, so the ring reads only this format.
func isPackedFloat32(_ format: AudioStreamBasicDescription) -> Bool {
    format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
        && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mFormatFlags & kAudioFormatFlagIsPacked != 0
}

/// Throws `.unsupportedFormat` when an input stream of `id` has a virtual format that is not
/// packed float32.
func checkFloatInput(_ id: AudioObjectID) throws(HALError) {
    for stream in try readArray(
        id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, as: AudioStreamID.self)
    {
        let format = try readValue(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
        guard isPackedFloat32(format) else { throw .unsupportedFormat }
    }
}

/// The shared part of the live take attach and the live listen attach (decisions 0013 and 0044).
/// It creates the IOProc with `context`, adds the listener of each of `properties` with `client`
/// as client data, runs `afterListeners`, and starts the device. The errors are those of
/// `DeviceHAL.attach`: after the IOProc exists, a failure runs the detach first.
func attachIOProc<Client: AnyObject>(
    _ id: AudioObjectID, ioProc: AudioDeviceIOProc, context: UnsafeMutableRawPointer, client: Client,
    properties: [AudioObjectPropertyAddress], listener: AudioObjectPropertyListenerProc,
    afterListeners: () -> OSStatus = { noErr }
) throws(HALError) -> Detach {
    var procID: AudioDeviceIOProcID?
    var status = AudioDeviceCreateIOProcID(id, ioProc, context, &procID)
    guard status == noErr, let procID else { throw .status(status) }

    // Each listener holds one retain of the client, released only after its removal returns noErr.
    let data = ClientData(pointer: Unmanaged.passUnretained(client).toOpaque())
    var listening: [AudioObjectPropertyAddress] = []
    for property in properties where status == noErr {
        var address = property
        _ = Unmanaged.passRetained(client)
        status = AudioObjectAddPropertyListener(id, &address, listener, data.pointer)
        if status == noErr {
            listening.append(property)
        } else {
            Unmanaged<Client>.fromOpaque(data.pointer).release()
        }
    }
    if status == noErr { status = afterListeners() }
    if status == noErr { status = AudioDeviceStart(id, procID) }
    let added = listening
    let detach: Detach = {
        var clean = AudioDeviceStop(id, procID) == noErr
        clean = AudioDeviceDestroyIOProcID(id, procID) == noErr && clean
        for property in added {
            var address = property
            if AudioObjectRemovePropertyListener(id, &address, listener, data.pointer) == noErr {
                Unmanaged<Client>.fromOpaque(data.pointer).release()
            } else {
                clean = false
            }
        }
        return clean
    }
    guard status == noErr else { throw detach() ? .undone(status) : .undoFailed }
    return detach
}
