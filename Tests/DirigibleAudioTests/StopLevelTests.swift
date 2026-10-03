import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 8b criteria 6 to 11: the level at stop (decision 0031). Track t1 (mono, `mic` channel 1)
/// has c1: 3 s of a -24 dBFS sine over 0..<144 000 (-27 LUFS). Track t2 (mono) has c2: 3 s of a
/// -30 dBFS sine (-33 LUFS). A take records 1 s on t1 at 48 000, so it splits c1.
struct StopLevelTests {
    let package: MixPackage
    var url: URL { package.url }
    static let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: tone([(3, -24)], layout: .mono))
        try package.addFile("f2", channels: tone([(3, -30)], layout: .mono))
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 144_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 144_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
    }

    @MainActor func studio(peaks: Bool = false) async throws -> Studio {
        let studio = try await Studio.open(url, peakCache: peaks ? package.folder.url.appending(path: "Peaks") : nil)
        studio.environment = .test(TestHAL([Self.mic]))
        return studio
    }

    /// Records 1 s of a sine at `dBFS` on t1 from frame 48 000, then stops.
    @MainActor func recordOver(_ studio: Studio, dBFS: Double = -30) async throws {
        let hal = TestHAL([Self.mic])
        studio.environment = .test(hal)
        _ = try await studio.startTake(armed: ["t1"], devices: [Self.mic], playhead: 48_000, hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(records(tone([(1, dBFS)], layout: .mono), layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try await studio.stopRecording()
    }

    static func expectGain(
        _ session: Session, _ clip: ClipID, _ expected: Double, tolerance: Double = 0.1, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        AutoLevelTests.expectGain(session, clip, expected, tolerance: tolerance, label, sourceLocation: sourceLocation)
    }

    // MARK: Criterion 6 and 10

    @Test @MainActor func aStopLevelsOnlyTheTakeClips() async throws {
        let studio = try await studio(peaks: true)
        try await recordOver(studio)

        let ids = studio.session.track("t1")?.clips.map(\.id)
        #expect(ids == ["c1", "take1-1-1", "c1@96000"], "t1 clips: \(String(describing: ids))")
        #expect(studio.session.clip("take1-1-1")?.clip.range == 48_000..<96_000)
        Self.expectGain(studio.session, "take1-1-1", 14, "take clip in memory")
        Self.expectGain(try Session(contentsOf: url), "take1-1-1", 14, "take clip in session.xml")
        Self.expectGain(studio.session, "c1", 0, tolerance: 0, "old clip c1")
        Self.expectGain(studio.session, "c1@96000", 0, tolerance: 0, "old clip c1@96000")
        Self.expectGain(studio.session, "c2", 0, tolerance: 0, "old clip c2")
        #expect(await waitForPeaks(studio, "take1-1-1") != nil, "no peak pass for the take file")
    }

    @Test @MainActor func oneUndoRemovesTheLevelAndKeepsTheTake() async throws {
        let studio = try await studio()
        try await recordOver(studio)
        #expect(studio.canUndo)

        try studio.undo()
        Self.expectGain(studio.session, "take1-1-1", 0, tolerance: 0, "first undo")

        try studio.undo()
        #expect(studio.session.clip("take1-1-1") == nil, "second undo: the take clip stays")
        #expect(studio.session.track("t1")?.clips.map(\.id) == ["c1"], "second undo: c1 is not back")
    }

    /// A take of silence has no measurement, so it gives one entry.
    @Test @MainActor func aSilentTakeIsOneEntry() async throws {
        let studio = try await studio()
        try await recordOver(studio, dBFS: -.infinity)
        Self.expectGain(studio.session, "take1-1-1", 0, tolerance: 0, "silent take")

        try studio.undo()
        #expect(studio.session.clip("take1-1-1") == nil, "silent take: one undo keeps the take")
        #expect(!studio.canUndo, "silent take: more than one entry")
    }

    // MARK: Criteria 6b, 7, and 8: the internal completeTake with a test write

    /// A pending take of `segments` on t1 (mono): each part is a length in seconds and a level.
    static func pendingTake(_ segments: [(seconds: Double, dBFS: Double)]) throws -> TakePackage {
        let package = try TakePackage(playhead: 0)
        var host = takeStart + 10_000_000
        for (index, part) in segments.enumerated() {
            try package.segment(
                segment: index + 1, header: TakePackage.header(firstHost: host),
                samples: tone([part], layout: .mono)[0])
            host += UInt64((part.seconds + 1) * 1e9)
        }
        return package
    }

    @Test func theSegmentsOfATrackShareOneDelta() throws {
        let package = try Self.pendingTake([(3, -30), (1, -24)])
        let lock = try PackageLock(package.url)
        let outcome = completeTake(of: try package.read(), lock: lock, level: true) {
            session throws(SessionFileError) in try session.write(under: lock)
        }
        let gains = outcome.session.track("t1")?.clips.map(\.gain.dB) ?? []
        #expect(gains.count == 2, "segments: \(gains)")
        #expect(abs((gains.first ?? 0) - (gains.last ?? 0)) <= 0.001, "one delta: \(gains)")
        #expect(abs((gains.first ?? 0) - 11.9) <= 0.1, "one delta value: \(gains)")
    }

    @Test func theTakeWritesBeforeTheLevel() throws {
        let package = try Self.pendingTake([(1, -30)])
        let lock = try PackageLock(package.url)
        var writes: [Session] = []
        let outcome = completeTake(of: try package.read(), lock: lock, level: true) {
            session throws(SessionFileError) in
            writes.append(session)
            try session.write(under: lock)
        }
        #expect(writes.count == 2, "write order: \(writes.count) writes")
        Self.expectGain(writes.first ?? outcome.session, "take1-1-1", 0, tolerance: 0, "write order first")
        Self.expectGain(writes.last ?? outcome.session, "take1-1-1", 14, "write order second")
        #expect(outcome.placed == writes.first, "write order: placed is not the first write")
    }

    @Test func aFailedLevelWriteKeepsTheTake() throws {
        let package = try Self.pendingTake([(1, -30)])
        let lock = try PackageLock(package.url)
        var count = 0
        let outcome = completeTake(of: try package.read(), lock: lock, level: true) {
            session throws(SessionFileError) in
            count += 1
            if count == 2 { throw .writeFailed(step: "test", errno: EIO) }
            try session.write(under: lock)
        }
        #expect(outcome.error == nil, "failed level write: error \(String(describing: outcome.error))")
        Self.expectGain(outcome.session, "take1-1-1", 0, tolerance: 0, "failed level write in memory")
        #expect(try package.read() == outcome.session, "failed level write: session.xml is not the first write")
    }

    // MARK: Criterion 9: the other paths do not level

    @Test @MainActor func recoveryAtOpenDoesNotLevel() async throws {
        let package = try Self.pendingTake([(1, -30)])
        let studio = try await Studio.open(package.url)
        #expect(studio.pendingTake == nil && studio.takeError == nil)
        Self.expectGain(studio.session, "take1-1-1", 0, tolerance: 0, "recovery")
    }

    @Test @MainActor func retryDoesNotLevel() async throws {
        let package = try Self.pendingTake([(1, -30)])
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let studio = try await Studio.open(package.url)
        #expect(studio.pendingTake != nil)
        try await studio.retryFinalize()
        Self.expectGain(studio.session, "take1-1-1", 0, tolerance: 0, "retry")
    }

    @Test @MainActor func placementDoesNotLevel() async throws {
        let package = try Self.pendingTake([(1, -30)])
        var session = try finalizeTake(of: package.read(), in: package.url)
        try session.clear(.zero..<Frames.limit, on: "t1")
        try session.removeFile("take1-1-1")
        try session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))

        _ = try await studio.place(try #require(SegmentName(stem: "take1-1-1")))
        Self.expectGain(studio.session, "take1-1-1", 0, tolerance: 0, "placement")
    }

    // MARK: Criterion 11: Studio.level

    @Test @MainActor func levelIsOneEntryAndBlocksEdits() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4_800)
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }

        let leveling = Task { try await studio.level(["c1", "c2"], .eachClip) }
        await gate.entered()
        #expect(studio.transport == .leveling, "level hold: \(studio.transport)")
        #expect(throws: StudioError.busy) { try studio.edit { _ throws(SessionError) in } }
        gate.open()
        try await leveling.value

        #expect(studio.transport == .idle, "after the level: \(studio.transport)")
        Self.expectGain(studio.session, "c1", 8, "Cmd-L c1")
        Self.expectGain(studio.session, "c2", 14, "Cmd-L c2")
        #expect(try Session(contentsOf: url) == studio.session, "Cmd-L: session.xml has no level after the return")
        let after = await studio.renderOffline(frames: 4_800)
        #expect(after.joined().allSatisfy { $0 == 0 }, "Cmd-L: the Player still renders")
        let stop = await studio.play.player?.reading().frame
        #expect(
            studio.playhead == stop && studio.playhead > .zero,
            "Cmd-L playhead \(studio.playhead), stop \(String(describing: stop))")

        try studio.undo()
        Self.expectGain(studio.session, "c1", 0, tolerance: 0, "Cmd-L undo c1")
        Self.expectGain(studio.session, "c2", 0, tolerance: 0, "Cmd-L undo c2")
        #expect(!studio.canUndo, "Cmd-L: more than one entry")
    }

    @Test @MainActor func levelDuringATakeIsBusy() async throws {
        let studio = try await studio()
        let hal = TestHAL([Self.mic])
        studio.environment = .test(hal)
        _ = try await studio.startTake(armed: ["t1"], devices: [Self.mic], playhead: 0, hostTimeNanos: takeStart)
        let before = studio.session

        await #expect(throws: StudioError.busy) { try await studio.level(["c2"], .eachClip) }
        #expect(studio.session == before, "level during a take changed the session")
        #expect(studio.transport == .recording(take: 1), "level during a take: \(studio.transport)")
        try await studio.stopRecording()
    }

    /// The package left its volume: the level throws or levels nothing, and the studio is idle.
    @Test @MainActor func levelEndsIdleAfterAFault() async throws {
        let studio = try await studio()
        try FileManager.default.removeItem(at: url)

        try? await studio.level(["c1"], .eachClip)

        #expect(studio.transport == .idle, "level fault: \(studio.transport)")
        Self.expectGain(studio.session, "c1", 0, tolerance: 0, "level fault")
        do {
            try await studio.startRecording(armed: ["t1"])
            try await studio.stopRecording()
        } catch {
            #expect(error != .busy, "level fault: a start is busy")
        }
    }
}
