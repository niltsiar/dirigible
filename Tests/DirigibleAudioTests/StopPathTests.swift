import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The stop path from input records (criteria 11, 12, and 19): `startTake`, records through
/// the ring of each device writer, and `stopRecording`.
@MainActor
struct StopPathTests {
    let folder: TemporaryFolder
    let url: URL
    var sessionXML: URL { url.appending(path: "session.xml") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 48)!
    let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 44_100, availableRates: [44_100...44_100], channelsPerBuffer: [2],
        latency: 0)!

    /// Track `t1` (mono, `mic` channel 1) and track `t2` (stereo, `box` channels 1 and 2).
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(Route(deviceUID: "box", channels: .stereo(1, 2)), track: "t2")
        try session.write(to: url)
    }

    /// Starts take 1 on `t1` and `t2` and sends 3.0 s of records from each device through its
    /// ring, in burst mode.
    func recordThreeSeconds(_ studio: Studio) async throws -> [String: DeviceWriter] {
        let hal = TestHAL([mic, box])
        studio.environment = .test(hal)
        let writers = try await studio.startTake(
            armed: ["t1", "t2"], devices: [mic, box], playhead: 0, hostTimeNanos: takeStart)
        let micInput = SyntheticInput(hal, "mic")
        let boxInput = SyntheticInput(hal, "box")
        micInput.play(
            records([sine(seconds: 3, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart + 1_000_000))
        boxInput.play(records([sine(seconds: 3, rate: 44_100, channels: 2)], layout: [2], rate: 44_100))
        await micInput.wait()
        await boxInput.wait()
        return writers
    }

    @Test func twoDevicesRecordAndStopToTwoClips() async throws {
        let studio = try await Studio.open(url)

        _ = try await recordThreeSeconds(studio)
        #expect(studio.transport == .recording(take: 1))
        #expect(try Session(contentsOf: url).recording?.armedTracks == ["t1", "t2"])
        try await studio.stopRecording()

        #expect(studio.transport == .idle)
        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(studio.session.track("t1")?.clips.first?.length == 144_000)
        let boxLength = try #require(studio.session.track("t2")?.clips.first?.length.count)
        #expect(abs(boxLength - 144_000) <= 1)
        #expect(studio.session.captures["take1-2-1"]?.resampledFromRate == 44_100)
        #expect(try Session(contentsOf: url) == studio.session)
        let sidecar = try #require(Sidecar.decode(Data(contentsOf: url.appending(path: "Capture/take1-1-1.sidecar"))))
        #expect(sidecar.checkpoints.map(\.fileFrame) == [0, 48_128, 96_256, 143_872])

        #expect(studio.unplacedSegments == [])

        // The unplaced list follows the session (decision 0012): the undo takes the files away.
        try studio.undo()
        #expect(studio.session.tracks.map(\.clips.count) == [0, 0])
        #expect(studio.session.recording == nil)
        #expect(studio.unplacedSegments.map(\.stem) == ["take1-1-1", "take1-2-1"])
        try studio.redo()
        #expect(studio.unplacedSegments == [])
    }

    @Test func aTrackGetsOnlyItsChannel() async throws {
        let quad = try #require(
            InputDevice(
                uid: "quad", name: "Quad", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [2, 2], latency: 0))
        let studio = try await Studio.open(url)
        try studio.edit { session throws(SessionError) in
            try session.setRoute(Route(deviceUID: "quad", channels: .mono(3)), track: "t1")
        }
        let tone = sine(seconds: 1, rate: 48_000)
        // Channel 3 is the first channel of the second buffer.
        let second = tone.flatMap { sample -> [Float] in [sample, 0] }
        let first = [Float](repeating: 0, count: second.count)

        let hal = TestHAL([quad])
        studio.environment = .test(hal)
        let writers = try await studio.startTake(armed: ["t1"], devices: [quad], playhead: 0, hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "quad")
        input.play(records([first, second], layout: [2, 2], rate: 48_000))
        await input.wait()
        await writers["quad"]?.finish()

        #expect(try readAudio(url.appending(path: "Capture/take1-1-1.caf")).samples == tone)
        try await studio.stopRecording()
    }

    /// A clip ID from package content can hold the last take number of decision 0012. The next
    /// take has no stem, so the start throws and changes nothing.
    @Test func aTakeNumberPastTheStemRangeThrowsAndChangesNothing() async throws {
        var session = try Session(contentsOf: url)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 100))
        try session.place(Clip(id: "take999999999-1-1", file: "f", start: 0, offset: 0, length: 100), on: "t1")
        try session.write(to: url)
        let studio = try await Studio.open(url)
        let before = try Data(contentsOf: sessionXML)

        await #expect(throws: StudioError.session(.takeOutOfRange(1_000_000_000))) {
            _ = try await studio.startTake(
                armed: ["t1"], devices: [mic], playhead: 0, hostTimeNanos: takeStart)
        }
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(studio.transport == .idle)
        #expect(studio.session.recording == nil)
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "Capture").path))
    }

    @Test func aStartWithABadRouteThrowsAndChangesNothing() async throws {
        let studio = try await Studio.open(url)
        var before = try Data(contentsOf: sessionXML)
        let stereoMic = try #require(
            InputDevice(
                uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [], channelsPerBuffer: [2],
                latency: 0))
        func start(_ armed: [TrackID], _ devices: [InputDevice]) async throws(StudioError) {
            _ = try await studio.startTake(
                armed: armed, devices: devices, playhead: 0, hostTimeNanos: takeStart)
        }

        await #expect(throws: StudioError.deviceMissing("t2")) { try await start(["t1", "t2"], [mic]) }
        #expect(try Data(contentsOf: sessionXML) == before)
        try studio.edit { session throws(SessionError) in
            try session.setRoute(Route(deviceUID: "mic", channels: .mono(3)), track: "t1")
            try session.setLayout(.mono, route: Route(deviceUID: "mic", channels: .mono(1)), track: "t2")
            try session.addTrack("t3", name: "Music", layout: .mono)
        }
        // Each edit saves (decision 0014), so the bytes to compare are the bytes after its save.
        await studio.settle()
        before = try Data(contentsOf: sessionXML)
        await #expect(throws: StudioError.channelOutOfRange("t1")) { try await start(["t1"], [stereoMic]) }
        #expect(try Data(contentsOf: sessionXML) == before)
        try studio.edit { session throws(SessionError) in
            try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        }
        await studio.settle()
        before = try Data(contentsOf: sessionXML)
        await #expect(throws: StudioError.channelInUse("t1", "t2")) { try await start(["t1", "t2"], [stereoMic]) }
        await #expect(throws: StudioError.noRoute("t3")) { try await start(["t3"], [stereoMic]) }
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(studio.transport == .idle)
    }

    @Test func aRecordingStudioIsBusy() async throws {
        let studio = try await Studio.open(url)
        _ = try await recordThreeSeconds(studio)

        #expect(throws: StudioError.busy) {
            try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "X") }
        }
        #expect(throws: StudioError.busy) { try studio.undo() }
        await #expect(throws: StudioError.busy) {
            _ = try await studio.startTake(
                armed: ["t1"], devices: [mic], playhead: 0, hostTimeNanos: takeStart)
        }
        await #expect(throws: StudioError.busy) { try await studio.retryFinalize() }

        let first = Task { try await studio.stopRecording() }
        // Bounded, so a regression fails the test instead of a hang.
        for _ in 0..<10_000 where studio.transport != .finalizing(take: 1) { await Task.yield() }
        try #require(studio.transport == .finalizing(take: 1))
        await #expect(throws: StudioError.busy) { try await studio.stopRecording() }
        try await first.value
        #expect(studio.transport == .idle)
    }

    @Test func aStopWithReadOnlyClipsKeepsTheTakePending() async throws {
        let studio = try await Studio.open(url)
        let clips = url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        _ = try await recordThreeSeconds(studio)

        await #expect {
            try await studio.stopRecording()
        } throws: { error in
            guard case .finalize(.writeFailed) = error as? StudioError else { return false }
            return true
        }
        #expect(studio.transport == .idle)
        #expect(studio.pendingTake?.take == 1)
        #expect(try Session(contentsOf: url).recording?.take == 1)
        // A new take waits for the pending take.
        await #expect(throws: StudioError.busy) {
            _ = try await studio.startTake(
                armed: ["t1"], devices: [mic], playhead: 0, hostTimeNanos: takeStart)
        }
    }

    @Test func aStopLeavesASegmentWithABadSidecarUnplaced() async throws {
        let studio = try await Studio.open(url)
        let writers = try await recordThreeSeconds(studio)
        await writers["mic"]?.finish()
        let handle = try FileHandle(forWritingTo: url.appending(path: "Capture/take1-1-1.sidecar"))
        try handle.write(contentsOf: Data("XXXXXXXX".utf8))
        try handle.close()

        try await studio.stopRecording()

        #expect(studio.transport == .idle)
        #expect(studio.takeError == nil)
        #expect(studio.session.tracks.map(\.clips.count) == [0, 1])
        #expect(try Session(contentsOf: url).recording == nil)
        #expect(studio.unplacedSegments.map(\.stem) == ["take1-1-1"])
    }

    @Test func aStopWhoseSaveFailsKeepsTheTakePending() async throws {
        let studio = try await Studio.open(url)
        _ = try await recordThreeSeconds(studio)
        // A non-empty folder in place of session.xml fails only the rename of the save.
        try FileManager.default.removeItem(at: sessionXML)
        try FileManager.default.createDirectory(at: sessionXML, withIntermediateDirectories: false)
        FileManager.default.createFile(atPath: sessionXML.appending(path: "x").path, contents: nil)

        await #expect {
            try await studio.stopRecording()
        } throws: { error in
            guard case .file = error as? StudioError else { return false }
            return true
        }
        #expect(studio.pendingTake?.take == 1)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "Clips/take1-1-1.wav").path))
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "Clips/take1-2-1.wav").path))
        #expect(studio.session.files.isEmpty)
        #expect(studio.session.tracks.map(\.clips.count) == [0, 0])
    }
}
