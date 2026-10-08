import DirigibleCore
import Foundation
import Testing

/// The file-ID map of a paste from another package (decision 0042, C1b), and the package identity
/// that tells a package from another one (C3).
struct ExcerptMapTests {
    @Test func aMapRewritesTheClipFilesAndTheRecordsTogether() throws {
        var session = try editFixture()
        try session.place(
            Clip(id: "A", file: "f", start: 0, offset: 100, length: 48_000, gain: Gain(dB: -3)!), on: "a")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 48_000), on: "s")
        let excerpt = try session.excerpt(of: 0..<48_000, on: ["a", "b", "s"])
        #expect(excerpt.sampleRate == 48_000 && excerpt.files.keys.sorted() == ["f", "g"])
        #expect(
            excerpt.lanes.map(\.name) == ["A", "B", "S"] && excerpt.lanes.map(\.layout) == [.mono, .mono, .stereo])
        let f2 = AudioFile(id: "f 2", path: "f 2.wav", layout: .mono, length: 480_000)
        let g2 = AudioFile(id: "g 2", path: "g 2.wav", layout: .stereo, length: 480_000)

        let mapped = try excerpt.mapped(to: ["f": f2, "g": g2])

        #expect(mapped.files == ["f 2": f2, "g 2": g2], "the records go with the clips")
        #expect(mapped.lanes.flatMap(\.clips).map(\.file) == ["f 2", "g 2"])
        let a = try #require(mapped.lanes.first?.clips.first)
        #expect(a == Clip(id: "A", file: "f 2", start: 0, offset: 100, length: 48_000, gain: Gain(dB: -3)!))
        #expect(throws: SessionError.unknownFile("g")) { try excerpt.mapped(to: ["f": f2]) }
    }

    /// A nil identity never matches, so a package with no `.lock` file counts as another package.
    @Test func aNilIdentityNeverMatches() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ExcerptMapTests-\(UUID().uuidString)")
        let package = folder.appending(path: "Show.dirigible")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(PackageID(lockFileOf: package) == nil, "no .lock file yet")

        let lock = try PackageLock(package)
        let id = try #require(lock.identity, "fstat of the held descriptor")
        // The stat branch of an unlocked open (ENOTSUP): the same value from the .lock path.
        #expect(PackageID(lockFileOf: package) == id)
        #expect(PackageID.same(id, PackageID(lockFileOf: package)))
        #expect(!PackageID.same(nil, nil) && !PackageID.same(id, nil) && !PackageID.same(nil, id))
        let moved = folder.appending(path: "Moved.dirigible")
        try #require(rename(package.path, moved.path) == 0)
        #expect(PackageID.same(id, PackageID(lockFileOf: moved)), "a rename keeps the identity")
        withExtendedLifetime(lock) {}
    }
}
