import CoreAudio
import Testing

@testable import DirigibleAudio

/// The live attach takes only an input stream of packed 32-bit float samples (decision 0013).
/// Each refused case fails one clause of the rule only.
struct LiveAttachFormatTests {
    static func format(
        id: AudioFormatID = kAudioFormatLinearPCM, bits: UInt32 = 32,
        flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: bits / 8, mFramesPerPacket: 1,
            mBytesPerFrame: bits / 8, mChannelsPerFrame: 1, mBitsPerChannel: bits, mReserved: 0)
    }

    @Test(arguments: [
        ("packed float32", format(), true),
        ("packed int32", format(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked), false),
        ("packed float64", format(bits: 64), false),
        ("float32 not packed", format(flags: kAudioFormatFlagIsFloat), false),
        ("AAC with float32 flags", format(id: kAudioFormatMPEG4AAC), false),
    ])
    func onlyPackedFloat32Passes(name: String, format: AudioStreamBasicDescription, passes: Bool) {
        #expect(isPackedFloat32(format) == passes, "format rule: \(name)")
    }
}
