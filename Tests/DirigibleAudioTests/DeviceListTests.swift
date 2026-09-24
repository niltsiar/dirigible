import CoreAudio
import Testing

@testable import DirigibleAudio

/// The device list (criterion 5): the parse of HAL property values, and read-only checks of the
/// real list of this Mac. No test opens a device or asks for the microphone.
struct DeviceListTests {
    /// Calls `body` with an input stream configuration of `channels` per buffer.
    func withConfiguration<Result>(_ channels: [Int], _ body: (UnsafePointer<AudioBufferList>) -> Result) -> Result {
        let list = AudioBufferList.allocate(maximumBuffers: max(1, channels.count))
        defer { free(list.unsafeMutablePointer) }
        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels.count)
        for (index, count) in channels.enumerated() {
            list[index] = AudioBuffer(mNumberChannels: UInt32(count), mDataByteSize: 0, mData: nil)
        }
        return body(list.unsafePointer)
    }

    func device(_ channels: [Int]) -> InputDevice? {
        withConfiguration(channels) { configuration in
            InputDevice(
                uid: "usb-1", name: "USB Mic", nominalRate: 48_000,
                availableRates: [AudioValueRange(mMinimum: 44_100, mMaximum: 44_100)],
                streamConfiguration: configuration, deviceLatency: 32, streamLatency: 16, safetyOffset: 8)
        }
    }

    @Test func theParseKeepsTheChannelsOfEachBufferAndAddsTheLatencies() throws {
        let parsed = try #require(device([2, 1]))
        #expect(parsed.channelsPerBuffer == [2, 1])
        #expect(parsed.channelCount == 3)
        #expect(parsed.latency == 56)
        #expect(parsed.availableRates == [44_100...44_100])
    }

    /// Control: an output-only device has no input buffer (probe P2).
    @Test func aConfigurationWithNoBufferIsNotAnInputDevice() {
        #expect(device([]) == nil)
    }

    /// The real list, read only: invariants, because each Mac has other devices.
    @Test func eachListedDeviceHasInputAndItsUIDLooksItUp() {
        let devices = InputDevice.all()
        #expect(Set(devices.map(\.uid)).count == devices.count)
        for device in devices {
            #expect(device.channelCount > 0)
            #expect(InputDevice.lookUp(uid: device.uid)?.device == device)
        }
    }

    /// A missing UID is noErr with device 0 (probe P2), and a gone object fails its reads.
    @Test func aMissingUIDOrAGoneObjectGivesNil() {
        #expect(InputDevice.lookUp(uid: "no-such-device") == nil)
        #expect(InputDevice.read(AudioObjectID(0xDEAD)) == nil)
    }
}
