import Testing

@testable import DirigibleAudio

struct InputDeviceTests {
    func make(
        uid: String = "usb-1", name: String = "USB Mic", rate: Double = 48_000,
        rates: [ClosedRange<Double>] = [48_000...48_000], buffers: [Int] = [1, 2], latency: Int = 48
    ) -> InputDevice? {
        InputDevice(
            uid: uid, name: name, nominalRate: rate, availableRates: rates, channelsPerBuffer: buffers, latency: latency
        )
    }

    @Test func aGoodDeviceKeepsItsValues() throws {
        let device = try #require(make())
        #expect(device.uid == "usb-1")
        #expect(device.name == "USB Mic")
        #expect(device.channelCount == 3)
        #expect(device.latency == 48)
    }

    @Test func aNameScalarThatTheSessionCannotStoreBecomesASpace() {
        #expect(make(name: "A\u{FFFE}B")?.name == "A B")
        #expect(make(name: "A\u{01}\u{FFFF}B")?.name == "A  B")
        #expect(make(name: "AB")?.name == "AB")
    }

    @Test func aBadDeviceIsRefused() {
        #expect(make(uid: "usb\u{FFFE}1") == nil)
        #expect(make(rate: 0) == nil)
        #expect(make(rate: .nan) == nil)
        #expect(make(rates: [0...48_000]) == nil)
        #expect(make(rates: [48_000...Double.infinity]) == nil)
        #expect(make(buffers: []) == nil)
        #expect(make(buffers: [0]) == nil)
        #expect(make(latency: -1) == nil)
    }
}
