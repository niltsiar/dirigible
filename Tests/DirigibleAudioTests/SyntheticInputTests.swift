import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A `SyntheticInput` thread has no test of its own, so it keeps its attach miss and `wait()`
/// records it in the test that waits (run workflow-speed, F3).
@Suite struct SyntheticInputTests {
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
    }

    /// A package with a saved take start (`withTakeStart`) or without.
    private func writePackage(withTakeStart: Bool) throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        if withTakeStart {
            try session.setRecording(
                Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        }
        try session.write(to: url)
        try FileManager.default.createDirectory(
            at: url.appending(path: "Capture"), withIntermediateDirectories: true)
    }

    /// A writer that attaches `mic` of `hal`, as `Studio.begin` does.
    private func attachedWriter(_ hal: TestHAL) async -> DeviceWriter {
        let package = url
        let writer = DeviceWriter(
            device: mic, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { package }),
            hal: hal.hal, report: { _ in }, silenceLimit: noWatchdog, firstRecordLimit: noWatchdog)
        writer.start()
        await until("no attach") { hal.current("mic") != nil }
        return writer
    }

    @Test func aMissingTakeStartIsRecordedInTheTestThatWaits() async throws {
        try writePackage(withTakeStart: false)
        let hal = TestHAL([mic])
        let writer = await attachedWriter(hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(clock.run(seconds: 0.2), takeStartIn: url)
        await withKnownIssue {
            await input.wait()
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("found no saved take start") }
        }
        await writer.finish()
    }

    /// Control: with a saved take start, the feeder sends and `wait()` records no issue.
    @Test func aFeederWithATakeStartRecordsNoIssue() async throws {
        try writePackage(withTakeStart: true)
        let hal = TestHAL([mic])
        let writer = await attachedWriter(hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(takeStart) + 100_000_000)
        input.play(clock.run(seconds: 0.2), takeStartIn: url)
        await input.wait()
        await writer.finish()
    }
}
