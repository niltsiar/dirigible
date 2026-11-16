import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Decision 0043 in a studio (run 14, criteria C5 and C8 to C14 and C22 to C24): the revert is
/// one undo entry, the list follows the writes, and the close keeps a backup.
@MainActor
struct StudioBackupTests {
    let folder: TemporaryFolder
    let url: URL
    var sessionXML: URL { url.appending(path: "session.xml") }
    var backupFolder: URL { url.appending(path: "Backups") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on channel 1 of `mic`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        try Self.named("Host").write(to: url)
    }

    static func named(_ name: String) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: name, layout: .mono)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        return session
    }

    func studio(
        _ hal: TestHAL = TestHAL([]),
        save: @escaping @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL = CaptureEnvironment.live
            .saveSession,
        beforeFinalize: @escaping @Sendable () async -> Void = {}
    ) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, saveSession: save, beforeFinalize: beforeFinalize)
        return studio
    }

    func setName(_ studio: Studio, to name: String) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: name) }
    }

    /// The bytes that a save writes for `session`.
    func bytes(of session: Session) throws -> Data {
        let package = folder.url.appending(path: "\(UUID().uuidString).dirigible")
        try session.write(to: package)
        return try Data(contentsOf: package.appending(path: "session.xml"))
    }

    /// The modification time of `session.xml` in whole seconds.
    func sessionTime() throws -> Int {
        var info = stat()
        try #require(stat(sessionXML.path, &info) == 0)
        return info.st_mtimespec.tv_sec
    }

    func setSessionTime(_ seconds: Int) throws {
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        try #require(utimes(sessionXML.path, &times) == 0)
    }

    /// Writes a backup of `session` named for `seconds` in `package` (default: `url`).
    @discardableResult
    func plant(_ session: Session, at seconds: Int, in package: URL? = nil) throws -> Backup {
        let folder = (package ?? url).appending(path: "Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = Backup.name(seconds)
        try bytes(of: session).write(to: folder.appending(path: name))
        return try #require(Backup(fileName: name))
    }

    func names(in package: URL? = nil) -> Set<String> {
        Set(
            (try? FileManager.default.contentsOfDirectory(atPath: (package ?? url).appending(path: "Backups").path))
                ?? [])
    }

    /// True when a file in `Backups/` has the bytes of `session.xml`.
    func backupsHoldTheSession() throws -> Bool {
        let current = try Data(contentsOf: sessionXML)
        return names().contains { (try? Data(contentsOf: backupFolder.appending(path: $0))) == current }
    }

    /// C8. Control: one undo gives the state before the revert, so the revert is one entry.
    @Test func aRevertIsOneUndoEntry() async throws {
        let studio = try await studio()
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        try setName(studio, to: "B")
        try setName(studio, to: "C")
        await studio.serialized {}
        let revision = studio.sessionRevision

        try await studio.revert(to: backup)

        #expect(studio.session == (try Self.named("A")), "the revert gives the backup state")
        #expect(studio.sessionRevision == revision + 1)
        await studio.serialized {}
        #expect(try Session(contentsOf: url) == Self.named("A"), "the autosave writes the reverted state")
        try studio.undo()
        #expect(studio.session.track("t1")?.name == "C", "one undo gives the state before the revert")
        try studio.redo()
        #expect(studio.session.track("t1")?.name == "A")
        await studio.serialized {}
        let before = names()

        try await studio.revert(to: backup)

        #expect(studio.sessionRevision == revision + 3, "a revert to an equal state records no entry")
        #expect(names() == before, "a revert to held bytes adds no file")
        await studio.settle()
    }

    /// C9: the revert keeps the state before it, also when the newest backup is 1 s old.
    @Test func aRevertKeepsTheStateBeforeIt() async throws {
        let studio = try await studio()
        let backup = try plant(Self.named("A"), at: try sessionTime() - 1)
        try setName(studio, to: "B")
        await studio.serialized {}
        try #require(!(try backupsHoldTheSession()))
        let current = try Data(contentsOf: sessionXML)

        try await studio.revert(to: backup)

        let kept = names().contains { (try? Data(contentsOf: backupFolder.appending(path: $0))) == current }
        #expect(kept, "the revert keeps the state before it")
        await studio.settle()
    }

    /// C5: a backup fault shows no save error.
    @Test func aBackupFaultShowsNoSaveError() async throws {
        // The open refuses a `Backups` that is not a folder, so the fault comes after the open.
        let studio = try await studio()
        try Data("not a folder".utf8).write(to: backupFolder)

        try setName(studio, to: "B")
        await studio.serialized {}

        #expect(studio.saveError == nil, "a backup fault shows no save error")
        try FileManager.default.removeItem(at: backupFolder)
        #expect(try Session(contentsOf: url).track("t1")?.name == "B")
        await studio.settle()
    }

    /// C14. Failing value: the list at open.
    @Test func theListFollowsTheSaves() async throws {
        let studio = try await studio()
        let planted = try plant(Self.named("A"), at: try sessionTime() - 1)
        #expect(studio.backups == [], "the list at open")

        try setName(studio, to: "B")
        await studio.serialized {}

        #expect(studio.backups == [planted], "the save sets the list")
        await studio.settle()
        #expect(studio.backups == Backup.all(in: url), "the close sets the list")
    }

    /// C14: after a rename of the package, a save keeps its backup in the new path.
    @Test func backupsFollowARename() async throws {
        let studio = try await studio()
        let moved = folder.url.appending(path: "Moved.dirigible")
        try #require(rename(url.path, moved.path) == 0)

        try setName(studio, to: "B")
        await studio.serialized {}

        #expect(Backup.all(in: moved).count == 1, "the backup is in the moved package")
        #expect(studio.backups == Backup.all(in: moved))
        await studio.settle()
    }

    /// C22: an edit 2 min after the last backup, then a close. A second close adds no file.
    @Test func aCloseKeepsTheStateAtClose() async throws {
        let studio = try await studio()
        try plant(Self.named("A"), at: try sessionTime() - 120)
        try setName(studio, to: "B")
        await studio.serialized {}
        try #require(!(try backupsHoldTheSession()))

        await studio.settle()

        #expect(try backupsHoldTheSession(), "the close keeps the state at close")
        let after = names()
        await studio.settle()
        #expect(names() == after, "a second close adds no file")
    }

    /// C22 regression case: a name 1 h after the mtime does not stop the close backup.
    @Test func aFutureNameDoesNotStopTheCloseBackup() async throws {
        let studio = try await studio()
        try plant(Self.named("A"), at: try sessionTime() + 3600)
        try setName(studio, to: "B")
        await studio.serialized {}

        await studio.settle()

        #expect(try backupsHoldTheSession(), "the close keeps the state at close")
    }
}

extension Backup {
    static func name(_ seconds: Int) -> String {
        // The parse gives the one name of a date, so the test spells it once here.
        var time = time_t(seconds)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(
            format: "session-%04d%02d%02dT%02d%02d%02d.000Z.xml", parts.tm_year + 1900, parts.tm_mon + 1,
            parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec)
    }
}
