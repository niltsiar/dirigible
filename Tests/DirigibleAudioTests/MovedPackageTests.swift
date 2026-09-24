import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A package that moves while a studio has it open (decision 0014, probes P11 and P14): every
/// write goes to the package that the lock holds, and no write makes a folder at an old path.
@MainActor
struct MovedPackageTests {
    let folder: TemporaryFolder
    let url: URL
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on channel 1 of `mic`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL = TestHAL([])) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        return studio
    }

    /// Renames the package with `rename(2)`, the call of a Finder rename, and returns the new URL.
    func move(_ from: URL, to name: String) throws -> URL {
        let to = folder.url.appending(path: name)
        try #require(rename(from.path, to.path) == 0)
        return to
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Records after now, so they are after the take start that the live start saves.
    func clock() -> DeviceClock {
        DeviceClock(hostNanos: Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) + 100_000_000)
    }

    @Test func anEditAfterARenameLandsInTheMovedPackage() async throws {
        let studio = try await studio()
        let moved = try move(url, to: "Moved.dirigible")

        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Guest") }
        await studio.settle()

        #expect(!exists(url))
        #expect(try Session(contentsOf: moved).track("t1")?.name == "Guest")
        #expect(studio.url == packageIdentity(moved))
        #expect(studio.saveError == nil)
    }

    /// Control: a write with no move keeps the URL. The package is in the temporary folder, a
    /// `/var` path, and `F_GETPATH` gives the `/private/var` spelling.
    @Test func anEditWithNoMoveKeepsTheURL() async throws {
        let studio = try await studio()
        let before = studio.url

        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Guest") }
        await studio.settle()

        #expect(studio.url == before)
        #expect(try Session(contentsOf: url).track("t1")?.name == "Guest")
    }

    /// Control: a package that left the volume refuses the write, and no folder comes back.
    @Test func aDeletedPackageRefusesTheWrite() async throws {
        let studio = try await studio()
        try FileManager.default.removeItem(at: url)

        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Guest") }
        await studio.settle()

        #expect(studio.saveError == .file(.packageMoved))
        #expect(!exists(url))
    }

    @Test func aTakeFinalizesInTheMovedPackage() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let moved = try move(url, to: "Moved.dirigible")
        let input = SyntheticInput(hal, "mic")
        var clock = clock()
        input.play(clock.run(seconds: 0.5))
        await input.wait()

        try await studio.stopRecording()

        #expect(!exists(url))
        let saved = try Session(contentsOf: moved)
        #expect(saved.recording == nil)
        #expect(saved.track("t1")?.clips.map(\.id) == ["take1-1-1"])
        #expect(exists(moved.appending(path: "Clips/take1-1-1.wav")))
        #expect(studio.url == packageIdentity(moved))
    }

    /// A take whose `Capture/` is gone stays pending: the finalize does not place zero clips.
    @Test func aFinalizeWithoutCaptureStaysPending() async throws {
        let studio = try await studio(TestHAL([mic]))
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        try FileManager.default.removeItem(at: url.appending(path: "Capture"))

        await #expect(throws: StudioError.finalize(.readFailed(file: "Capture", errno: ENOENT))) {
            try await studio.stopRecording()
        }

        #expect(studio.takeError == .finalize(.readFailed(file: "Capture", errno: ENOENT)))
        #expect(studio.pendingTake?.take == 1)
        #expect(try Session(contentsOf: url).recording?.take == 1)
    }

    /// Round 2, item 1: two renames, one before and one during the take, and a device loss and
    /// return after the second. The free space is the live `fstatfs` of the lock descriptor, so
    /// the take does not end as disk low; the second segment opens in the moved `Capture/`.
    @Test func aRenameDuringATakeKeepsRecording() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        studio.environment.freeBytes = CaptureEnvironment.live.freeBytes
        let first = try move(url, to: "First.dirigible")
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let second = try move(first, to: "Second.dirigible")
        let input = SyntheticInput(hal, "mic")
        var clock = clock()

        input.play(clock.run(seconds: 0.5))
        await input.wait()
        hal.set("mic", id: nil)
        studio.writer("mic")?.post(.alive(false), from: hal.current("mic"))
        await until(limit: .seconds(5), "t1 is not lost") { studio.liveTracks["t1"]?.state == .deviceLost }
        hal.set("mic", id: 1)
        studio.writer("mic")?.post(.devicesChanged, from: nil)
        clock.sampleTime = 0
        input.play(clock.run(seconds: 0.5))
        await input.wait()
        await until(limit: .seconds(5), "t1 is not recording") { studio.liveTracks["t1"]?.state == .recording }
        try await studio.stopRecording()

        #expect(studio.lastTake?.end == .requested)
        #expect(!exists(url))
        #expect(!exists(first))
        #expect(exists(second.appending(path: "Capture/take1-1-2.caf")))
        let saved = try Session(contentsOf: second)
        #expect(saved.recording == nil)
        #expect(saved.track("t1")?.clips.map(\.id) == ["take1-1-1", "take1-1-2"])
    }
}
