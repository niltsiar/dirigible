import DirigibleCore
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import DirigibleAudio

/// The sleep assertion of a take (criterion 13). Tests run in parallel in one process, so each
/// test looks only for the assertion ID of its own studio.
@MainActor
struct SleepAssertionTests {
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
    }

    /// The assertions of this process with `id`, as `IOPMCopyAssertionsByProcess` lists them.
    func listed(_ id: IOPMAssertionID) throws -> [NSDictionary] {
        var byProcess: Unmanaged<CFDictionary>?
        try #require(IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess)
        let processes = try #require(byProcess?.takeRetainedValue() as? [NSNumber: [NSDictionary]])
        return (processes[NSNumber(value: getpid())] ?? []).filter {
            ($0["AssertionId"] as? NSNumber)?.uint32Value == id
        }
    }

    /// Control: no assertion before the start.
    @Test func aTakeHoldsTheSleepAssertionUntilTheStopEnds() async throws {
        let studio = try await Studio.open(url)
        studio.environment = .test(TestHAL([mic]))
        #expect(studio.sleepAssertion == nil)

        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let id = try #require(studio.sleepAssertion?.id)
        let entry = try #require(try listed(id).first)
        #expect(entry["AssertName"] as? String == "Dirigible is recording")
        #expect(entry["AssertType"] as? String == "PreventUserIdleSystemSleep")
        try await studio.stopRecording()

        #expect(studio.sleepAssertion == nil)
        #expect(try listed(id).isEmpty)
    }

    @Test func aDiskLowStopEndsTheSleepAssertion() async throws {
        let free = FreeBytes(DiskRuleTests.margin)
        let studio = try await Studio.open(url)
        studio.environment = .test(TestHAL([mic]), free: free)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let id = try #require(studio.sleepAssertion?.id)
        try #require(try listed(id).count == 1)

        free.value = DiskRuleTests.margin - 1
        await until(limit: .seconds(10), "the take did not stop") { studio.transport == .idle }

        #expect(studio.lastTake?.end == .diskLow)
        #expect(studio.sleepAssertion == nil)
        #expect(try listed(id).isEmpty)
    }
}
