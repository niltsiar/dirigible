import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A template package `Show.dirigible` with three referenced clip files (`Clips/a.wav`,
/// `Clips/c.wav`, `Clips/sub/b.wav`), the episode artwork and a marker image in `Artwork/`, and
/// one item of each kind that must not copy: an unused clip file, an unused artwork file, a
/// transcript, `Backups/`, `Capture/`, `.lock`, and `recovery-attempt`. Each file has its own bytes.
final class TemplateFixture {
    let folder: TemporaryFolder
    let template: URL
    let target: URL
    var session: Session
    static let artwork = try! ArtworkName("0B1E1F4C-8F0E-4C3B-9F1A-2B7D4E6A9C01.jpg")
    static let image = try! ArtworkName("6A0C2D1B-3E4F-4A5B-8C7D-9E0F1A2B3C4D.png")
    /// The referenced paths in copy order.
    static let copied = [
        "Clips/a.wav", "Clips/c.wav", "Clips/sub/b.wav", "Artwork/\(artwork.name)", "Artwork/\(image.name)",
    ]

    init(targetName: String = "New.dirigible") throws {
        folder = try TemporaryFolder()
        template = folder.url.appending(path: "Show.dirigible")
        target = folder.url.appending(path: targetName)
        session = Session(sampleRate: 44_100)
        try session.addTrack("t", name: "Host", layout: .mono)
        for (index, (id, path)) in [("a", "a.wav"), ("b", "sub/b.wav"), ("c", "c.wav"), ("u", "unused.wav")]
            .enumerated()
        {
            try session.addFile(AudioFile(id: FileID(id), path: path, layout: .mono, length: 88_200))
            try write("Clips/\(path)", size: 10_000 + index * 1_000, seed: UInt64(index))
            if id != "u" {
                try session.place(
                    Clip(id: ClipID(id), file: FileID(id), start: Frames(index * 100_000), offset: 0, length: 88_200),
                    on: "t")
            }
        }
        var episode = Episode()
        episode.artwork = Self.artwork
        try episode.set(.title, text: "Episode 1")
        try episode.set(.show, text: "The Show")
        session.setEpisode(episode)
        try session.setMarker(Marker(id: "m", name: "Intro", position: 0, kind: .chapter, image: Self.image))
        try write("Artwork/\(Self.artwork.name)", size: 3_000, seed: 10)
        try write("Artwork/\(Self.image.name)", size: 2_000, seed: 11)
        try write("Artwork/9C2F6C2A-1B3D-4E5F-8A9B-0C1D2E3F4A5B.jpg", size: 1_500, seed: 12)
        let json = #"{"words":[{"word":"hello","start":0.5,"end":0.9}]}"#
        try session.importTranscript(try TranscriptFile(data: Data(json.utf8)), name: "t.json", track: "t", at: 0)
        try session.write(to: template)
        try write("Backups/session-1.xml", size: 100, seed: 13)
        try write("Capture/take1.caf", size: 100, seed: 14)
        try write(".lock", size: 0, seed: 15)
        try write("recovery-attempt", size: 10, seed: 16)
    }

    func write(_ path: String, size: Int, seed: UInt64) throws {
        let url = template.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var generator = SeededGenerator(seed: seed)
        try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
    }

    /// `copyNewEpisode` of the session of this fixture into `target`.
    func copy(
        seams: TemplateCopySeams = TemplateCopySeams(), isCancelled: @escaping () -> Bool = { false },
        progress: @escaping (Double) -> Void = { _ in }
    ) throws(TemplateError) {
        let episode: NewEpisode
        do { episode = try session.newEpisode() } catch { throw .read(.invalidSession(error)) }
        try copyNewEpisode(
            episode, files: template, to: target, progress: progress, isCancelled: isCancelled, seams: seams)
    }

    /// The names in the folder of the template and the target.
    var parentNames: [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()) ?? [] }

    /// Each file under `url`, as a relative path.
    func files(under url: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        var paths: [String] = []
        while let path = enumerator?.nextObject() as? String {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.appending(path: path).path, isDirectory: &isFolder),
                !isFolder.boolValue
            {
                paths.append(path)
            }
        }
        return paths.sorted()
    }

    /// Replaces the file at `path` with a new file of other bytes, through a rename.
    func replace(_ path: String) {
        let url = template.appending(path: path)
        let other = url.deletingLastPathComponent().appending(path: ".other")
        FileManager.default.createFile(atPath: other.path, contents: Data(repeating: 7, count: 500))
        rename(other.path, url.path)
    }

    /// Moves the item at `path` out of the package and puts a link to it at `path`.
    func link(_ path: String) throws {
        let url = template.appending(path: path)
        let moved = folder.url.appending(path: "outside-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: moved)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
    }
}

/// The copy of a template (T3, T4, T5, T12): it reads only the referenced files, checks each one
/// on one descriptor, stages, flushes, and publishes, or leaves nothing.
struct TemplateCopyTests {
    /// A test made nothing: no target and no staging folder or lock file in the parent.
    func madeNothing(_ fixture: TemplateFixture) -> Bool {
        fixture.parentNames.filter { !$0.hasPrefix("outside-") } == ["Show.dirigible"]
    }

    /// The flush seam that records each path, with an action.
    final class Flushes {
        var paths: [String] = []
        var action: (String) -> Void = { _ in }
    }

    func seams(_ flushes: Flushes) -> TemplateCopySeams {
        var seams = TemplateCopySeams()
        seams.flush = { path in
            flushes.paths.append(path)
            flushes.action(path)
            return nil
        }
        return seams
    }

    /// The copy pass names of the flushed files, by their path in the package.
    func flushedFiles(_ flushes: Flushes) -> [String] {
        flushes.paths.compactMap { path in TemplateFixture.copied.first { path.hasSuffix("/\($0)") } }
    }

    // MARK: T3, T4, T5

    @Test func aTemplateCopyHasOnlyTheReferencedFiles() throws {
        let fixture = try TemplateFixture()
        var fractions: [Double] = []

        try createSession(
            at: fixture.target, template: fixture.template, progress: { fractions.append($0) }, isCancelled: { false },
            seams: TemplateCopySeams())

        let expected = try Session(contentsOf: fixture.template).newEpisode().session
        #expect(try Session(contentsOf: fixture.target) == expected)
        #expect(fixture.files(under: fixture.target) == (TemplateFixture.copied + ["session.xml"]).sorted())
        for path in TemplateFixture.copied {
            let same =
                FileManager.default.contents(atPath: fixture.target.appending(path: path).path)
                == FileManager.default.contents(atPath: fixture.template.appending(path: path).path)
            #expect(same, "\(path) byte for byte")
        }
        #expect(fixture.parentNames == ["New.dirigible", "Show.dirigible"], "no staging folder or lock file")
        #expect(fractions.last == 1 && fractions == fractions.sorted(), "the progress rises to 1")
    }

    @Test func aMissingFileLeavesNoPackageAndNoStagingFolder() throws {
        let fixture = try TemplateFixture()
        let flushes = Flushes()
        let last = TemplateFixture.copied[2]
        flushes.action = { path in
            if path.hasSuffix("/\(TemplateFixture.copied[1])") {
                unlink(fixture.template.appending(path: last).path)
            }
        }

        #expect(throws: TemplateError.missing(last)) { try fixture.copy(seams: seams(flushes)) }
        #expect(flushedFiles(flushes) == Array(TemplateFixture.copied.prefix(2)), "two copies ran first")
        #expect(madeNothing(fixture))
    }

    @Test func aCopyOverAnItemThrowsAndKeepsTheItem() throws {
        let fixture = try TemplateFixture()
        try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
        let inside = fixture.target.appending(path: "mine.txt")
        try Data("mine".utf8).write(to: inside)
        var before = stat()
        stat(fixture.target.path, &before)
        let flushes = Flushes()

        #expect(throws: TemplateError.publish(.exists)) { try fixture.copy(seams: seams(flushes)) }

        var after = stat()
        stat(fixture.target.path, &after)
        #expect(after.st_ino == before.st_ino && FileManager.default.contents(atPath: inside.path) == Data("mine".utf8))
        #expect(fixture.files(under: fixture.target) == ["mine.txt"])
        #expect(fixture.parentNames == ["New.dirigible", "Show.dirigible"] && flushes.paths.isEmpty)

        // An empty folder that appears at the target during the copy: the publish does not replace it.
        let late = try TemplateFixture()
        var empty = stat()
        let lateFlushes = Flushes()
        lateFlushes.action = { _ in
            if mkdir(late.target.path, 0o755) == 0 { stat(late.target.path, &empty) }
        }

        #expect(throws: TemplateError.publish(.exists)) { try late.copy(seams: seams(lateFlushes)) }

        var kept = stat()
        stat(late.target.path, &kept)
        #expect(!lateFlushes.paths.isEmpty, "the folder came after the first copy")
        #expect(kept.st_ino == empty.st_ino && late.files(under: late.target).isEmpty)
        #expect(late.parentNames == ["New.dirigible", "Show.dirigible"])
    }

    @Test func aNameOverTheLimitMakesNothing() throws {
        #expect(templateNameLimit == 193)
        let long = try TemplateFixture(targetName: String(repeating: "a", count: 194) + ".dirigible")

        #expect(throws: TemplateError.nameTooLong) { try long.copy() }
        #expect(madeNothing(long))

        let fits = try TemplateFixture(targetName: String(repeating: "a", count: 193) + ".dirigible")
        try fits.copy()
        #expect(FileManager.default.fileExists(atPath: fits.target.appending(path: "session.xml").path))
    }

    @Test func theCopyFlushesTheFilesThenTheFoldersThenTheSessionFile() throws {
        let fixture = try TemplateFixture()
        let flushes = Flushes()
        var seams = seams(flushes)
        seams.writeSession = { session, folder throws(SessionFileError) in
            flushes.paths.append("session.xml")
            try session.write(to: folder)
        }

        try fixture.copy(seams: seams)

        let staging = try #require(flushes.paths.first { $0.hasSuffix(".template") })
        let relative = flushes.paths.map { $0 == staging ? "." : $0.replacing(staging + "/", with: "") }
        #expect(relative == TemplateFixture.copied + ["Clips/sub", "Artwork", "Clips", ".", "session.xml"])
    }

    @Test func aNewerTemplateIsRefusedAndDoesNotChange() throws {
        let fixture = try TemplateFixture()
        let xml = fixture.template.appending(path: "session.xml")
        let text = try String(contentsOf: xml, encoding: .utf8)
        try text.replacing(/version="\d+"/, with: #"version="99""#).write(to: xml, atomically: true, encoding: .utf8)
        let listing = { () -> [String] in
            fixture.files(under: fixture.template).map { path in
                let values = try? fixture.template.appending(path: path).resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                ])
                return
                    "\(path) \(values?.fileSize ?? -1) \(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
            }
        }
        let before = listing()

        #expect(throws: TemplateError.read(.unsupportedVersion(99))) {
            try createSession(
                at: fixture.target, template: fixture.template, progress: { _ in }, isCancelled: { false },
                seams: TemplateCopySeams())
        }
        #expect(listing() == before && madeNothing(fixture))
    }

    // MARK: T12

    @Test func aLinkInArtworkMakesNothing() throws {
        let fixture = try TemplateFixture()
        try fixture.link(TemplateFixture.copied[3])
        let flushes = Flushes()

        #expect(throws: TemplateError.notRegularFile(TemplateFixture.copied[3])) {
            try fixture.copy(seams: seams(flushes))
        }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    @Test func aLinkInClipsMakesNothing() throws {
        let fixture = try TemplateFixture()
        try fixture.link("Clips/c.wav")
        let flushes = Flushes()

        #expect(throws: TemplateError.notRegularFile("Clips/c.wav")) { try fixture.copy(seams: seams(flushes)) }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    @Test func aLinkedArtworkFolderMakesNothing() throws {
        let fixture = try TemplateFixture()
        try fixture.link("Artwork")
        let flushes = Flushes()

        #expect(throws: TemplateError.notRegularFile(TemplateFixture.copied[3])) {
            try fixture.copy(seams: seams(flushes))
        }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    @Test func aLinkedClipsSubfolderMakesNothing() throws {
        let fixture = try TemplateFixture()
        try fixture.link("Clips/sub")
        let flushes = Flushes()

        #expect(throws: TemplateError.notRegularFile("Clips/sub/b.wav")) { try fixture.copy(seams: seams(flushes)) }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    /// The file is replaced after file 1, so the copy pass refuses it before its copy.
    @Test func aReplacedFileThrowsSourceChanged() throws {
        let fixture = try TemplateFixture()
        let second = TemplateFixture.copied[1]
        let flushes = Flushes()
        flushes.action = { path in
            if path.hasSuffix("/\(TemplateFixture.copied[0])") { fixture.replace(second) }
        }

        #expect(throws: TemplateError.sourceChanged(second)) { try fixture.copy(seams: seams(flushes)) }
        #expect(flushedFiles(flushes) == [TemplateFixture.copied[0]], "no copy of the replaced file")
        #expect(madeNothing(fixture))
    }

    /// The path is swapped between the check of the copy pass and the copy.
    @Test func aSwapAfterTheCheckMakesNothing() throws {
        let fixture = try TemplateFixture()
        let second = TemplateFixture.copied[1]
        var seams = TemplateCopySeams()
        seams.beforeCopy = { path in if path == second { fixture.replace(second) } }

        #expect(throws: TemplateError.sourceChanged(second)) { try fixture.copy(seams: seams) }
        #expect(madeNothing(fixture))
    }

    @Test(.timeLimit(.minutes(1))) func aFIFOMakesNothing() throws {
        let fixture = try TemplateFixture()
        let path = TemplateFixture.copied[1]
        unlink(fixture.template.appending(path: path).path)
        try #require(mkfifo(fixture.template.appending(path: path).path, 0o644) == 0)
        let flushes = Flushes()

        #expect(throws: TemplateError.notRegularFile(path)) { try fixture.copy(seams: seams(flushes)) }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    /// The bytes of the referenced files: none clones in these tests.
    let copiedBytes: Int64 = 10_000 + 12_000 + 11_000 + 3_000 + 2_000

    func spaceSeams(free: Int64, flushes: Flushes) -> TemplateCopySeams {
        var seams = seams(flushes)
        seams.canClone = { _, _ in false }
        seams.freeBytes = { _ in free }
        return seams
    }

    @Test func aFullVolumeMakesNothing() throws {
        let fixture = try TemplateFixture()
        let need = copiedBytes + diskMargin
        let flushes = Flushes()

        #expect(throws: TemplateError.space(needed: need, free: need - 1)) {
            try fixture.copy(seams: spaceSeams(free: need - 1, flushes: flushes))
        }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    @Test func oneByteUnderTheSpaceCopies() throws {
        let fixture = try TemplateFixture()

        try fixture.copy(seams: spaceSeams(free: copiedBytes + diskMargin + 1, flushes: Flushes()))

        #expect(fixture.files(under: fixture.target).count == TemplateFixture.copied.count + 1)
    }

    @Test func anEvictedFileMakesNothing() throws {
        let fixture = try TemplateFixture()
        let path = TemplateFixture.copied[2]
        let flushes = Flushes()
        var seams = seams(flushes)
        seams.isDownloaded = { $0.path.hasSuffix(path) == false }

        #expect(throws: TemplateError.notDownloaded(path)) { try fixture.copy(seams: seams) }
        #expect(madeNothing(fixture) && flushes.paths.isEmpty)
    }

    @Test func aCancelMakesNothing() throws {
        let fixture = try TemplateFixture()
        let flushes = Flushes()
        var cancelled = false
        flushes.action = { _ in cancelled = true }

        #expect(throws: TemplateError.cancelled) { try fixture.copy(seams: seams(flushes), isCancelled: { cancelled }) }
        #expect(flushedFiles(flushes) == [TemplateFixture.copied[0]], "the cancel came after file 1")
        #expect(madeNothing(fixture))
    }
}
