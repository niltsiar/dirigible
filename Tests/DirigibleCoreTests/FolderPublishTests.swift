import Foundation
import Testing

@testable import DirigibleCore

/// C22, C6, and C7 of the stem export: `stageFolder(for:kind:)` and `StagingFolder` publish a
/// folder that appears whole or not at all, and the sweep removes only dead staging items.
struct FolderPublishTests {
    /// A new folder in the temporary folder, and the target `Stems` in it.
    final class Place {
        let parent: URL
        var target: URL { parent.appending(path: "Stems") }

        init() throws {
            parent = FileManager.default.temporaryDirectory.appending(path: "FolderPublishTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: parent) }

        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted() }

        func makeFolder(_ name: String, file: String? = nil) throws {
            try FileManager.default.createDirectory(
                at: parent.appending(path: name), withIntermediateDirectories: false)
            if let file { try Data("x".utf8).write(to: parent.appending(path: "\(name)/\(file)")) }
        }

        func makeFile(_ name: String) throws { try Data("lock".utf8).write(to: parent.appending(path: name)) }

        /// Holds an flock on the file `name` through a descriptor of its own, as a live export does.
        func hold(_ name: String) throws -> Int32 {
            let descriptor = open(parent.appending(path: name).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            try #require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            return descriptor
        }
    }

    /// The error of a publish, or nil.
    static func publishError(_ staging: consuming StagingFolder) -> SessionFileError? {
        do { try staging.publish() } catch { return error }
        return nil
    }

    static func inode(_ url: URL) -> ino_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_ino : nil
    }

    static let uuid = UUID().uuidString

    @Test func aPublishOntoAnItemThrowsAndKeepsIt() throws {
        for item in ["file", "full folder", "empty folder"] {
            let place = try Place()
            switch item {
            case "file": try Data("user".utf8).write(to: place.target)
            case "full folder": try place.makeFolder("Stems", file: "user.wav")
            default: try place.makeFolder("Stems")
            }
            let before = Self.inode(place.target)
            let staging = try stageFolder(for: place.target, kind: "stems")
            try Data("stem".utf8).write(to: staging.url.appending(path: "01.wav"))
            #expect(Self.publishError(staging) == .exists, "\(item)")
            #expect(Self.inode(place.target) == before && before != nil, "\(item) keeps its inode")
            #expect(try place.names() == ["Stems"], "\(item): no staging folder and no lock file stay")
            switch item {
            case "file": #expect(try Data(contentsOf: place.target) == Data("user".utf8))
            case "full folder":
                #expect(try FileManager.default.contentsOfDirectory(atPath: place.target.path) == ["user.wav"])
            default: #expect(try FileManager.default.contentsOfDirectory(atPath: place.target.path) == [])
            }
        }
    }

    @Test func aPublishOntoAFreeNameMovesTheFolder() throws {
        let place = try Place()
        let staging = try stageFolder(for: place.target, kind: "stems")
        #expect(staging.url.deletingLastPathComponent().path == place.parent.path)
        try Data("stem".utf8).write(to: staging.url.appending(path: "01.wav"))
        #expect(Self.publishError(staging) == nil)
        #expect(try place.names() == ["Stems"])
        #expect(try Data(contentsOf: place.target.appending(path: "01.wav")) == Data("stem".utf8))
    }

    @Test func theClaimFallbackPublishes() throws {
        let place = try Place()
        var seams = FolderPublishSeams()
        seams.exclusiveRename = { _, _ in ENOTSUP }
        let staging = try stageFolder(for: place.target, kind: "stems", seams: seams)
        try Data("stem".utf8).write(to: staging.url.appending(path: "01.wav"))
        #expect(Self.publishError(staging) == nil)
        #expect(try place.names() == ["Stems"])
        #expect(try Data(contentsOf: place.target.appending(path: "01.wav")) == Data("stem".utf8))
    }

    /// An item gets into the claim between the `mkdir` and the rename: the claim stays with it.
    @Test func aFullClaimStays() throws {
        let place = try Place()
        var seams = FolderPublishSeams()
        seams.exclusiveRename = { _, _ in ENOTSUP }
        let target = place.target
        seams.plainRename = { from, to in
            try? Data("user".utf8).write(to: target.appending(path: "user.wav"))
            return rename(from, to) == 0 ? 0 : errno
        }
        let staging = try stageFolder(for: place.target, kind: "stems", seams: seams)
        try Data("stem".utf8).write(to: staging.url.appending(path: "01.wav"))
        #expect(Self.publishError(staging) == .exists)
        #expect(try place.names() == ["Stems"])
        #expect(try Data(contentsOf: place.target.appending(path: "user.wav")) == Data("user".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.target.path) == ["user.wav"])
    }

    @Test func aFailedClaimRenameRemovesTheClaim() throws {
        let place = try Place()
        var seams = FolderPublishSeams()
        seams.exclusiveRename = { _, _ in ENOTSUP }
        seams.plainRename = { _, _ in EIO }
        let staging = try stageFolder(for: place.target, kind: "stems", seams: seams)
        #expect(Self.publishError(staging) == .writeFailed(step: "rename", errno: EIO))
        #expect(try place.names() == [], "no claim, no staging folder, and no lock file stay")
    }

    @Test func aDeadStagingFolderIsSwept() throws {
        let place = try Place()
        try place.makeFolder(".Stems.\(Self.uuid).stems", file: "01.wav")
        try place.makeFile(".Stems.\(Self.uuid).stems.lock")
        let staging = try stageFolder(for: place.target, kind: "stems")
        let name = staging.url.lastPathComponent
        #expect(try place.names() == [name, "\(name).lock"].sorted())
        staging.discard()
        #expect(try place.names() == [])
    }

    @Test func aLiveStagingFolderStays() throws {
        let place = try Place()
        let live = ".Stems.\(Self.uuid).stems"
        try place.makeFolder(live, file: "01.wav")
        let descriptor = try place.hold("\(live).lock")
        defer { close(descriptor) }
        let staging = try stageFolder(for: place.target, kind: "stems")
        let name = staging.url.lastPathComponent
        #expect(try place.names() == [live, "\(live).lock", name, "\(name).lock"].sorted())
        staging.discard()
    }

    @Test func aStagingFolderOfAnotherKindStays() throws {
        let place = try Place()
        let other = ".Stems.\(Self.uuid).template"
        try place.makeFolder(other, file: "session.xml")
        try place.makeFile("\(other).lock")
        let staging = try stageFolder(for: place.target, kind: "stems")
        let name = staging.url.lastPathComponent
        #expect(try place.names() == [other, "\(other).lock", name, "\(name).lock"].sorted())
        staging.discard()
    }

    @Test func aLoneLockFileOrFolderGoesOnlyForItsTarget() throws {
        let place = try Place()
        let (one, two, three) = (UUID().uuidString, UUID().uuidString, UUID().uuidString)
        try place.makeFolder(".Stems.\(one).stems", file: "01.wav")
        try place.makeFile(".Stems.\(two).stems.lock")
        try place.makeFile(".Other.\(three).stems.lock")
        let staging = try stageFolder(for: place.target, kind: "stems")
        let name = staging.url.lastPathComponent
        #expect(try place.names() == [".Other.\(three).stems.lock", name, "\(name).lock"].sorted())
        staging.discard()
    }

    @Test func aDeadStagingFolderOfAnotherTargetIsRemoved() throws {
        let place = try Place()
        try place.makeFolder(".other.\(Self.uuid).stems", file: "01.wav")
        try place.makeFile(".other.\(Self.uuid).stems.lock")
        let staging = try stageFolder(for: place.target, kind: "stems")
        let name = staging.url.lastPathComponent
        #expect(try place.names() == [name, "\(name).lock"].sorted())
        staging.discard()
    }

    @Test func aFolderWithNoUUIDStays() throws {
        let place = try Place()
        try place.makeFolder(".Stems.notauuid.stems", file: "01.wav")
        try place.makeFile(".Stems.notauuid.stems.lock")
        try place.makeFolder(".other.\(Self.uuid).stems", file: "01.wav")
        let staging = try stageFolder(for: place.target, kind: "stems")
        let name = staging.url.lastPathComponent
        let kept = [".Stems.notauuid.stems", ".Stems.notauuid.stems.lock", ".other.\(Self.uuid).stems"]
        #expect(try place.names() == (kept + [name, "\(name).lock"]).sorted())
        staging.discard()
    }

    /// With the capability bit not set, the check renames an empty folder over an empty folder in
    /// the staging folder; with the bit set, it runs no rename.
    @Test func aVolumeWithNoExclusiveRenameRunsTheClaimTest() throws {
        let place = try Place()
        for (bit, renames, expected) in [
            (false, false, SessionFileError.writeFailed(step: "rename test", errno: EXDEV)), (false, true, nil),
            (true, false, nil),
        ] as [(Bool, Bool, SessionFileError?)] {
            var seams = FolderPublishSeams()
            seams.hasExclusiveRename = { _ in bit }
            if !renames { seams.plainRename = { _, _ in EXDEV } }
            let staging = try stageFolder(for: place.target, kind: "stems", seams: seams)
            var thrown: SessionFileError?
            do { try staging.checkPublish() } catch { thrown = error }
            #expect(thrown == expected, "bit \(bit), rename \(renames)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging.url.path) == [])
            staging.discard()
        }
    }

    /// The lock name `.<name>.<UUID>.stems.lock` fits 255 bytes at a folder name of 206 bytes.
    @Test func theFolderNameLimitFitsTheLockName() throws {
        #expect(folderNameLimit(kind: "stems") == 206)
        let place = try Place()
        let fits = try stageFolder(for: place.parent.appending(path: String(repeating: "é", count: 103)), kind: "stems")
        fits.discard()
        var thrown: SessionFileError?
        do {
            let over = try stageFolder(
                for: place.parent.appending(path: String(repeating: "a", count: 207)), kind: "stems")
            over.discard()
        } catch { thrown = error }
        #expect(thrown == .writeFailed(step: "lock", errno: ENAMETOOLONG))
        #expect(try place.names() == [])
    }
}
