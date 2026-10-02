import DirigibleCore
import Foundation
import IOKit.pwr_mgt
import Testing

@testable import DirigibleAudio

/// The sleep assertion and the activity of a take (criterion 13 of run 2, criterion 8). Tests run in parallel in one process, so each
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
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
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

    /// The assertions of this process named `name`.
    func listed(named name: String) throws -> [NSDictionary] {
        var byProcess: Unmanaged<CFDictionary>?
        try #require(IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess)
        let processes = try #require(byProcess?.takeRetainedValue() as? [NSNumber: [NSDictionary]])
        return (processes[NSNumber(value: getpid())] ?? []).filter { $0["AssertName"] as? String == name }
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

    /// Criterion 8: the take also holds a latency-critical activity against App Nap. Its options
    /// let the system sleep, so it adds no second sleep assertion (P3). Control: the same lookup
    /// finds the IOPM assertion of the take.
    @Test func theActivityOfATakeAddsNoSleepAssertion() async throws {
        let studio = try await Studio.open(url)
        studio.environment = .test(TestHAL([mic]))
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let id = try #require(studio.sleepAssertion?.id)

        #expect(try listed(id).first?["AssertName"] as? String == "Dirigible is recording")
        #expect(try listed(named: SleepAssertion.activityReason).isEmpty)
        try await studio.stopRecording()
        #expect(studio.sleepAssertion == nil)
    }

    /// The stop takes a watcher tick with three main-actor hops, the drain, and the finalize. A
    /// full suite holds the main actor for seconds at each hop (process sample 2026-09-25: the
    /// window tests and the other `@MainActor` suites), so the limit is 30 s. The silence
    /// watchdog (60 s) is longer, so only the disk rule can end the take.
    @Test func aDiskLowStopEndsTheSleepAssertion() async throws {
        let free = FreeBytes(DiskRuleTests.margin)
        let studio = try await Studio.open(url)
        studio.environment = .test(TestHAL([mic]), free: free)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let id = try #require(studio.sleepAssertion?.id)
        try #require(try listed(id).count == 1)

        free.value = DiskRuleTests.margin - 1
        await until(limit: .seconds(30), "the take did not stop") { studio.transport == .idle }

        #expect(studio.lastTake?.end == .diskLow)
        #expect(studio.sleepAssertion == nil)
        #expect(try listed(id).isEmpty)
    }
}
