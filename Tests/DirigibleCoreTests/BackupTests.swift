import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0043: a lock-holder save keeps backups of `session.xml` in `Backups/` (criteria C1 to
/// C6, C14, and C15 of run 14). Each test sets the file times with `utimes`, so no wall clock
/// takes part.
struct BackupTests {
    /// A time far from the clock of the test machine, as on a server with a skewed clock.
    static let time = 2_000_000_000
    let package: URL
    var sessionXML: URL { package.appending(path: "session.xml") }
    var folder: URL { package.appending(path: "Backups") }

    init() throws {
        package = try Self.newPackage()
    }

    static func newPackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "BackupTests-\(UUID().uuidString)/Episode.dirigible")
        try Session(sampleRate: 48_000).write(to: package)
        try setTime(of: package.appending(path: "session.xml"), to: time)
        return package
    }

    static func setTime(of url: URL, to seconds: Int) throws {
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        try #require(utimes(url.path, &times) == 0)
    }

    /// A session with `count` tracks, so each count gives other bytes.
    static func state(_ count: Int) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for index in 0..<count { try session.addTrack(TrackID("t\(index)"), name: "T\(index)", layout: .mono) }
        return session
    }

    static func name(_ seconds: Int) -> String {
        Backup(saved: Date(timeIntervalSince1970: TimeInterval(seconds))).fileName
    }

    /// Writes a backup file named for `seconds` with `bytes` in `package`.
    @discardableResult
    static func plant(_ seconds: Int, _ bytes: String, in package: URL) throws -> String {
        let folder = package.appending(path: "Backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: folder.appending(path: name(seconds)))
        return name(seconds)
    }

    static func save(_ session: Session, in package: URL, _ policy: BackupPolicy = .standard) throws {
        let lock = try PackageLock(package)
        try withExtendedLifetime(lock) { _ = try session.write(under: lock, backups: policy) }
    }

    static func names(in package: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: package.appending(path: "Backups").path)) ?? [])
    }

    /// C1.
    @Test func aNameRoundTripsAndOtherNamesAreRefused() {
        let date = Date(timeIntervalSince1970: 1_791_533_730.25)
        #expect(Backup(saved: date).fileName == "session-20261009T081530.250Z.xml")
        #expect(Backup(fileName: "session-20261009T081530.250Z.xml")?.saved == date, "the name gives the date")
        let refused = [
            "notes.xml", "session-20261009T081530Z.xml", "session-20261309T081530.250Z.xml",
            "session-20261009T081530.250Z.XML",
        ]
        for name in refused { #expect(Backup(fileName: name) == nil, "\(name) is refused") }
        let subMillisecond = Date(timeIntervalSince1970: 1_791_533_730.2509)
        #expect(Backup(saved: subMillisecond).fileName == "session-20261009T081530.250Z.xml")
    }

    /// C2. Failing value: the backup has the new bytes.
    @Test func theFirstSaveKeepsTheOldFile() throws {
        let old = try Data(contentsOf: sessionXML)

        try Self.save(Self.state(1), in: package)

        #expect(Self.names(in: package) == [Self.name(Self.time)], "one backup named for the old mtime")
        let kept = try? Data(contentsOf: folder.appending(path: Self.name(Self.time)))
        #expect(kept == old, "the backup holds the old bytes")
        #expect(try Session(contentsOf: package) == Self.state(1))
    }

    /// C3: the backups that one save adds, with names planted at these offsets from the mtime.
    func added(planted offsets: [Int]) throws -> Int {
        let package = try Self.newPackage()
        for offset in offsets { try Self.plant(Self.time + offset, "planted \(offset)", in: package) }
        try Self.save(Self.state(1), in: package)
        return Self.names(in: package).count - offsets.count
    }

    /// C3. 599 s is not due; 600 s, no backup, and only names after the mtime are due.
    @Test func aBackupIsDueAfterTenMinutes() throws {
        #expect(try added(planted: [-599]) == 0, "599 s is not due")
        #expect(try added(planted: [-600]) == 1, "600 s is due")
        #expect(try added(planted: [-600, -10]) == 0, "the newest name decides")
        #expect(try added(planted: []) == 1, "no backup is due")
        #expect(try added(planted: [60]) == 1, "a name after the mtime does not count")
        let replaced = Backup(saved: Date(timeIntervalSince1970: TimeInterval(Self.time)))
        let newest = { (offset: Int) in Backup(saved: Date(timeIntervalSince1970: TimeInterval(Self.time + offset))) }
        #expect(!BackupPolicy.isDue(newest: newest(-599), replacing: replaced), "isDue at 599 s")
        #expect(BackupPolicy.isDue(newest: newest(-600), replacing: replaced), "isDue at 600 s")
    }

    /// C3: a newest name 15 min behind the mtime, then 30 saves 1 s apart. Failing value: 30.
    @Test func aSkewedClockGivesOneBackup() throws {
        try Self.plant(Self.time - 900, "planted", in: package)
        for index in 1...30 {
            try Self.save(Self.state(index), in: package)
            try Self.setTime(of: sessionXML, to: Self.time + index)
        }
        #expect(Self.names(in: package).count == 2, "30 saves 1 s apart keep one backup")
    }

    /// C4: with 20 backups, a due backup deletes the oldest; other names stay.
    @Test func aPruneKeepsTheNewestAndForeignFiles() throws {
        let planted = try (1...20).map { try Self.plant(Self.time - 600 * $0, "planted \($0)", in: package) }
        for name in ["notes.xml", "session-2026.xml"] {
            try Data("foreign".utf8).write(to: folder.appending(path: name))
        }

        try Self.save(Self.state(1), in: package)

        let expected = Set(planted.dropLast()).union([Self.name(Self.time), "notes.xml", "session-2026.xml"])
        #expect(Self.names(in: package) == expected, "the prune keeps the 20 newest and the foreign files")
    }

    /// C4: an old backup of a newer version stays; an old damaged backup goes.
    @Test func aPruneKeepsANewerVersion() throws {
        let planted = try (1...20).map { try Self.plant(Self.time - 600 * $0, "planted \($0)", in: package) }
        let xml = String(decoding: try Data(contentsOf: sessionXML), as: UTF8.self)
        try #require(xml.contains(" version=\"1\""))
        let newer = try Self.plant(
            Self.time - 30_000, xml.replacingOccurrences(of: " version=\"1\"", with: " version=\"99\""), in: package)
        try Self.plant(Self.time - 31_000, "xx", in: package)

        try Self.save(Self.state(1), in: package)

        let expected = Set(planted.dropLast()).union([Self.name(Self.time), newer])
        #expect(Self.names(in: package) == expected, "the prune keeps a newer version and deletes a damaged file")
    }

    /// C4: an old backup that the prune cannot read stays: it can be of a newer version.
    @Test func aPruneKeepsABackupThatItCannotRead() throws {
        for index in 1...20 { try Self.plant(Self.time - 600 * index, "planted \(index)", in: package) }
        let unreadable = try Self.plant(Self.time - 30_000, "unreadable", in: package)
        try #require(chmod(folder.appending(path: unreadable).path, 0o000) == 0)
        defer { chmod(folder.appending(path: unreadable).path, 0o644) }

        try Self.save(Self.state(1), in: package)

        #expect(Self.names(in: package).contains(unreadable), "the prune keeps a backup that it cannot read")
    }

    /// C4: 20 names after the new name do not push it out.
    @Test func futureNamesDoNotFillTheWindow() throws {
        let planted = try (1...20).map { try Self.plant(Self.time + 60 * $0, "future \($0)", in: package) }

        try Self.save(Self.state(1), in: package)

        #expect(Self.names(in: package) == Set(planted).union([Self.name(Self.time)]), "the new backup stays")
    }

    /// C9 core: no copy when a backup has the bytes of `session.xml`, and so no prune.
    @Test func keepSkipsBytesThatBackupsHold() throws {
        let current = String(decoding: try Data(contentsOf: sessionXML), as: UTF8.self)
        for index in 2...21 { try Self.plant(Self.time - 600 * index, "planted \(index)", in: package) }
        try Self.plant(Self.time - 600, current, in: package)
        let before = Self.names(in: package)

        #expect(try Backup.keep(in: package) == nil, "keep copies no bytes that a backup holds")
        try Self.save(Self.state(1), in: package)

        #expect(Self.names(in: package) == before, "a due save of held bytes adds and deletes no file")
    }

    /// U21: on a volume with a coarse `mtime`, two states can have one `mtime`. Failing value: the
    /// second copy writes over the first.
    @Test func twoStatesWithOneMtimeKeepTwoBackups() throws {
        let first = try Data(contentsOf: sessionXML)
        try #require(try Backup.keep(in: package) != nil)
        let second = try Self.state(1).checkedData()
        try second.write(to: sessionXML)
        try Self.setTime(of: sessionXML, to: Self.time)

        let kept = try Backup.keep(in: package)

        let bumped = Self.name(Self.time).replacingOccurrences(of: ".000Z", with: ".001Z")
        #expect(kept?.fileName == bumped, "the second copy gets the next millisecond")
        #expect(Self.names(in: package) == [Self.name(Self.time), bumped], "both backups stay")
        #expect((try? Data(contentsOf: folder.appending(path: Self.name(Self.time)))) == first, "both backups stay")
        #expect((try? Data(contentsOf: folder.appending(path: bumped))) == second)
    }

    /// C9 core: a backup of the same size with one other byte is not the same file.
    @Test func keepCopiesOtherBytesOfTheSameSize() throws {
        var current = try Data(contentsOf: sessionXML)
        current[current.count - 2] ^= 1
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try current.write(to: folder.appending(path: Self.name(Self.time - 600)))

        #expect(try Backup.keep(in: package) != nil, "keep copies bytes of the same size that differ")
    }

    /// C5: a due backup needs twice the size of `session.xml` free, so the save after it has space.
    @Test func aBackupNeedsTwiceTheFileSizeFree() throws {
        let size = Int64(try Data(contentsOf: sessionXML).count)

        try BackupPolicy.standard.keepIfDue(in: package, freeBytes: { _ in 2 * size - 1 })
        #expect(Self.names(in: package).isEmpty, "no backup with less than twice the file size free")

        try BackupPolicy.standard.keepIfDue(in: package, freeBytes: { _ in 2 * size })
        #expect(Self.names(in: package) == [Self.name(Self.time)], "a backup with twice the file size free")
    }

    /// C5: a `statfs` error does not stop the backups: the save already catches a failed copy.
    @Test func aFreeSpaceErrorDoesNotStopTheBackups() {
        #expect(volumeFreeBytes(package.appending(path: "Gone")) == .max, "an error gives no limit")
    }

    /// C5: a regular file named `Backups`, then a folder with no write access.
    @Test func aBackupFaultDoesNotStopTheSave() throws {
        try Data("not a folder".utf8).write(to: folder)
        #expect(throws: Never.self, "a backup fault does not fail the save") {
            try Self.save(Self.state(1), in: package)
        }
        #expect(try Session(contentsOf: package) == Self.state(1))

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try #require(chmod(folder.path, 0o555) == 0)
        defer { chmod(folder.path, 0o755) }
        #expect(throws: Never.self, "a backup fault does not fail the save") {
            try Self.save(Self.state(2), in: package)
        }
        #expect(try Session(contentsOf: package) == Self.state(2))
    }

    /// C6: 30 saves 600 s apart, so each keeps a backup. Each backup is an older state.
    @Test func backupsNeverReplaceTheSession() throws {
        let states = try (0...30).map(Self.state)
        for index in 1...30 {
            try Self.save(states[index], in: package)
            try Self.setTime(of: sessionXML, to: Self.time + 600 * index)
        }
        #expect(try Session(contentsOf: package) == states[30])
        let kept = try Self.names(in: package).map { try Session(xml: Data(contentsOf: folder.appending(path: $0))) }
        #expect(kept.count == 20)
        #expect(kept.allSatisfy { states.dropLast().contains($0) }, "each backup is an older state")
    }

    /// C14.
    @Test func theListIsNewestFirst() throws {
        #expect(Backup.all(in: package) == [])
        for offset in [0, -5, 3] { try Self.plant(Self.time + offset, "planted \(offset)", in: package) }
        for name in ["notes.xml", "session-2026.xml", ".session.xml.\(UUID().uuidString).tmp"] {
            try Data("other".utf8).write(to: folder.appending(path: name))
        }
        #expect(Backup.all(in: package).map(\.fileName) == [3, 0, -5].map { Self.name(Self.time + $0) })
    }

    /// C15: the sweep deletes the temporary file of a backup and keeps other names.
    @Test func theSweepCleansBackups() throws {
        let backup = try Self.plant(Self.time - 600, "planted", in: package)
        let leftover = ".session.xml.\(UUID().uuidString).tmp"
        for name in [leftover, "notes.tmp"] { try Data("x".utf8).write(to: folder.appending(path: name)) }

        try Session(contentsOf: package).removeTemporaryFiles(in: package)

        #expect(Self.names(in: package) == [backup, "notes.tmp"])
    }

    /// C13: a newer, a damaged, and a deleted backup throw. `session.xml` and `Backups/` do not
    /// change.
    @Test func aRefusedBackupChangesNothing() throws {
        let xml = String(decoding: try Data(contentsOf: sessionXML), as: UTF8.self)
        try #require(xml.contains(" version=\"1\""))
        let newer = try Self.plant(
            Self.time - 600, xml.replacingOccurrences(of: " version=\"1\"", with: " version=\"99\""), in: package)
        let damaged = try Self.plant(Self.time - 1200, "xx", in: package)
        let deleted = Backup(saved: Date(timeIntervalSince1970: TimeInterval(Self.time - 1800)))
        let old = try Data(contentsOf: sessionXML)
        let before = Self.names(in: package)
        let cases: [(Backup?, SessionFileError)] = [
            (Backup(fileName: newer), .unsupportedVersion(99)), (Backup(fileName: damaged), .malformedXML),
            (deleted, .readFailed(errno: ENOENT)),
        ]

        let lock = try PackageLock(package)
        for (backup, error) in cases {
            let backup = try #require(backup)
            #expect(throws: RevertReadError.backup(error), "the revert refuses \(backup.fileName)") {
                try backup.readForRevert(under: lock)
            }
        }
        withExtendedLifetime(lock) {}

        #expect(Self.names(in: package) == before, "a refused backup adds no file")
        #expect(try Data(contentsOf: sessionXML) == old)
    }

    /// C9 core: the read keeps the current file, also when the newest backup is 1 s old. A second
    /// read of the same file adds no file, and no read prunes.
    @Test func readForRevertKeepsTheCurrentFileOnce() throws {
        for index in 1...20 { try Self.plant(Self.time - index, "planted \(index)", in: package) }
        let target = try Self.state(2)
        let backup = Backup(saved: Date(timeIntervalSince1970: TimeInterval(Self.time - 30_000)))
        try target.checkedData().write(to: folder.appending(path: backup.fileName))
        let current = try Data(contentsOf: sessionXML)

        let lock = try PackageLock(package)
        #expect(try backup.readForRevert(under: lock) == target)
        let kept = try? Data(contentsOf: folder.appending(path: Self.name(Self.time)))
        #expect(kept == current, "the read keeps the current file")
        #expect(Self.names(in: package).count == 22, "the read prunes nothing")

        #expect(try backup.readForRevert(under: lock) == target)
        withExtendedLifetime(lock) {}
        #expect(Self.names(in: package).count == 22, "a second read adds no file")
    }

    /// C9 core: 20 backups, and `session.xml` has the bytes of the oldest (a saved revert to it).
    /// A revert to the newest, an edit, and a due save that prunes. The replaced state stays.
    @Test func aRevertKeepsTheStateItReplacesPastThePrune() throws {
        let states = try (1...20).map(Self.state)
        for (index, state) in states.enumerated() {
            try Self.plant(
                Self.time - 600 * (index + 1), String(decoding: try state.checkedData(), as: UTF8.self), in: package)
        }
        let replaced = try states[19].checkedData()
        try replaced.write(to: sessionXML)
        try Self.setTime(of: sessionXML, to: Self.time)
        do {
            let lock = try PackageLock(package)
            let newest = try #require(Backup(fileName: Self.name(Self.time - 600)))
            #expect(try newest.readForRevert(under: lock) == states[0])
            withExtendedLifetime(lock) {}
        }

        try Self.save(Self.state(30), in: package)
        try Self.setTime(of: sessionXML, to: Self.time + 600)
        try Self.save(Self.state(31), in: package)

        let held = Self.names(in: package).map { try? Data(contentsOf: folder.appending(path: $0)) }
        #expect(held.contains(replaced), "the state that the revert replaced stays after the prune")
    }

    /// C4, the take-start branch: `.none` keeps and deletes no backup, also when one is due.
    @Test func noBackupPolicyAddsNothing() throws {
        for index in 1...20 { try Self.plant(Self.time - 600 * index, "planted \(index)", in: package) }
        let before = Self.names(in: package)

        try Self.save(Self.state(1), in: package, .none)

        #expect(Self.names(in: package) == before, "a save with no backup policy adds and deletes no file")
        #expect(try Session(contentsOf: package) == Self.state(1))
    }
}
