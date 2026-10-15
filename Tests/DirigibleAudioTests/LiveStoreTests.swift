import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The live store and the head of a take in `Studio` (live take view, criteria C9 to C13). The
/// store takes the reports of the take until the hand-off, also during `.finalizing`. Each take
/// starts in the past of the host clock, so its spans are not past the 5 s limit of `add`.
@MainActor
struct LiveStoreTests {
    let folder: TemporaryFolder
    let url: URL
    let busy = Duration.seconds(20)
    /// 48 kHz with a latency of 48 frames (1 ms).
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 48)!
    let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on `mic` (arm 1) and track `t2` on `box` (arm 2), both mono.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "box", channels: .mono(1)), track: "t2")
        try session.write(to: url)
    }

    /// The host clock of the take anchor.
    func now() -> UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }

    /// With `gate`, each finalize waits in it.
    func open(_ hal: TestHAL, gate: AsyncGate? = nil) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, beforeFinalize: { await gate?.wait() })
        return studio
    }

    /// Starts a take on `t1` and `t2` whose start host time is `ago` seconds before now.
    /// Returns that host time.
    func start(_ studio: Studio, ago: Double = 30, playhead: Frames = 0) async throws -> UInt64 {
        let host = now() - UInt64(ago * 1e9)
        _ = try await studio.startTake(
            armed: ["t1", "t2"], devices: [mic, box], playhead: playhead, hostTimeNanos: host)
        return host
    }

    func levels(take: Int = 1, arm: Int, from: UInt64, to: UInt64, latencyNanos: Int64 = 0) -> Report {
        .levels(
            take: take, arms: [arm: ArmLevel(peak: 0.5, rms: 0.25, written: from..<to)], latencyNanos: latencyNanos,
            droppedFrames: 0)
    }

    /// Plays `seconds` of records on each device from 0.1 s after `host`, then waits until the
    /// store of each track has bins.
    func record(_ hal: TestHAL, _ studio: Studio, from host: UInt64, seconds: Double) async {
        let inputs = [SyntheticInput(hal, "mic"), SyntheticInput(hal, "box")]
        for input in inputs {
            var clock = DeviceClock(hostNanos: Double(host) + 100_000_000)
            input.play(clock.run(seconds: seconds))
        }
        for input in inputs { await input.wait() }
        await until(limit: busy, "the reports of the take added no bins") {
            studio.livePeaks(of: "t1")?.covered.isEmpty == false && studio.livePeaks(of: "t2")?.covered.isEmpty == false
        }
    }

    func readOnlyClips() throws -> URL {
        let clips = url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        return clips
    }

    // MARK: C9

    @Test func aReportOfTheTakeAddsBins() async throws {
        let studio = try await open(TestHAL([mic, box]))
        let host = try await start(studio)
        let version = studio.liveVersion

        studio.apply(
            levels(arm: 1, from: host + 1_000_000_000, to: host + 1_100_000_000, latencyNanos: 1_000_000),
            generation: studio.generation)

        #expect(
            studio.livePeaks(of: "t1")?.covered == [Frames(47_952)..<Frames(52_752)],
            "a report of the take added no bins")
        #expect(studio.liveVersion == version + 1)
        #expect(studio.livePeaks(of: "t2")?.covered == [])
        #expect(studio.liveTracks["t1"]?.peak == 0.5)
        try await studio.stopRecording()
    }

    /// `stop` empties `armed` before the finalize; the store keeps the arm map of the take.
    @Test func aReportDuringTheFinalizeAddsBins() async throws {
        let gate = AsyncGate()
        defer { gate.open() }
        let studio = try await open(TestHAL([mic, box]), gate: gate)
        let host = try await start(studio)
        let stop = Task { try await studio.stopRecording() }
        await gate.entered()
        #expect(studio.transport == .finalizing(take: 1))
        #expect(studio.liveTracks.isEmpty)
        let version = studio.liveVersion

        studio.apply(
            levels(arm: 2, from: host + 2_000_000_000, to: host + 2_100_000_000), generation: studio.generation)

        #expect(
            studio.livePeaks(of: "t2")?.covered == [Frames(96_000)..<Frames(100_800)],
            "a report of the take during the finalize added no bins")
        #expect(studio.liveVersion == version + 1)
        #expect(studio.liveTracks.isEmpty)
        #expect(studio.transport == .finalizing(take: 1))
        gate.open()
        try await stop.value

        let after = studio.liveVersion
        studio.apply(
            levels(arm: 2, from: host + 3_000_000_000, to: host + 3_100_000_000), generation: studio.generation)
        #expect(studio.liveVersion == after, "a report after the hand-off raised the version")
        #expect(studio.livePeaks(of: "t2") == nil)
    }

    @Test func aLateReportOfAnOldTakeAddsNothing() async throws {
        let studio = try await open(TestHAL([mic, box]))
        let host = try await start(studio)
        let version = studio.liveVersion
        let (from, to) = (host + 1_000_000_000, host + 1_100_000_000)

        studio.apply(levels(take: 2, arm: 1, from: from, to: to), generation: studio.generation)
        studio.apply(levels(arm: 1, from: from, to: to), generation: studio.generation - 1)

        #expect(studio.liveVersion == version, "a report of another take or generation raised the version")
        #expect(studio.livePeaks(of: "t1")?.covered == [])
        // Control: the same report of this take adds bins.
        studio.apply(levels(arm: 1, from: from, to: to), generation: studio.generation)
        #expect(studio.liveVersion == version + 1)
        try await studio.stopRecording()
    }

    /// F1: the view reads the lowest added frame of all tracks in session frames, and the read
    /// clears it. A late span of one track sets it below a newer span of the other track. A
    /// span after a gap sets it to the end of the covered range before it (V1).
    @Test func theViewTakesTheLowestAddedFrameOnce() async throws {
        let studio = try await open(TestHAL([mic, box]))
        let host = try await start(studio, playhead: 48_000)
        let generation = studio.generation
        studio.apply(levels(arm: 1, from: host, to: host + 2_000_000_000), generation: generation)
        studio.apply(levels(arm: 2, from: host, to: host + 1_010_000_000), generation: generation)
        #expect(studio.takeLiveAddedFrom() == Frames(48_000), "the take start")

        studio.apply(levels(arm: 1, from: host + 2_000_000_000, to: host + 2_100_000_000), generation: generation)
        studio.apply(levels(arm: 2, from: host + 1_010_000_000, to: host + 1_100_000_000), generation: generation)

        #expect(studio.takeLiveAddedFrom() == Frames(96_000), "the start of the lowest bin, in session frames")
        #expect(studio.takeLiveAddedFrom() == nil, "the read cleared it")
        studio.apply(levels(arm: 1, from: host + 3_000_000_000, to: host + 3_100_000_000), generation: generation)
        #expect(studio.takeLiveAddedFrom() == Frames(148_800), "the end of the covered range before the gap")
        try await studio.stopRecording()
    }

    // MARK: C10

    @Test func aNewTakeStartsWithNoBins() async throws {
        let hal = TestHAL([mic, box])
        let studio = try await open(hal)
        let first = try await start(studio)
        await record(hal, studio, from: first, seconds: 0.5)
        try await studio.stopRecording()
        let files = Array(studio.session.files.keys)
        #expect(files.count == 2)
        let epoch = studio.liveEpoch

        let second = try await start(studio, ago: 20, playhead: 1_000_000)

        #expect(studio.liveEpoch == epoch + 1, "a take start did not raise the epoch")
        #expect(studio.livePeaks(of: "t1")?.covered == [], "the new take has no empty live peaks")
        #expect(studio.livePeaks(of: "t1")?.startHostNanos == second)
        #expect(studio.livePeaks(of: "t1")?.origin == Frames(1_000_000))
        #expect(files.allSatisfy { studio.liveFiles[$0] != nil }, "the take start dropped the file map")
        try await studio.stopRecording()
    }

    @Test func aFinalizeErrorDropsTheBins() async throws {
        let hal = TestHAL([mic, box])
        let studio = try await open(hal)
        let clips = try readOnlyClips()
        defer { chmod(clips.path, 0o755) }
        let host = try await start(studio)
        await record(hal, studio, from: host, seconds: 0.5)
        let epoch = studio.liveEpoch

        await #expect {
            try await studio.stopRecording()
        } throws: { error in
            guard case .finalize(.writeFailed) = error as? StudioError else { return false }
            return true
        }

        #expect(studio.pendingTake?.take == 1)
        #expect(studio.livePeaks(of: "t1") == nil, "a finalize error kept the bins")
        #expect(studio.livePeaks(of: "t2") == nil)
        #expect(studio.liveEpoch == epoch + 1, "a finalize error did not raise the epoch")
    }

    // MARK: C11

    /// Take 1 gives files f1 (`t1`) and f2 (`t2`). Before take 2, f1 has `.unavailable` peaks
    /// and f2 `.computing`. The pool file `old` has a clip on the armed track `t1`.
    @Test func theTakeFilesGetTheLivePeaks() async throws {
        let hal = TestHAL([mic, box])
        let studio = try await open(hal)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addFile(AudioFile(id: "old", path: "old.wav", layout: .mono, length: 100))
            try session.place(Clip(id: "c1", file: "old", start: 5_000_000, offset: 0, length: 100), on: "t1")
        }
        func file(of track: TrackID, in ids: Set<FileID>) -> Clip? {
            studio.session.track(track)?.clips.first { ids.contains($0.file) }
        }

        let first = try await start(studio)
        let epoch = studio.liveEpoch
        await record(hal, studio, from: first, seconds: 0.5)
        try await studio.stopRecording()
        let one = Set(studio.session.files.keys).subtracting(["old"])
        #expect(one.count == 2)
        #expect(studio.liveEpoch == epoch + 1, "the hand-off did not raise the epoch")
        let f1 = try #require(file(of: "t1", in: one))
        let f2 = try #require(file(of: "t2", in: one))
        #expect(f1.start == Frames(4_752) && f2.start == Frames(4_800))
        #expect(studio.liveFiles[f1.file]?.anchor == Frames(4_752), "the anchor of the take file")
        #expect(studio.liveFiles[f2.file]?.anchor == Frames(4_800))
        #expect(studio.liveFiles[f1.file]?.peaks.covered.isEmpty == false)
        #expect(studio.liveFiles["old"] == nil, "a file in the pool before the take got live peaks")
        #expect(studio.livePeaks(of: "t1") == nil)

        studio.peakLoad.states[f1.file] = .unavailable
        studio.peakLoad.states[f2.file] = .computing
        let second = try await start(studio, ago: 20, playhead: 2_000_000)
        await record(hal, studio, from: second, seconds: 0.5)
        try await studio.stopRecording()

        let two = Set(studio.session.files.keys).subtracting(one).subtracting(["old"])
        #expect(two.count == 2)
        for id in two {
            let clip = try #require(studio.session.tracks.flatMap(\.clips).first { $0.file == id })
            #expect(
                studio.liveFiles[id]?.anchor == clip.start - clip.offset, "file \(id) has no live peaks or anchor"
            )
        }
        #expect(studio.liveFiles[f1.file] == nil, "an entry with unavailable peaks stayed")
        #expect(studio.liveFiles[f2.file] != nil, "an entry with peaks that are not ready went")
        #expect(studio.liveFiles["old"] == nil, "a file in the pool before the take got live peaks")
    }

    // MARK: C12

    /// 9.8 s of records from 0.1 s after the take start, then 0.2 s more in the ring at the
    /// stop, so the drains of the finish report during `.finalizing`.
    @Test func theFinalClipStartsWhereTheLiveSpanStarts() async throws {
        let hal = TestHAL([mic])
        let studio = try await open(hal)
        let host = now() - 30_000_000_000
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], playhead: 0, hostTimeNanos: host)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock(hostNanos: Double(host) + 100_000_000)
        input.play(clock.run(seconds: 9.8))
        await input.wait()
        // 9.9 s less the latency of 48 frames.
        await until(limit: busy, "the reports of the take did not cover 9.9 s") {
            studio.livePeaks(of: "t1")?.covered.last?.upperBound == Frames(475_152)
        }
        let ring = try #require(hal.current("mic")).ring
        for record in clock.run(seconds: 0.2) { send(record, to: ring) }
        try await studio.stopRecording()

        let clip = try #require(studio.session.track("t1")?.clips.first)
        #expect(clip.start == Frames(4_752) && clip.end == Frames(484_752), "the clip is \(clip.start)..<\(clip.end)")
        let entry = try #require(studio.liveFiles[clip.file])
        #expect(entry.peaks.covered.count == 1)
        let first = (entry.peaks.covered.first?.lowerBound ?? .zero) + entry.peaks.origin
        let last = (entry.peaks.covered.last?.upperBound ?? .zero) + entry.peaks.origin
        #expect(abs(first.count - clip.start.count) <= 1, "the live span starts at \(first), the clip at \(clip.start)")
        #expect(abs(last.count - clip.end.count) <= 48, "the live span ends at \(last), the clip at \(clip.end)")
    }

    // MARK: C13

    @Test func theHeadMovesThenFreezesAtTheStop() async throws {
        let gate = AsyncGate()
        defer { gate.open() }
        let studio = try await open(TestHAL([mic, box]), gate: gate)
        let host = try await start(studio, ago: 10, playhead: 1_000)

        #expect(studio.liveHead(atHostNanos: host + 2_000_000_000) == Frames(97_000))
        #expect(studio.liveHead(atHostNanos: host + 3_500_000_000) == Frames(169_000))
        let before = now()
        let head = studio.liveHead()?.count ?? -1
        let after = now()
        let low = 1_000 + Int(Double(before - host) * 48_000 / 1e9)
        let high = 1_000 + Int((Double(after - host) * 48_000 / 1e9).rounded(.up))
        #expect((low...high).contains(head), "liveHead() is \(head), not in \(low)...\(high) of the anchor clock")

        let stop = Task { try await studio.stopRecording() }
        await gate.entered()
        #expect(studio.transport == .finalizing(take: 1))
        let stopped = try #require(studio.live.stopHostNanos, "the stop recorded no host time")
        let frozen = Frames(1_000 + Int((Double(stopped &- host) * 48_000 / 1e9).rounded()))
        #expect(studio.liveHead(atHostNanos: stopped + 60_000_000_000) == frozen, "the head moved after the stop")
        #expect(studio.liveHead() == frozen)
        gate.open()
        try await stop.value

        #expect(studio.liveHead() == nil, "a head at .idle")
        #expect(studio.liveHead(atHostNanos: stopped) == nil)
    }

    @Test func theFrozenHeadTakesTheTail() async throws {
        let gate = AsyncGate()
        defer { gate.open() }
        let studio = try await open(TestHAL([mic, box]), gate: gate)
        let host = try await start(studio, ago: 10, playhead: 1_000)
        let stop = Task { try await studio.stopRecording() }
        await gate.entered()
        let stopped = try #require(studio.live.stopHostNanos, "the stop recorded no host time")
        let frozen = Frames(1_000 + Int((Double(stopped &- host) * 48_000 / 1e9).rounded()))

        studio.apply(
            levels(arm: 1, from: stopped - 300_000_000, to: stopped - 100_000_000), generation: studio.generation)
        #expect(studio.liveHead() == frozen, "a span before the stop head moved the head")
        studio.apply(
            levels(arm: 2, from: stopped - 50_000_000, to: stopped + 200_000_000), generation: studio.generation)

        let tail = Frames(1_000 + Int((Double(stopped + 200_000_000 &- host) * 48_000 / 1e9).rounded()))
        #expect(studio.liveHead(atHostNanos: stopped) == tail, "the frozen head did not take the tail")
        #expect(studio.transport == .finalizing(take: 1))
        gate.open()
        try await stop.value
    }

    @Test func aRetryHasNoHead() async throws {
        let hal = TestHAL([mic, box])
        let studio = try await open(hal)
        let clips = try readOnlyClips()
        defer { chmod(clips.path, 0o755) }
        let host = try await start(studio)
        await record(hal, studio, from: host, seconds: 0.5)
        await #expect(throws: StudioError.self) { try await studio.stopRecording() }
        #expect(studio.liveHead() == nil)

        let gate = AsyncGate()
        defer { gate.open() }
        studio.environment = .test(hal, beforeFinalize: { await gate.wait() })
        let retry = Task { try? await studio.retryFinalize() }
        await gate.entered()

        #expect(studio.transport == .finalizing(take: 1))
        #expect(studio.liveHead() == nil, "a retry has a live head")
        #expect(studio.liveHead(atHostNanos: host + 1_000_000_000) == nil)
        chmod(clips.path, 0o755)
        gate.open()
        await retry.value
        #expect(studio.pendingTake == nil)
    }
}
