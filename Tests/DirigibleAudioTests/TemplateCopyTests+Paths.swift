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
