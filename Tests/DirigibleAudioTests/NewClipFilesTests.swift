import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The batch of new clip files (decision 0056), in a package folder with no `Clips/` at the start.
struct NewClipFilesTests {
    let folder: TemporaryFolder
    var clips: URL { folder.url.appending(path: clipsFolderName) }

    init() throws { folder = try TemporaryFolder() }

    /// The names in `Clips/`, also hidden ones, sorted.
    var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: clips.path)) ?? []).sorted() }

    func bytes(_ name: String) -> Data? { FileManager.default.contents(atPath: clips.appending(path: name).path) }

    /// C3: the second of three names is taken. File 1 is renamed and stays, the taken file keeps
    /// its bytes, and the cleanup removes temps 2 and 3.
    @Test func aTakenNameIsRefusedAndKept() throws {
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data("taken".utf8).write(to: clips.appending(path: "b.wav"))
        var files = try NewClipFiles(in: folder.url, bytes: 0, freeBytes: { 0 })
        for stem in ["a", "b", "c"] { try Data(stem.utf8).write(to: try files.add(stem: stem)) }

        var thrown: NewClipFault?
        do throws(NewClipFault) { try files.commit() } catch { thrown = error }
        files.discard()

        #expect(thrown == .move(file: "b.wav", errno: EEXIST))
        #expect(bytes("b.wav") == Data("taken".utf8), "the taken file keeps its bytes")
        #expect(bytes("a.wav") == Data("a".utf8), "file 1 is renamed and stays")
        #expect(names == ["a.wav", "b.wav"], "temps 2 and 3 are gone")
        #expect(files.made == [clips.appending(path: "a.wav")], "made lists file 1 only")
    }

    /// C1: 1,000 bytes and the 1 GB margin, at the exact limit. A refusal makes no `Clips/`.
    @Test func spaceCheckRefusesOneByteLess() throws {
        let needed: Int64 = 1_000 + 1_000_000_000

        #expect(throws: NewClipFault.space(needed: needed, free: needed - 1), "1 byte less refuses") {
            _ = try NewClipFiles(in: folder.url, bytes: 1_000, freeBytes: { needed - 1 })
        }
        #expect(!FileManager.default.fileExists(atPath: clips.path), "the refusal comes before the mkdir")
        _ = try NewClipFiles(in: folder.url, bytes: 1_000, freeBytes: { needed })
        #expect(FileManager.default.fileExists(atPath: clips.path), "the exact need passes and makes Clips/")
    }

    /// C1: a batch of clones only needs no free byte.
    @Test func zeroBytesMakesNoCheck() throws {
        _ = try NewClipFiles(in: folder.url, bytes: 0, freeBytes: { 0 })

        #expect(FileManager.default.fileExists(atPath: clips.path) && names == [])
    }

    /// C2: a throw of the caller before the commit leaves only the items from before the batch.
    @Test func aThrowBeforeTheCommitLeavesNoTemp() throws {
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: clips.appending(path: "old.wav"))
        struct Stop: Error {}
        func write() throws {
            var files = try NewClipFiles(in: folder.url, bytes: 0, freeBytes: { 0 })
            defer { files.discard() }
            for stem in ["a", "b"] { try Data(stem.utf8).write(to: try files.add(stem: stem)) }
            #expect(names == [".a.wav.tmp", ".b.wav.tmp", "old.wav"], "the temps are there before the throw")
            throw Stop()
        }

        #expect(throws: Stop.self) { try write() }
        #expect(names == ["old.wav"] && bytes("old.wav") == Data("old".utf8))
    }

    /// C2: two equal stems, in any case, would write one temp, so the second add throws and the
    /// batch stays whole: the first temp is removed by the discard.
    @Test func equalStemsAreRefused() throws {
        var files = try NewClipFiles(in: folder.url, bytes: 0, freeBytes: { 0 })
        try Data("a".utf8).write(to: files.add(stem: "a"))

        var thrown: NewClipFault?
        do throws(NewClipFault) { _ = try files.add(stem: "A") } catch { thrown = error }
        files.discard()

        #expect(thrown == .taken(stem: "A"))
        #expect(files.stems == ["a"] && names == [], "the refused add changed nothing and the temp is gone: \(names)")
    }

    /// C4: `made` lists the renamed files in commit order, and `discard` keeps them.
    @Test func madeListsTheRenamedFiles() throws {
        var files = try NewClipFiles(in: folder.url, bytes: 0, freeBytes: { 0 })
        for stem in ["b", "a"] { try Data(stem.utf8).write(to: try files.add(stem: stem)) }
        #expect(files.made == [])

        try files.commit()
        files.discard()

        #expect(files.made == [clips.appending(path: "b.wav"), clips.appending(path: "a.wav")])
        #expect(names == ["a.wav", "b.wav"] && bytes("a.wav") == Data("a".utf8) && bytes("b.wav") == Data("b".utf8))
    }

    /// C4: a flush fault of `Clips/` after the renames keeps each renamed file (0040).
    @Test func aFlushFaultKeepsTheRenamedFiles() throws {
        let folderPath = clips.path
        var files = try NewClipFiles(
            in: folder.url, bytes: 0, freeBytes: { 0 }, flush: { $0 == folderPath ? EIO : nil })
        for stem in ["a", "b"] { try Data(stem.utf8).write(to: try files.add(stem: stem)) }

        var thrown: NewClipFault?
        do throws(NewClipFault) { try files.commit() } catch { thrown = error }
        files.discard()

        #expect(thrown == .flush(errno: EIO))
        #expect(files.made.count == 2 && names == ["a.wav", "b.wav"], "the renamed files stay: \(names)")
    }

    /// C3: the stem rule of 0040 takes the stems of the batch, in any case.
    @Test func addStemOfTakesTheNextNumber() throws {
        var files = try NewClipFiles(in: folder.url, bytes: 0, freeBytes: { 0 })
        let session = Session(sampleRate: 48_000)

        let first = try files.add(stemOf: URL(filePath: "/x/a.wav"), in: session)
        let second = try files.add(stemOf: URL(filePath: "/x/A.mp3"), in: session)

        #expect(first.stem == "a" && second.stem == "A 2")
        #expect(second.temporary == clips.appending(path: ".A 2.wav.tmp") && files.stems == ["a", "a 2"])
    }

    @Test func eachFaultMapsToTheErrorOfItsCaller() {
        let cases: [(NewClipFault, ImportError, PasteError)] = [
            (.space(needed: 5, free: 4), .space(file: "Voice.mp3", needed: 5, free: 4), .space(needed: 5, free: 4)),
            (
                .folder(errno: EACCES), .write(file: "Voice.mp3", .writeFailed(file: "Clips", status: EACCES)),
                .write(file: "Clips", errno: EACCES)
            ),
            (
                .flush(errno: EIO), .write(file: "Voice.mp3", .writeFailed(file: "Clips", status: EIO)),
                .write(file: "Clips", errno: EIO)
            ),
            (
                .move(file: "a.wav", errno: EEXIST),
                .write(file: "Voice.mp3", .writeFailed(file: "Clips/a.wav", status: EEXIST)),
                .write(file: "a.wav", errno: EEXIST)
            ),
            (
                .taken(stem: "a"), .write(file: "Voice.mp3", .writeFailed(file: "Clips/a.wav", status: EEXIST)),
                .write(file: "a.wav", errno: EEXIST)
            ),
        ]
        for (fault, imported, pasted) in cases {
            #expect(ImportError(fault, file: "Voice.mp3") == imported, "\(fault)")
            #expect(PasteError(fault) == pasted, "\(fault)")
        }
    }

    /// Seeded: 1 to 5 stems, some names taken, sometimes a flush fault. After the commit and the
    /// discard, no temp is left, each taken file keeps its bytes, and `made` is the stems before
    /// the first taken name.
    @Test func eachCommitLeavesNoTempAndKeepsEachTakenFile() throws {
        var random = SeededGenerator(seed: 56)
        for round in 0..<50 {
            let package = folder.url.appending(path: "p\(round)")
            let clips = package.appending(path: clipsFolderName)
            try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
            let stems = (0..<Int.random(in: 1...5, using: &random)).map { "s\($0)" }
            let taken = Set(stems.filter { _ in Int.random(in: 0..<4, using: &random) == 0 })
            for stem in taken { try Data("taken \(stem)".utf8).write(to: clips.appending(path: "\(stem).wav")) }
            let fault = Bool.random(using: &random)
            var files = try NewClipFiles(in: package, bytes: 0, freeBytes: { 0 }, flush: { _ in fault ? EIO : nil })
            for stem in stems { try Data(stem.utf8).write(to: try files.add(stem: stem)) }

            try? files.commit()
            files.discard()

            let renamed = Array(stems.prefix { !taken.contains($0) })
            let left = try FileManager.default.contentsOfDirectory(atPath: clips.path)
            #expect(!left.contains { $0.hasSuffix(".tmp") }, "round \(round): \(left)")
            #expect(Set(left) == Set((renamed + taken).map { "\($0).wav" }), "round \(round): \(left)")
            #expect(files.made == renamed.map { clips.appending(path: "\($0).wav") }, "round \(round)")
            for stem in taken {
                #expect(
                    FileManager.default.contents(atPath: clips.appending(path: "\(stem).wav").path)
                        == Data("taken \(stem)".utf8))
            }
        }
    }
}
