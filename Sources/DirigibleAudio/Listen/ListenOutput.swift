import AudioToolbox
import CoreAudio

/// The output side of a Listener (decision 0044), as closures: the live value makes an AUHAL
/// default output unit, and tests give closures. Not a protocol: two values, one type.
struct ListenOutput: Sendable {
    /// Installs the speaker guard of `ring` and reads the flag once. False when a listener add
    /// failed: the ring then plays zeros for good.
    var watch: @Sendable (_ ring: ListenRing) -> Bool
    /// Removes the speaker listeners of `ring`. The ring adds no listener after it.
    var unwatch: @Sendable (_ ring: ListenRing) -> Void
    /// Makes and starts an output unit that pulls `ring` at the input `rate`. It calls
    /// `ring.prepare` with the pull of the unit before the start. Returns the stop: true when
    /// the unit stopped (a barrier, probe P9) and is disposed. False: a render can still come, so
    /// the caller keeps the ring for the process life.
    var start: @Sendable (_ ring: ListenRing, _ rate: Double, _ inputBlock: Int) throws(HALError) -> Detach
    /// True only for `live`. Closures have no equality, so a test checks this flag: no test
    /// support environment plays to the real speakers.
    var isLive = false

    static let live = ListenOutput(
        watch: { SpeakerGuard.open($0) }, unwatch: { SpeakerGuard.close($0) },
        start: { ring, rate, inputBlock throws(HALError) in try startLive(ring, rate: rate, inputBlock: inputBlock) },
        isLive: true)

    /// The default output of `offline`: no test device has this ID, so it is never a loopback.
    static let offlineOutput: AudioObjectID = 999

    /// For tests and `DIRIGIBLE_AUDIO_OUTPUT=none`: no unit and no HAL call. The flag is
    /// `speakers`, stored through the same refresh, and the pull is 512 frames. With `startFails`,
    /// each start throws. A test renders with `ring.pull`.
    static func offline(speakers: Bool = false, startFails: Bool = false) -> ListenOutput {
        ListenOutput(
            watch: {
                SpeakerGuard.refresh($0, output: { offlineOutput }, watch: { _ in }, speakers: { _ in speakers })
                return true
            },
            unwatch: { SpeakerGuard.close($0, remove: { _ in }) },
            start: { ring, rate, inputBlock throws(HALError) in
                if startFails { throw .status(kAudioHardwareUnspecifiedError) }
                ring.prepare(rate: rate, inputBlock: inputBlock, pull: 512)
                return { true }
            })
    }
}

/// An output unit that a `@Sendable` stop captures.
private struct OutputUnit: @unchecked Sendable {
    let unit: AudioUnit
}

/// The default output unit with a 2-channel non-interleaved Float32 client format at the input
/// rate, so the unit converts the rate and follows the default output (probes P5 and P6).
private func startLive(_ ring: ListenRing, rate: Double, inputBlock: Int) throws(HALError) -> Detach {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else {
        throw .status(kAudioHardwareUnsupportedOperationError)
    }
    var instance: AudioUnit?
    var status = AudioComponentInstanceNew(component, &instance)
    guard status == noErr, let instance else { throw .status(status) }
    var format = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32,
        mReserved: 0)
    status = AudioUnitSetProperty(
        instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    var callback = AURenderCallbackStruct(inputProc: ListenRing.render, inputProcRefCon: ring.context)
    if status == noErr {
        status = AudioUnitSetProperty(
            instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }
    if status == noErr { status = AudioUnitInitialize(instance) }
    if status == noErr {
        ring.prepare(rate: rate, inputBlock: inputBlock, pull: pull(of: instance, rate: rate))
        status = AudioOutputUnitStart(instance)
    }
    guard status == noErr else {
        AudioUnitUninitialize(instance)
        AudioComponentInstanceDispose(instance)
        throw .status(status)
    }
    let unit = OutputUnit(unit: instance)
    return {
        guard AudioOutputUnitStop(unit.unit) == noErr else { return false }
        AudioUnitUninitialize(unit.unit)
        AudioComponentInstanceDispose(unit.unit)
        return true
    }
}

/// The IO buffer of the current device of `unit` at the input `rate`, rounded up.
/// ponytail: 512 when a read fails; a larger pull makes a new rule at the render (DriftRule).
private func pull(of unit: AudioUnit, rate: Double) -> Int {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
            == noErr,
        let frames = try? readValue(device, kAudioDevicePropertyBufferFrameSize, as: UInt32.self),
        let outputRate = try? readValue(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self),
        outputRate > 0
    else { return 512 }
    return Int((Double(frames) * rate / outputRate).rounded(.up))
}
