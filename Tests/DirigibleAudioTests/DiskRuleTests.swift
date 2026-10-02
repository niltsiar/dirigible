import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The disk rule of decision 0004 (criteria 11 and 12): 1 GB of margin, and 7 bytes for each
/// sample and channel.
@MainActor
struct DiskRuleTests {
    static let margin: Int64 = 1_000_000_000
    let folder: TemporaryFolder
    let url: URL
    var sessionXML: URL { url.appending(path: "session.xml") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Mono tracks `t1` and `t2` at 48 kHz; `t1` on channel 1 of `mic`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL, free: FreeBytes) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, free: free)
        return studio
    }

    // MARK: Criterion 11

    /// 0.5 s of mono is 72,000 WAV bytes. One byte less than those bytes and the margin stops
    /// the take. Control: 2 GB free, and the take runs until `stopRecording`.
    @Test(arguments: [false, true])
    func theTakeStopsWhenTheDiskIsAlmostFull(low: Bool) async throws {
        let free = FreeBytes(2_000_000_000)
        let hal = TestHAL([mic])
        let studio = try await studio(hal, free: free)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let input = SyntheticInput(hal, "mic")
        // The live start saves the host time of now as the take start.
        var clock = DeviceClock(hostNanos: Double(try #require(studio.session.recording).takeStartHostTimeNanos))

        input.play(clock.run(seconds: 0.5))
        await input.wait()
        if low {
            free.value = Self.margin + 72_000 - 1
            // A watcher tick, three hops, and the finalize: a full suite holds the main actor for
            // seconds at each hop. The silence watchdog (60 s) is longer than the limit.
            await until(limit: .seconds(30), "the take did not stop") { studio.transport == .idle }
        } else {
            try await Task.sleep(for: .milliseconds(300))
            #expect(studio.transport == .recording(take: 1))
            // The transport bar value: 1 mono track, 72,000 WAV bytes (timeline-playback criterion 20).
            let left = Duration.seconds(Double(2_000_000_000 - Self.margin - 72_000) / 336_000)
            await until(limit: .seconds(10), "no record time left") { studio.recordTimeLeft == left }
            try await studio.stopRecording()
            #expect(studio.recordTimeLeft == nil)
        }

        #expect(studio.lastTake == TakeResult(take: 1, end: low ? .diskLow : .requested, gaps: [:]))
        #expect(studio.session.track("t1")?.clips.map(\.id) == ["take1-1-1"])
        #expect(studio.session.track("t1")?.clips.first?.length == 24_000)
        #expect(try Session(contentsOf: url).recording == nil)
    }

    // MARK: Criterion 12

    /// 2 mono tracks x 48,000 x 7 bytes = 672,000 bytes each second.
    @Test func theRemainingRecordTimeUsesSevenBytesPerSampleAfterTheMargin() async throws {
        let studio = try await studio(TestHAL([mic]), free: FreeBytes(Self.margin + 40_320_000))

        #expect(await studio.remainingRecordTime(armed: ["t1", "t2"]) == .seconds(60))
    }

    /// A pending take 1 with a CAF of 4,000,000 bytes, and `free` bytes.
    func pendingStudio(free: Int64) async throws -> Studio {
        var session = try Session(contentsOf: url)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try session.write(to: url)
        let capture = url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data(count: 4_000_000).write(to: capture.appending(path: "take1-1-1.caf"))
        // An earlier recovery died, so the open keeps the take pending.
        try Data().write(to: marker(in: url))
        let studio = try await studio(TestHAL([mic]), free: FreeBytes(free))
        try #require(studio.pendingTake?.take == 1)
        return studio
    }

    /// The WAV of a pending take needs 3 bytes for each 4 CAF bytes.
    @Test func aPendingTakeTakesItsWAVBytesFromTheRemainingTime() async throws {
        let studio = try await pendingStudio(free: Self.margin + 40_320_000)

        let left = try #require(await studio.remainingRecordTime(armed: ["t1", "t2"]))

        let expected = 60 - 3_000_000.0 / 672_000
        #expect(abs(Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18 - expected) < 1e-6)
    }

    /// Record-ui criterion 11: the finalize of 4,000,000 CAF bytes needs 3,000,000 WAV bytes.
    @Test func pendingSpaceGivesTheWAVBytesAndTheFreeBytes() async throws {
        let studio = try await pendingStudio(free: 5_000_000_000)

        let space = try #require(await studio.pendingSpace())

        #expect(space.needed == 3_000_000)
        #expect(space.free == 5_000_000_000)
    }

    /// Code gate 1, item 5: after a Finder rename and before the next write, `Studio.url` still
    /// has the old path. The WAV bytes come from the package that the lock holds.
    @Test func aRenamedPackageKeepsThePendingBytes() async throws {
        let studio = try await pendingStudio(free: Self.margin + 40_320_000)
        try #require(rename(url.path, folder.url.appending(path: "Renamed.dirigible").path) == 0)

        #expect(await studio.pendingSpace()?.needed == 3_000_000)
        let left = try #require(await studio.remainingRecordTime(armed: ["t1", "t2"]))
        let expected = 60 - 3_000_000.0 / 672_000
        #expect(abs(Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18 - expected) < 1e-6)
    }

    /// Control: no pending take gives nil.
    @Test func pendingSpaceWithNoPendingTakeIsNil() async throws {
        let studio = try await studio(TestHAL([mic]), free: FreeBytes())

        #expect(await studio.pendingSpace() == nil)
    }

    /// Less than 1 GB free throws and changes nothing. Control: 1 GB + 1 byte starts.
    @Test(arguments: [false, true])
    func aStartWithLessThanOneGBFreeThrowsAndChangesNothing(low: Bool) async throws {
        let before = try Data(contentsOf: sessionXML)
        let studio = try await studio(TestHAL([mic]), free: FreeBytes(low ? Self.margin - 1 : Self.margin + 1))

        guard low else {
            try await studio.startRecording(armed: ["t1"], playhead: 0)
            #expect(studio.transport == .recording(take: 1))
            try await studio.stopRecording()
            return
        }
        await #expect(throws: StudioError.diskLow) { try await studio.startRecording(armed: ["t1"], playhead: 0) }
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "Capture").path))
    }
}
