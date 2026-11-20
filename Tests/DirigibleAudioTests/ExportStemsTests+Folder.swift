import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// Criteria C6, C7, and C16 of the stem export: the stem folder appears whole or not at all, and a
/// refusal comes before the first stem.
struct ExportStemsFolderTests {
    /// Two tracks of noise over 0..<48000.
    static func twoTracks() throws -> MixPackage {
        let package = try MixPackage()
        try package.addFile("n1", channels: [ExportStemsTests.noise(48_000, peak: 0.2, seed: 1)])
        try package.addFile("n2", channels: [ExportStemsTests.noise(48_000, peak: 0.2, seed: 2)])
        try package.addTrack("t1", clip: "a", file: "n1", start: 0, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "b", file: "n2", start: 0, offset: 0, length: 48_000)
        return package
    }

    /// Exports the stems of every track over 0..<48000 to `stems` in the test folder.
    static func stems(
        _ package: MixPackage, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false },
        stage: (URL) throws(SessionFileError) -> StagingFolder = { url throws(SessionFileError) in
            try stageFolder(for: url, kind: stemsKind)
        },
        freeBytes: (URL) -> Int64 = { _ in .max }
    ) throws -> Result<StemsResult, ExportStemsError> {
        let source = try #require(ExportSource(range: 0..<48_000))
        return Result { () throws(ExportStemsError) in
            try exportStems(
                package.session, by: .track, source: source, options: ExportStemsTests.wav24,
                to: package.folder.url.appending(path: "stems"), package: { package.url }, progress: progress,
                isCancelled: isCancelled, stage: stage, freeBytes: freeBytes)
        }
    }

    /// The names that start with `.stems.` in the test folder: staging folders and lock files.
    static func leftovers(_ package: MixPackage) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.folder.url.path)) ?? [])
            .filter { $0.hasPrefix(".stems.") }
    }

    /// The staging folder of the export in hand.
    static func staging(_ package: MixPackage) -> URL? {
        leftovers(package).first { !$0.hasSuffix(".lock") }.map { package.folder.url.appending(path: $0) }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The need that a refusal names, from a run with no free byte.
    static func need(_ package: MixPackage) throws -> Int64 {
        guard case .failure(.notEnoughSpace(let need, free: 0)) = try stems(package, freeBytes: { _ in 0 }) else {
            Issue.record("no space refusal")
            return 0
        }
        return need
    }

    /// C6: a cancel at stem 2 of 2, and a failure of stem 2 (an item at its name in the staging
    /// folder makes its move fail), leave no target folder, no staging folder, and no lock file.
    @Test func aCancelOrAFailureLeavesNoFolder() throws {
        let package = try Self.twoTracks()
        let target = package.folder.url.appending(path: "stems")
        func stemOneIsWritten() -> Bool {
            Self.staging(package).map { Self.exists($0.appending(path: "01.wav")) } ?? false
        }
        let cancelled = try Self.stems(package, isCancelled: stemOneIsWritten)
        guard case .failure(.stopped(.cancelled)) = cancelled else {
            Issue.record("cancel gave \(cancelled)")
            return
        }
        #expect(!Self.exists(target) && Self.leftovers(package).isEmpty, "\(Self.leftovers(package))")
        let failed = try Self.stems(
            package,
            isCancelled: {
                if stemOneIsWritten(), let staging = Self.staging(package),
                    !Self.exists(staging.appending(path: "02.wav"))
                {
                    FileManager.default.createFile(atPath: staging.appending(path: "02.wav").path, contents: Data())
                }
                return false
            })
        guard case .failure(.stopped(.exists)) = failed else {
            Issue.record("failure gave \(failed)")
            return
        }
        #expect(!Self.exists(target) && Self.leftovers(package).isEmpty, "\(Self.leftovers(package))")
    }

    /// C6: a folder with a file in it, or a file, at the target does not change, and no stem
    /// renders.
    @Test func anExistingTargetIsNotChanged() throws {
        let package = try Self.twoTracks()
        let target = package.folder.url.appending(path: "stems")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appending(path: "keep.txt"))
        var rendered = false
        guard case .failure(.publish(.exists)) = try Self.stems(package, progress: { _ in rendered = true }) else {
            Issue.record("a folder at the target")
            return
        }
        #expect(try Data(contentsOf: target.appending(path: "keep.txt")) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["keep.txt"])
        try FileManager.default.removeItem(at: target)
        try Data("file".utf8).write(to: target)
        guard case .failure(.publish(.exists)) = try Self.stems(package, progress: { _ in rendered = true }) else {
            Issue.record("a file at the target")
            return
        }
        #expect(try Data(contentsOf: target) == Data("file".utf8))
        #expect(!rendered && Self.leftovers(package).isEmpty)
    }

    /// C6: a volume with no exclusive rename where the rename over an empty folder fails refuses
    /// before the loop renders a stem.
    @Test func aVolumeThatCannotPublishRefusesBeforeTheFirstStem() throws {
        let package = try Self.twoTracks()
        let seams = FolderPublishSeams(plainRename: { _, _ in EXDEV }, hasExclusiveRename: { _ in false })
        var rendered = false
        let result = try Self.stems(
            package, progress: { _ in rendered = true },
            stage: { url throws(SessionFileError) in try stageFolder(for: url, kind: stemsKind, seams: seams) })
        guard case .failure(.publish(.writeFailed(step: "rename test", errno: EXDEV))) = result else {
            Issue.record("gave \(result)")
            return
        }
        #expect(!rendered && Self.leftovers(package).isEmpty)
        #expect(!Self.exists(package.folder.url.appending(path: "stems")))
    }

    /// C7: a dead staging folder with a stem, a `._` file, and a lock file that no process holds, a
    /// staging folder with no lock file, and a lock file with no staging folder, all of the same
    /// target, go at the next stem export to it.
    @Test func theNextExportRemovesTheLeftoversOfADeadOne() throws {
        let package = try Self.twoTracks()
        let folder = package.folder.url
        let dead = folder.appending(path: ".stems.\(UUID().uuidString).stems")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: false)
        try Data([1]).write(to: dead.appending(path: "01.wav"))
        try Data([2]).write(to: dead.appending(path: "._01.wav"))
        try Data().write(to: URL(filePath: dead.path + ".lock"))
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".stems.\(UUID().uuidString).stems"), withIntermediateDirectories: false)
        try Data().write(to: folder.appending(path: ".stems.\(UUID().uuidString).stems.lock"))
        #expect(Self.leftovers(package).count == 4)
        guard case .success(let result) = try Self.stems(package) else {
            Issue.record("the export failed")
            return
        }
        #expect(result.files.map(\.name) == ["01.wav", "02.wav"])
        #expect(Self.leftovers(package).isEmpty, "\(Self.leftovers(package))")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "stems").path).sorted()
                == ["01.wav", "02.wav"])
    }

    /// C16: the need of the stems with `diskMargin` passes, and that need minus 1 refuses with both
    /// numbers before the first stem and leaves no staging folder. The need covers the files.
    @Test func notEnoughSpaceRefusesBeforeTheFirstStem() throws {
        let package = try Self.twoTracks()
        let need = try Self.need(package)
        var rendered = false
        let short = try Self.stems(package, progress: { _ in rendered = true }, freeBytes: { _ in need - 1 })
        guard case .failure(.notEnoughSpace(need: need, free: need - 1)) = short else {
            Issue.record("gave \(short)")
            return
        }
        #expect(!rendered && Self.leftovers(package).isEmpty)
        #expect(!Self.exists(package.folder.url.appending(path: "stems")))
        guard case .success = try Self.stems(package, freeBytes: { _ in need }) else {
            Issue.record("the need did not pass")
            return
        }
        let target = package.folder.url.appending(path: "stems")
        let written = try ["01.wav", "02.wav"].reduce(Int64(0)) { sum, name in
            let size = try FileManager.default.attributesOfItem(atPath: target.appending(path: name).path)[.size]
            return sum + ((size as? Int64) ?? 0)
        }
        #expect(written > 2 * 48_000 * 2 * 3 && need >= written + diskMargin, "need \(need), written \(written)")
        #expect(need - written - diskMargin < 2 * 8_192, "need \(need), written \(written)")
    }

    /// C16: the sweep runs before the space check, so the bytes of a dead staging folder do not
    /// count against the export.
    @Test func aDeadStagingFolderDoesNotBlockTheSpaceCheck() throws {
        let package = try Self.twoTracks()
        let need = try Self.need(package)
        let dead = package.folder.url.appending(path: ".stems.\(UUID().uuidString).stems")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: false)
        try Data(count: 100_000).write(to: dead.appending(path: "01.wav"))
        try Data().write(to: URL(filePath: dead.path + ".lock"))
        let result = try Self.stems(package, freeBytes: { _ in Self.exists(dead) ? need - 100_000 : need })
        guard case .success = result else {
            Issue.record("gave \(result)")
            return
        }
        #expect(!Self.exists(dead) && Self.leftovers(package).isEmpty)
    }

    /// No heard track gives no stem: a refusal before the staging folder exists.
    @Test func noHeardTrackMakesNoFolder() throws {
        let package = try Self.twoTracks()
        try package.session.setMuted(true, tracks: ["t1", "t2"])
        guard case .failure(.noStem) = try Self.stems(package) else {
            Issue.record("no refusal")
            return
        }
        #expect(Self.leftovers(package).isEmpty && !Self.exists(package.folder.url.appending(path: "stems")))
    }
}
