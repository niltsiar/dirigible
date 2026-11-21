import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Pool paths that name one file in two ways (code gate 1, item 4).
extension TemplateCopyTests {
    /// `./a.wav` and `./sub/b.wav` name the files of `a.wav` and `sub/b.wav`; on a volume that ignores case,
    /// `A.wav` does too. Each file copies once, and the copy makes the package.
    @Test func aPoolPathWithADotOrACaseVariantCopiesOnce() throws {
        let fixture = try TemplateFixture()
        let ignoresCase =
            try fixture.folder.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames == false
        var paths = ["./a.wav", "./sub/b.wav"]
        if ignoresCase { paths.append("A.wav") }
        for (index, path) in paths.enumerated() {
            let id = "d\(index)"
            try fixture.session.addFile(AudioFile(id: FileID(id), path: path, layout: .mono, length: 88_200))
            try fixture.session.place(
                Clip(
                    id: ClipID(id), file: FileID(id), start: Frames(400_000 + index * 100_000), offset: 0,
                    length: 88_200),
                on: "t")
        }
        try fixture.session.write(to: fixture.template)

        try createSession(
            at: fixture.target, template: fixture.template, progress: { _ in }, isCancelled: { false },
            seams: TemplateCopySeams())

        #expect(
            fixture.files(under: fixture.target).map { $0.lowercased() }
                == (TemplateFixture.copied + ["session.xml"]).map { $0.lowercased() }.sorted())
        #expect(try Session(contentsOf: fixture.target).files.count == 3 + paths.count, "the pool keeps each entry")
    }

    /// A template on a volume that ignores case names `a.wav` and `A.wav`, one file. On a case-sensitive volume
    /// they are two names, so each pool path of the new session must exist. Slow: it makes a disk image.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCaseVariantCopiesEachSpellingOntoACaseSensitiveVolume() throws {
        let fixture = try TemplateFixture()
        let values = try fixture.folder.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        try #require(values.volumeSupportsCaseSensitiveNames == false, "the temporary folder must ignore case")
        try fixture.session.addFile(AudioFile(id: FileID("d"), path: "A.wav", layout: .mono, length: 88_200))
        try fixture.session.place(
            Clip(id: ClipID("d"), file: FileID("d"), start: Frames(500_000), offset: 0, length: 88_200), on: "t")
        try fixture.session.write(to: fixture.template)
        let image = fixture.folder.url.appending(path: "cased.dmg")
        let volume = fixture.folder.url.appending(path: "volume")
        try FullDiskTests.hdiutil(
            "create", "-size", "20m", "-fs", "Case-sensitive HFS+", "-volname", "DirigibleCased", image.path)
        try FullDiskTests.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { try? FullDiskTests.hdiutil("detach", volume.path, "-force") }
        let package = volume.appending(path: "New.dirigible")
        var seams = TemplateCopySeams()
        seams.freeBytes = { _ in .max }  // The 1 GB margin of the space check is over the image.

        try createSession(
            at: package, template: fixture.template, progress: { _ in }, isCancelled: { false }, seams: seams)

        let paths = try Session(contentsOf: package).files.values.map(\.path)
        #expect(paths.contains("A.wav") && paths.contains("a.wav"))
        for path in paths {
            #expect(FileManager.default.fileExists(atPath: package.appending(path: "Clips/\(path)").path), "\(path)")
        }
    }

    @Test func filePathsDropDotComponentsAndRepeats() throws {
        var session = Session(sampleRate: 44_100)
        try session.addTrack("t", name: "Host", layout: .mono)
        for (index, path) in ["a.wav", "./a.wav", "sub/./b.wav"].enumerated() {
            try session.addFile(AudioFile(id: FileID("f\(index)"), path: path, layout: .mono, length: 10))
            try session.place(
                Clip(
                    id: ClipID("c\(index)"), file: FileID("f\(index)"), start: Frames(index * 100), offset: 0,
                    length: 10),
                on: "t")
        }

        #expect(try session.newEpisode().filePaths == ["Clips/a.wav", "Clips/sub/b.wav"])
    }
}
