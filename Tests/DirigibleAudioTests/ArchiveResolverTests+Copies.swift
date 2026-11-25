import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A source package "Show" for the copy cases: track t<n> with clip c<n> of the 1 s file f<n> at
/// 48000 Hz, a `.lock` file, and a saved session. `samples` holds the samples of each file before
/// any archive.
final class CopySource {
    let package: MixPackage
    let samples: [Float]

    init(files: [FileID] = ["f1"]) throws {
        package = try MixPackage(name: "Show")
        for (index, id) in files.enumerated() {
            try package.addFile(id, channels: [ramp(frames: 48_000)])
            try package.addTrack(
                TrackID("t\(index + 1)"), clip: ClipID("c\(index + 1)"), file: id, start: 0, offset: 0, length: 48_000)
        }
        try package.session.write(to: package.url)
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        samples = try readAudio(package.url.appending(path: "Clips/f1.wav")).samples
    }

    var url: URL { package.url }

    func file(_ id: FileID = "f1") throws -> AudioFile { try #require(package.session.files[id]) }

    /// A Copy of 0..<48000 on t1, made before any archive.
    var clipboard: Clipboard {
        get throws {
            Clipboard(
                try package.session.excerpt(of: 0..<48_000, on: ["t1"]), package: url,
                origin: PackageID(lockFileOf: url))
        }
    }

    func save(_ session: Session) throws(SessionFileError) -> URL {
        try session.write(to: url)
        return url
    }

    /// `archivePackage` of the saved session.
    func archive() throws {
        var session = package.session
        _ = try archivePackage(&session, in: url, save: save)
        package.session = session
    }

    /// An empty target session at `rate` with the mono track u1.
    func target(rate: Int = 48_000) throws -> MixPackage {
        let target = try MixPackage(sampleRate: rate, name: "Target")
        try target.session.addTrack("u1", name: "u1", layout: .mono)
        return target
    }

    func paste(
        _ clipboard: Clipboard, from source: URL? = nil, into target: MixPackage, free: Int64 = .max,
        canClone: (URL, URL) -> Bool = { _, _ in true }, at: (ExcerptCopyPoint) -> Void = { _ in }
    ) throws(PasteError) {
        _ = try pasteClipboard(
            clipboard, from: source ?? url, into: target.session, in: target.url, identity: nil, mode: .over(at: 0),
            on: .tracks(["u1"]), freeBytes: { free }, canClone: canClone, progress: { _ in }, isCancelled: { false },
            flush: NewClipFiles.flushToDisk, at: at)
    }

    func samples(of url: URL, _ path: String = "Clips/f1.wav") throws -> [Float] {
        try readAudio(url.appending(path: path)).samples
    }
}

/// The copies out of an archived package write WAVs (decision 0072, run criteria C22 and C23).
extension ArchiveResolverTests {
    /// C22: a paste whose clipboard names a source that another window archived after the copy
    /// converts the FLAC to a WAV; the space need counts the decoded frames.
    @Test func aPasteFromASourceArchivedAfterTheCopyConvertsToAWAV() throws {
        let source = try CopySource()
        let clipboard = try source.clipboard
        var clones = 0
        try source.paste(
            clipboard, into: try source.target(),
            canClone: { _, _ in
                clones += 1
                return true
            })
        #expect(clones == 1, "a working source clones its WAV")
        try source.archive()
        let target = try source.target()
        clones = 0

        #expect(throws: PasteError.space(needed: 48_000 * 3 + diskMargin, free: 0)) {
            try source.paste(clipboard, into: target, free: 0)
        }
        try source.paste(
            clipboard, into: target,
            canClone: { _, _ in
                clones += 1
                return true
            })

        #expect(clones == 0, "no clone and no data copy")
        #expect(try clipNames(target.url) == ["f1.wav"])
        #expect(try source.samples(of: target.url) == source.samples)
        #expect(try clipNames(source.url) == ["f1.flac"])
    }

    /// C23: a job unlinks the WAV after the resolve, so the first pass takes the FLAC.
    @Test func aPasteOpensTheFLACWhenAJobUnlinksTheWAVAfterTheResolve() throws {
        let source = try CopySource()
        let wav = source.url.appending(path: "Clips/f1.wav")
        #expect(try !archiveClip(source.file(), in: source.url, rate: 48_000, after: { step, _ in step != .renamed }))
        let target = try source.target()

        try source.paste(
            try source.clipboard, into: target,
            at: { point in
                if case .resolved = point { unlink(wav.path) }
            })

        #expect(try clipNames(target.url) == ["f1.wav"])
        #expect(try source.samples(of: target.url) == source.samples)
    }

    /// C23: the source is archived between the two passes, by a copy and by a conversion.
    @Test(arguments: [48_000, 44_100])
    func aSourceArchivedBetweenThePassesThrowsSourceChanged(rate: Int) throws {
        let source = try CopySource()
        let file = try source.file()
        let target = try source.target(rate: rate)

        #expect(throws: PasteError.sourceChanged(file: "f1.wav")) {
            try source.paste(
                try source.clipboard, into: target,
                at: { point in
                    if point == .checked { _ = try? archiveClip(file, in: source.url, rate: 48_000) }
                })
        }
        #expect(try clipNames(target.url).isEmpty, "no new file")
    }

    /// C23: FLAC data at the WAV name clones, and the read-back refuses it.
    @Test func aWholeCopyOfFLACDataAtTheWAVNameThrowsSourceChanged() throws {
        let source = try CopySource()
        #expect(try archiveClip(source.file(), in: source.url, rate: 48_000))
        try FileManager.default.moveItem(
            at: source.url.appending(path: "Clips/f1.flac"), to: source.url.appending(path: "Clips/f1.wav"))
        let target = try source.target()

        for clone in [true, false] {
            #expect(throws: PasteError.sourceChanged(file: "f1.wav"), "clone \(clone)") {
                try source.paste(try source.clipboard, into: target, canClone: { _, _ in clone })
            }
        }
        #expect(try clipNames(target.url).isEmpty, "no .wav name holds FLAC data")
    }

    /// C23 (a) and (b): a favorite add from an archived source, then a paste of that favorite from
    /// the archived store.
    @Test func aFavoriteOfAnArchivedSourceAndItsPasteFromAnArchivedStoreWriteWAVs() throws {
        let source = try CopySource()
        try source.archive()
        let before = try packageBytes(source.url)
        let store = source.package.folder.url.appending(path: "Favorites.dirigible")
        func saveStore(_ session: Session) throws(SessionFileError) -> URL {
            try session.write(to: store)
            return store
        }

        let id = try Favorites.add(
            try source.clipboard, from: source.url, named: "Sting", bin: nil, store: store,
            log: { favoritesJournal(source.package.folder) })

        #expect(try clipNames(store) == ["f1.wav"])
        #expect(try source.samples(of: store) == source.samples)
        #expect(try packageBytes(source.url) == before, "the source does not change")
        var stored = try Session(contentsOf: store)
        _ = try archivePackage(&stored, in: store, save: saveStore)
        #expect(try clipNames(store) == ["f1.flac"])
        let target = try source.target()

        try source.paste(
            Clipboard(try stored.excerpt(of: id), package: store, origin: PackageID(lockFileOf: store)), from: store,
            into: target)

        #expect(try clipNames(target.url) == ["f1.wav"])
        #expect(try source.samples(of: target.url) == source.samples)
    }

    /// C23 (c): a session import of an archived source.
    @Test func aSessionImportOfAnArchivedSourceWritesWAVs() throws {
        let source = try CopySource()
        try source.archive()
        let before = try packageBytes(source.url)
        let target = try source.target()

        _ = try importSession(
            from: source.url, into: target.session, in: target.url, identity: nil, at: 0, markers: false,
            freeBytes: { .max })

        #expect(try clipNames(target.url) == ["f1.wav"])
        #expect(try source.samples(of: target.url) == source.samples)
        #expect(try packageBytes(source.url) == before, "the source does not change")
    }

    /// C22 link case: a session import refuses a link at the FLAC name.
    @Test func aSessionImportRefusesALinkAtTheFLACName() throws {
        let source = try CopySource()
        try source.archive()
        try Self.linkFLAC(of: source)
        let target = try source.target()

        #expect(throws: SessionImportError.unsafeFile("f1.wav")) {
            try importSession(
                from: source.url, into: target.session, in: target.url, identity: nil, at: 0, markers: false,
                freeBytes: { .max })
        }
        #expect(try clipNames(target.url).isEmpty)
    }

    /// C23 (d): a new session from an archived template gets WAVs and no `archive` attribute.
    @Test func aTemplateCopyOfAnArchivedSessionWritesWAVsAndNoAttribute() throws {
        let source = try CopySource()
        try source.archive()
        #expect(try Session(contentsOf: source.url).archive == .flac)
        let before = try packageBytes(source.url)
        let target = source.package.folder.url.appending(path: "New.dirigible")

        try createSession(at: target, template: source.url, progress: { _ in }, isCancelled: { false })

        #expect(try clipNames(target) == ["f1.wav"])
        #expect(try source.samples(of: target) == source.samples)
        #expect(try Session(contentsOf: target).archive == nil)
        #expect(try packageBytes(source.url) == before, "the template does not change")
    }

    /// C23 (d): the disk need of a template copy counts an archived file as the bytes of its WAV,
    /// not of its FLAC.
    @Test func theTemplateDiskNeedCountsTheWAVBytesOfAnArchivedFile() throws {
        let source = try CopySource()
        try source.archive()
        let target = source.package.folder.url.appending(path: "New.dirigible")
        var seams = TemplateCopySeams()
        seams.freeBytes = { _ in 0 }

        #expect(throws: TemplateError.space(needed: wavFileBytes(frames: 48_000, channels: 1) + diskMargin, free: 0)) {
            try createSession(
                at: target, template: source.url, progress: { _ in }, isCancelled: { false }, seams: seams)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// C22 link case: a template copy refuses a link at the FLAC name.
    @Test func aTemplateCopyRefusesALinkAtTheFLACName() throws {
        let source = try CopySource()
        try source.archive()
        try Self.linkFLAC(of: source)
        let target = source.package.folder.url.appending(path: "New.dirigible")

        #expect(throws: TemplateError.notRegularFile("Clips/f1.flac")) {
            try createSession(at: target, template: source.url, progress: { _ in }, isCancelled: { false })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// C23: a template file archived between the check pass and its copy.
    @Test func aTemplateFileArchivedBetweenThePassesThrowsSourceChanged() throws {
        let source = try CopySource(files: ["f1", "f2"])
        let second = try source.file("f2")
        let target = source.package.folder.url.appending(path: "New.dirigible")
        var seams = TemplateCopySeams()
        seams.flush = { path in
            if path.hasSuffix("/Clips/f1.wav") { _ = try? archiveClip(second, in: source.url, rate: 48_000) }
            return nil
        }

        #expect(throws: TemplateError.sourceChanged("Clips/f2.wav")) {
            try createSession(
                at: target, template: source.url, progress: { _ in }, isCancelled: { false }, seams: seams)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// C23: a job unlinks the WAV of a template after the resolve, so the check pass takes the FLAC.
    @Test func aTemplateCopyOpensTheFLACWhenAJobUnlinksTheWAVAfterTheResolve() throws {
        let source = try CopySource()
        let wav = source.url.appending(path: "Clips/f1.wav")
        #expect(try !archiveClip(source.file(), in: source.url, rate: 48_000, after: { step, _ in step != .renamed }))
        let target = source.package.folder.url.appending(path: "New.dirigible")
        var seams = TemplateCopySeams()
        seams.resolved = { _ in unlink(wav.path) }

        try createSession(at: target, template: source.url, progress: { _ in }, isCancelled: { false }, seams: seams)

        #expect(try clipNames(target) == ["f1.wav"])
        #expect(try source.samples(of: target) == source.samples)
    }

    /// Moves `Clips/f1.flac` out of the package and puts a link to it at its name.
    static func linkFLAC(of source: CopySource) throws {
        let flac = source.url.appending(path: "Clips/f1.flac")
        let outside = source.package.folder.url.appending(path: "f1.flac")
        try FileManager.default.moveItem(at: flac, to: outside)
        try FileManager.default.createSymbolicLink(at: flac, withDestinationURL: outside)
    }
}
