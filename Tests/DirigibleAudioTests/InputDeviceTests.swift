import CoreAudio
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
        #expect(make(rate: 0.4) == nil)
        #expect(make(rate: 1e300) == nil)
        #expect(make(rates: [0...48_000]) == nil)
        #expect(make(rates: [48_000...Double.infinity]) == nil)
        #expect(make(buffers: []) == nil)
        #expect(make(buffers: [0]) == nil)
        #expect(make(latency: -1) == nil)
    }

    func record(sampleTime: Double = 512, rate: Double = 48_000) -> InputRecord? {
        InputRecord(sampleTime: sampleTime, hostTimeNanos: 1, frameCount: 1, nominalRate: rate, buffers: [[0]])
    }

    /// The device writer rounds the rate to whole frames per second: a step of 0 never ends, and
    /// NaN or a rate past `Int64.max` traps. A sample time that is not finite traps in the gap math.
    @Test func aRecordWithABadRateOrSampleTimeIsRefused() {
        #expect(record() != nil)
        for rate in [0, 0.4, -48_000, .nan, .infinity, 1e300] { #expect(record(rate: rate) == nil) }
        for time in [Double.nan, .infinity, -.infinity] { #expect(record(sampleTime: time) == nil) }
    }

    /// Criterion P29 (run 2026-10-28-pre-roll): the shared latency reader keeps the input rule. A
    /// failed stream latency reads 0; a failed device latency, stream list, or safety offset gives
    /// no input latency, so `read` gives no `InputDevice`.
    @Test func inputKeepsItsFailureRule() throws {
        let input = kAudioObjectPropertyScopeInput
        func fake(failing: FakeLatencyHAL.Read) -> LatencyReads {
            FakeLatencyHAL(device: 40, stream: 1919, safety: 114, scope: input, failing: failing).reads
        }
        let noStream = try LatencyParts(FakeLatencyHAL.id, scope: input, reads: fake(failing: .streamLatency))
        #expect(noStream.inputFrames == 154)
        for failing in [FakeLatencyHAL.Read.latency, .streams, .safety] {
            #expect(throws: failing.fault) {
                try LatencyParts(FakeLatencyHAL.id, scope: input, reads: fake(failing: failing))
            }
        }
    }
}
