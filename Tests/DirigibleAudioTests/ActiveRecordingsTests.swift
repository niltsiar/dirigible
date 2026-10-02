import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The active-recordings hint of decision 0004 (criterion 7). Each test has its own list file in a
/// temporary folder, and the list starts with an entry of another package, which must stay.
@MainActor
struct ActiveRecordingsTests {
    let folder: TemporaryFolder
    let url: URL
    let list: ActiveRecordings
    let other = "/Volumes/Other/Other.dirigible"
    var entry: String { packageIdentity(url).path }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on channel 1 of `mic`. The list file is in a folder that exists.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
        list = ActiveRecordings(file: folder.url.appending(path: "active-recordings.plist"))
        try seed([other])
    }

    /// Writes `paths` as the list file, the plist array of decision 0004.
    func seed(_ paths: [String]) throws {
        try PropertyListEncoder().encode(paths).write(to: list.file)
    }

    /// The listed paths, read off the main actor.
    func listed(_ list: ActiveRecordings? = nil) async -> [String] {
        let list = list ?? self.list
        return await Task.detached { list.packages().map(\.path) }.value
    }

    func studio(_ list: ActiveRecordings? = nil) async throws -> Studio {
        let studio = try await Studio.open(url, recordings: list ?? self.list)
        studio.environment = .test(TestHAL([mic]))
        return studio
    }

    @Test func aStartAddsThePackageAndAGoodStopRemovesIt() async throws {
        let studio = try await studio()

        try await studio.startRecording(armed: ["t1"], playhead: 0)
        #expect(await listed() == [other, entry])

        try await studio.stopRecording()
        #expect(await listed() == [other])
    }

    @Test func aStopWhoseFinalizeFailsKeepsTheEntry() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        try FileManager.default.removeItem(at: url.appending(path: "Capture"))

        await #expect(throws: StudioError.finalize(.readFailed(file: "Capture", errno: ENOENT))) {
            try await studio.stopRecording()
        }

        #expect(await listed() == [other, entry])
    }

    @Test func anOpenWithNoRecordingRemovesAStaleEntry() async throws {
        try seed([other, entry])

        _ = try await studio()

        #expect(await listed() == [other])
    }

    /// A recording with no `Capture/` folder: the recovery throws, and the take stays pending.
    @Test func anOpenOfAPendingTakeKeepsTheEntry() async throws {
        var session = try Session(contentsOf: url)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try session.write(to: url)
        try seed([other, entry])

        let studio = try await studio()

        #expect(studio.pendingTake?.take == 1)
        #expect(await listed() == [other, entry])
    }

    @Test func aStartMakesTheListFolder() async throws {
        let list = ActiveRecordings(file: folder.url.appending(path: "Missing/Dirigible/active-recordings.plist"))
        let studio = try await studio(list)

        try await studio.startRecording(armed: ["t1"], playhead: 0)

        #expect(await listed(list) == [entry])
        try await studio.stopRecording()
    }

    /// The stop save goes to the moved package and removes the entry of the old path too.
    @Test func aRenameDuringATakeLeavesNoEntry() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let moved = folder.url.appending(path: "Moved.dirigible")
        try #require(rename(url.path, moved.path) == 0)

        try await studio.stopRecording()

        #expect(studio.url == packageIdentity(moved))
        #expect(await listed() == [other])
    }

    /// Control: the default is no list, so the CLI and the tests never write the real file.
    @Test func aStudioWithNoListHasNoFile() async throws {
        let studio = try await Studio.open(url)
        #expect(studio.recordings == nil)
    }

    @Test func packagesOffTheMainActor() async throws {
        #expect(await listed() == [other])
        #expect(await listed(ActiveRecordings(file: folder.url.appending(path: "none.plist"))) == [])
    }

    /// Control: a read on the main actor stops the process, so the app cannot wait on the list lock
    /// there.
    @Test func packagesOnTheMainActorStopsTheProcess() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = ActiveRecordings(file: URL(filePath: "/tmp/dirigible-none.plist")).packages()
            }
        }
    }
}
