import DirigibleCore
import Foundation
import Testing
import os

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

    // The file lock across processes (decision 0004, amended).

    var lockPath: String { folder.url.appending(path: "active-recordings.lock").path }

    /// Locks the lock file of the list, as another process does. The caller closes the descriptor.
    func holdLock() throws -> Int32 {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK, 0o644)
        try #require(descriptor >= 0, "the test holds the lock")
        return descriptor
    }

    /// The list file as it is on disk. `packages()` waits for the lock of the process, which a
    /// waiting `set` holds.
    func onDisk() throws -> [String] {
        try PropertyListDecoder().decode([String].self, from: Data(contentsOf: list.file))
    }

    /// Runs `set` on a dispatch thread, so a waiting `set` holds no thread of the pool. The result
    /// is the time that `set` took, once it ended.
    func startSet() -> OSAllocatedUnfairLock<Duration?> {
        let took = OSAllocatedUnfairLock<Duration?>(initialState: nil)
        let (list, package) = (list, packageIdentity(url))
        DispatchQueue.global().async {
            let start = ContinuousClock.now
            list.set(package, active: true)
            took.withLock { $0 = ContinuousClock.now - start }
        }
        return took
    }

    /// Runs `set` on a dispatch thread and returns when it ends.
    func setOffMain(active: Bool) async {
        let (list, package) = (list, packageIdentity(url))
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                list.set(package, active: active)
                done.resume()
            }
        }
    }

    /// What `holdDuringSet` saw while it held the lock of another process.
    struct Hold: Sendable {
        let took: Bool
        let endedWhileHeld: Bool
        let listWhileHeld: [String]?
        let ended: OSAllocatedUnfairLock<Bool>
    }

    /// On a dispatch thread: takes the lock as another process does, runs `set` on a second thread,
    /// and after 300 ms reads the list, writes `written` as the list when given, and releases. The
    /// hold runs off the main actor, so a busy main actor in a parallel suite cannot stretch it past
    /// the bound of 1 s of `set`.
    func holdDuringSet(writing written: [String]? = nil) async -> Hold {
        let (list, package, path) = (list, packageIdentity(url), lockPath)
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let held = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK, 0o644)
                let ended = OSAllocatedUnfairLock(initialState: false)
                DispatchQueue.global().async {
                    list.set(package, active: true)
                    ended.withLock { $0 = true }
                }
                usleep(300_000)
                let early = ended.withLock { $0 }
                let listed = try? PropertyListDecoder().decode([String].self, from: Data(contentsOf: list.file))
                if let written { try? PropertyListEncoder().encode(written).write(to: list.file, options: .atomic) }
                if held >= 0 { close(held) }
                done.resume(
                    returning: Hold(took: held >= 0, endedWhileHeld: early, listWhileHeld: listed, ended: ended))
            }
        }
    }

    /// Polls `condition` each 5 ms. False after the hang guard of 10 s.
    func within10Seconds(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func setWaitsForTheLockOfAnotherProcess() async throws {
        let hold = await holdDuringSet()
        try #require(hold.took, "the test holds the lock")
        #expect(!hold.endedWhileHeld, "the set waits while another process holds the lock")
        #expect(hold.listWhileHeld == [other], "the list is unchanged while the lock is held")

        #expect(await within10Seconds { hold.ended.withLock { $0 } }, "the set ended after the release")
        #expect(try onDisk() == [other, entry])
    }

    @Test func setKeepsTheEntryOfAnotherProcess() async throws {
        let written = "/Volumes/Third/Third.dirigible"
        let hold = await holdDuringSet(writing: [other, written])
        try #require(hold.took, "the test holds the lock")

        #expect(await within10Seconds { hold.ended.withLock { $0 } }, "the set ended")
        #expect(try onDisk() == [other, written, entry])
    }

    @Test func theLockFileOutlivesTheAtomicWrite() async throws {
        var info = stat()
        await setOffMain(active: true)
        try #require(stat(lockPath, &info) == 0, "a set makes the lock file")
        let first = info.st_ino
        await setOffMain(active: false)
        try #require(stat(lockPath, &info) == 0)
        #expect(info.st_ino == first, "the lock file is the same file after the second write")
    }

    @Test func aSetWithNoChangeReleasesTheLock() async throws {
        func probe() -> Bool {
            let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o644)
            defer { if descriptor >= 0 { close(descriptor) } }
            return descriptor >= 0
        }
        await setOffMain(active: false)
        try #require(FileManager.default.fileExists(atPath: lockPath), "the set took the lock file")
        #expect(probe(), "a set with no change leaves the lock free")
        await setOffMain(active: true)
        #expect(probe(), "a set with a change leaves the lock free")
    }

    @Test func setStopsWaitingAfterOneSecond() async throws {
        let held = try holdLock()
        defer { close(held) }
        let took = startSet()

        #expect(await within10Seconds { took.withLock { $0 } != nil }, "the set ended with the lock still held")
        let waited = try #require(took.withLock { $0 })
        #expect(waited >= .milliseconds(900), "the set waited \(waited)")
        #expect(try onDisk() == [other, entry], "the set wrote with no file lock")
    }

    /// A verify copy has its own list, and the real ID keeps the path of earlier versions.
    @Test func theFileFollowsTheBundleID() {
        let support = URL(filePath: "/Users/u/Library/Application Support")
        #expect(
            ActiveRecordings.file(bundleID: "com.delineas.dirigible.verify-0123abcd", support: support).path
                == "/Users/u/Library/Application Support/com.delineas.dirigible.verify-0123abcd/active-recordings.plist"
        )
        #expect(
            ActiveRecordings.file(bundleID: "com.delineas.dirigible", support: support).path
                == "/Users/u/Library/Application Support/com.delineas.dirigible/active-recordings.plist")
    }
}
