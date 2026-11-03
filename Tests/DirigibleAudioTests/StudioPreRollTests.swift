import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The pre-roll take of decision 0070 in the Studio (run 2026-10-28-pre-roll, criteria P2 to P9,
/// P13, P18, P21, P22, P24, and P30). Track `t1` (armed, on `mic`) and track `t2` (not armed)
/// each have a 4 s ramp clip at 0. The Player renders offline with the term `OutputTerm.builtIn`
/// (18,583,333 ns), and the host clock of the start reads `hostNow`, so the Player picks its
/// start 100 ms after it.
@MainActor
struct StudioPreRollTests {
    let package: MixPackage
    let hal: TestHAL
    static let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    nonisolated static let hostNow: UInt64 = 9_900_000_000

    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 192_000)])
        try package.addFile("f2", channels: [ramp(frames: 192_000, channel: 1)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 192_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 192_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
        hal = TestHAL([Self.mic])
    }

    func studio(access: MicrophoneAccess? = nil, free: FreeBytes = FreeBytes()) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(hal, access: access, free: free)
        studio.environment.outputTerm = { _ in .success(.builtIn) }
        studio.environment.hostNanos = { Self.hostNow }
        return studio
    }

    func reading(_ studio: Studio) async throws -> Player.Reading {
        try #require(await studio.play.player?.reading())
    }

    /// Plays `seconds` of input on `mic` from `offset` nanoseconds after H_T, then waits for it.
    func input(from offset: Int64, seconds: Double) async {
        let input = SyntheticInput(hal, "mic")
        let start = UInt64(Int64(takeStart) + offset)
        input.play(
            records([sine(seconds: seconds, rate: 48_000)], layout: [1], rate: 48_000, hostStart: start),
            takeStartIn: package.url)
        await input.wait()
    }

    /// The mix of `range` with no clip on `t1`: the oracle of the armed track that is silent from T.
    func mixWithoutT1(_ range: Range<Frames>) throws -> [[Float]] {
        var cut = package.session
        try cut.clear(0..<192_000, on: ["t1"])
        return try package.mix(range, session: cut)
    }

    func expectMix(_ out: [[Float]], _ mix: [[Float]], _ comment: Comment) {
        #expect(out.map(\.count) == mix.map(\.count), comment)
        for (a, b) in zip(out, mix) { #expect(maxError(a, b) <= 1e-6, comment) }
    }

    func takeClip(_ studio: Studio) -> Clip? { studio.session.track("t1")?.clips.first { $0.id == "take1-1-1" } }

    // MARK: P2

    /// T = 2 s and 1 s of pre-roll: the Player plays from S = 1 s, both tracks to T, then `t2` only.
    @Test func takeMixCutsTheArmedTracksAtT() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)

        let out = await studio.renderOffline(frames: 96_000)

        expectMix(out.map { Array($0[..<48_000]) }, try package.mix(48_000..<96_000), "from S to T")
        expectMix(out.map { Array($0[48_000...]) }, try mixWithoutT1(96_000..<144_000), "from T")
        try await studio.stopRecording()
    }

    /// The end of a fader drag in the save of `<recording>` sends the session before the take
    /// begins: the Player keeps the take mix.
    @Test func sessionSentBeforeTheTakeBeginsKeepsTheTakeMix() async throws {
        let studio = try await studio()
        let gain = try #require(Gain(dB: -6))
        studio.environment.beforeTakeSave = { @MainActor in
            studio.play.preview = (track: "t2", gain: gain)
            studio.endPreview()
            await Task.yield()
        }
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)

        let out = await studio.renderOffline(frames: 96_000)

        expectMix(out.map { Array($0[48_000...]) }, try mixWithoutT1(96_000..<144_000), "from T")
        try await studio.stopRecording()
    }

    @Test(arguments: [192_000, 240_000] as [Frames])
    func takeMixAtTheSessionEnd(playhead: Frames) {
        #expect(takeMix(package.session, armed: ["t1"], from: playhead) == package.session)
    }

    /// A speed of 1.5 is set: the pre-roll plays the source frames at 1x.
    @Test func preRollPlaysAtOne() async throws {
        let studio = try await studio()
        await studio.changeSpeed(to: .x150)
        try #require(studio.speed == .x150)
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)

        expectMix(await studio.renderOffline(frames: 48_000), try package.mix(48_000..<96_000), "1x")
        try await studio.stopRecording()
    }

    // MARK: P3

    /// The real start is 10 s, T - S is 3 s: H_T = 10 s + 18,583,333 ns + 3 s in `session.xml`
    /// before the first attach. A dropped term gives 13,000,000,000; a doubled one 13,037,166,666.
    @Test func recordingHoldsTheAnchor() async throws {
        let seen = LockedBox<Recording>()
        let url = package.url
        hal.failAttach { _, _ in
            if seen.value == nil { seen.value = try? Session(contentsOf: url).recording }
            return nil
        }
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 144_000, preRoll: 3)

        let recording = try #require(seen.value)
        #expect(recording.takeStartHostTimeNanos == 13_018_583_333)
        #expect(recording.playheadFrame == 144_000 && recording.isPreRoll)
        try await studio.stopRecording()
    }

    // MARK: P5 and P6

    /// Input from H_T - 0.9 s to H_T - 0.4 s, then Stop: no take clip, and the playhead is T.
    @Test func stopBeforeTGivesNoClip() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        await input(from: -900_000_000, seconds: 0.5)
        try await studio.stopRecording()

        #expect(studio.session.track("t1")?.clips.map(\.id) == ["c1"])
        #expect(studio.playhead == 96_000)
        #expect(try await !reading(studio).running)
    }

    @Test func stopBeforeTLeavesNoUnplacedSegment() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        await input(from: -900_000_000, seconds: 0.5)
        try await studio.stopRecording()

        #expect(studio.session.files["take1-1-1"]?.capture == "take1-1-1")
        #expect(studio.unplacedSegments.isEmpty && studio.canRipple)
        #expect(studio.session.recording == nil)
    }

    /// The writers end at the host time of the stop command, before the Player stop.
    @Test func stopEndsTheWritersBeforeThePlayerStop() async throws {
        let studio = try await studio()
        let ends = LockedBox<[UInt64]>()
        studio.environment.beforePlayerStop = { @MainActor in
            ends.value = studio.writers.values.map(\.lifecycle.endHostNanos)
        }
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        let called = hostNanosNow()
        try await studio.stopRecording()

        let end = try #require(ends.value?.first)
        #expect(ends.value?.count == 1 && end >= called && end < .max)
    }

    /// Input from H_T - 0.5 s for 1 s: the clip starts at T with an offset of 0.5 s, and the stop
    /// ends the pre-roll play.
    @Test func stopAfterTStopsThePlayer() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        #expect(try await reading(studio).running, "the pre-roll plays")
        await input(from: -500_000_000, seconds: 1)
        try await studio.stopRecording()

        #expect(try await !reading(studio).running)
        let clip = try #require(takeClip(studio))
        #expect(clip.start == 96_000 && clip.offset == 24_000 && clip.length == 24_000, "\(clip)")
    }

    @Test func diskLowStopsThePlayer() async throws {
        let free = FreeBytes()
        let studio = try await studio(free: free)
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        free.value = 0
        // A hang guard: the disk check runs each 50 ms.
        await until(limit: .seconds(10), "the disk-low stop") { studio.lastTake?.end == .diskLow }
        await until(limit: .seconds(10), "the finalize") { studio.transport == .idle }

        #expect(try await !reading(studio).running)
    }

    @Test func settleDuringPreRollStopsThePlayer() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        await studio.settle()

        #expect(studio.transport == .idle && studio.lastTake?.take == 1)
        #expect(try await !reading(studio).running)
        #expect(studio.playhead == 96_000)
    }

    // MARK: P7

    @Test func preRollDrawsFromT() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        await input(from: -500_000_000, seconds: 1)
        await until(limit: .seconds(10), "the take drew no bins") {
            studio.livePeaks(of: "t1")?.covered.isEmpty == false
        }

        let peaks = try #require(studio.livePeaks(of: "t1"))
        #expect(peaks.origin == 96_000)
        #expect(peaks.covered.allSatisfy { $0.lowerBound >= .zero }, "\(peaks.covered)")
        try await studio.stopRecording()
    }

    // MARK: P8

    /// Control of the take play: Command-R after a play plays nothing during its take.
    @Test func plainRecordPlaysNothing() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await studio.perform(.playStop)
        let before = try await reading(studio)

        try await studio.startRecording(armed: ["t1"], playhead: 96_000)

        let during = try await reading(studio)
        #expect(!during.running && during.played == before.played && during.realStart == nil)
        #expect(studio.session.recording?.isPreRoll == false)
        try await studio.stopRecording()
    }

    // MARK: P9

    @Test func transportIsLockedDuringPreRoll() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        let feed = studio.play.feed
        let commands: [TransportCommand] = [
            .stopAndReturn, .pause, .forward, .reverse, .slowForward, .slowReverse, .seek(.start), .seek(.end),
        ]
        for command in commands {
            await studio.perform(command)
            #expect(studio.playback == .stopped && studio.play.feed == feed, "\(command)")
            #expect(studio.transport == .recording(take: 1), "\(command)")
        }
        await #expect(throws: StudioError.busy) { try await studio.play(from: 0, to: nil) }

        let reading = try await reading(studio)
        #expect(reading.running && reading.played == feed, "the pre-roll plays on")
        try await studio.stopRecording()
    }

    // MARK: P13

    /// A crash during a pre-roll take: the open places the segment that starts 1 s before H_T at T.
    @Test func recoveryPlacesAtT() async throws {
        let crashed = try TakePackage(tracks: [("t1", .mono)])
        var session = try crashed.read()
        var recording = try #require(session.recording)
        recording.isPreRoll = true
        try session.setRecording(recording)
        try session.write(to: crashed.url)
        try crashed.segment(
            arm: 1, header: TakePackage.header(firstHost: takeStart - 1_000_000_000),
            samples: sine(seconds: 2, rate: 48_000))

        let studio = try await Studio.open(crashed.url)

        #expect(studio.session.recording == nil)
        #expect(
            studio.session.track("t1")?.clips.map { $0 } == [
                Clip(id: "take1-1-1", file: "take1-1-1", start: 96_000, offset: 48_048, length: 47_952)
            ])
    }

    // MARK: P18

    /// The host clock reads `hostNow` (R) and the term is 18,583,333 ns: H_T - R is the lead of
    /// 0.5 s plus the term. A lead of 0.4 s gives 418,583,333.
    func leadOfTake(at playhead: Frames) async throws -> UInt64 {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: playhead, preRoll: 3)
        let anchor = try #require(studio.session.recording?.takeStartHostTimeNanos)
        try await studio.stopRecording()
        return anchor - Self.hostNow
    }

    /// T = 0.2 s and 3 s of pre-roll: S = 0, so `play(at:)` waits 0.3 s.
    @Test func shortPreRollKeepsTheLead() async throws {
        #expect(try await leadOfTake(at: 9_600) == 518_583_333)
    }

    @Test func preRollAtZeroKeepsTheLead() async throws {
        #expect(try await leadOfTake(at: 0) == 518_583_333)
    }

    // MARK: P21

    @Test func takeMarkerInPreRollIsAtTheHeardFrame() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        let anchor = try #require(studio.session.recording?.takeStartHostTimeNanos)

        let marker = try studio.addMarkerAtRecordHead(.marker, name: "m", atHostNanos: anchor - 1_000_000_000)

        #expect(marker.position == 48_000)
        try await studio.stopRecording()
    }

    /// T = 0.2 s: 1 s before H_T is in the lead before S, so the marker goes at 0.
    @Test func takeMarkerInTheLeadClampsAtZero() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 9_600, preRoll: 3)
        let anchor = try #require(studio.session.recording?.takeStartHostTimeNanos)

        let marker = try studio.addMarkerAtRecordHead(.chapter, name: "c", atHostNanos: anchor - 1_000_000_000)

        #expect(marker.position == .zero)
        try await studio.stopRecording()
    }

    // MARK: P30

    /// A take marker after T sends the take mix of the edited session, so `t1` stays silent from
    /// T. The negative control is `takeMixCutsTheArmedTracksAtT`, the same render with no marker.
    @Test func takeMarkerKeepsTheTakeMix() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        let anchor = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let player = try #require(studio.play.player)

        _ = try studio.addMarkerAtRecordHead(.marker, name: "m", atHostNanos: anchor + 100_000_000)
        // The edit sends its session in a task: wait until the Player has it (a hang guard).
        var waits = 0
        while await player.session.markers.isEmpty, waits < 1000 {
            try await Task.sleep(for: .milliseconds(10))
            waits += 1
        }
        try #require(await !player.session.markers.isEmpty)

        let out = await studio.renderOffline(frames: 96_000)
        expectMix(out.map { Array($0[48_000...]) }, try mixWithoutT1(96_000..<144_000), "from T")
        try await studio.stopRecording()
    }

    // MARK: P22

    /// An output change in the pre-roll stops the sound only: the take goes on, with no message.
    @Test func outputChangeKeepsTheTake() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        let player = try #require(studio.play.player)
        await player.outputChanged()
        await input(from: -500_000_000, seconds: 1)
        try await studio.stopRecording()

        #expect(studio.playbackStop == nil && studio.takeError == nil)
        #expect(takeClip(studio)?.start == 96_000)
    }
}
