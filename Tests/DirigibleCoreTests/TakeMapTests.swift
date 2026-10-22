import Testing

@testable import DirigibleCore

/// The take time map of decision 0061.
struct TakeMapTests {
    /// Probe p1 of run take-sync: the two devices of take 4 of a tester session. The take start is
    /// the first host time of device 2 and the playhead is 3347, so the starts are the origins of
    /// the split clip IDs of that session: 3347 + round(9380083 ns x 48 kHz) - 156 = 3641, and 3347.
    @Test func alignedStartGivesTheTesterOriginDifference() throws {
        let recording = Recording(
            take: 4, playheadFrame: 3347, takeStartHostTimeNanos: 1_223_961_550_170_000, armedTracks: ["t1", "t2"])
        let mic = Capture(
            id: "take4-1-1", deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 1_223_961_559_550_083,
            sampleTime: 0, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 156)
        let call = Capture(
            id: "take4-2-1", deviceUID: "call", deviceName: "Call", hostTimeNanos: 1_223_961_550_170_000,
            sampleTime: 0, nominalSampleRate: 44_100, measuredSampleRate: 44_100, latency: 0)

        let first = try #require(mic.alignedStart(in: recording, sampleRate: 48_000))
        let second = try #require(call.alignedStart(in: recording, sampleRate: 48_000))

        #expect(first - second == 294)
        #expect([first, second] == [3641, 3347])
    }
}
