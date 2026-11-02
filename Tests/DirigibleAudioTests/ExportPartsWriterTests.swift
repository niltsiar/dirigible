import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The writer of one file for each part (run 2026-10-28-chapter-export-files, criteria C4, C5, C9,
/// C11, and the old files of C13).
struct ExportPartsWriterTests {
    static let wav = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)

    /// A 10 s tone on one track with `markers`.
    static func package(_ markers: [(String, Frames)], frames: Int = 480_000) throws -> MixPackage {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ExportTests.tone(frames: frames)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(frames))
        for (name, position) in markers {
            try package.session.setMarker(Marker(id: MarkerID(name), name: name, position: position, kind: .chapter))
        }
        return package
    }

    static func export(
        _ package: MixPackage, range: Range<Frames> = 0..<480_000, options: ExportOptions = wav, stem: String = "Ep",
        replacing: [URL: ConfirmedFile] = [:], progress: (ExportPartsProgress) -> Void = { _ in }
    ) throws(ExportPartsError) -> ExportPartsResult {
        try exportParts(
            package.session, range: range, by: .chapters, tracks: nil, options: options, folder: package.folder.url,
            stem: stem, replacing: replacing, package: { package.url }, progress: progress)
    }

    static func targets(_ package: MixPackage, range: Range<Frames> = 0..<480_000, stem: String = "Ep") -> [URL] {
        exportPartTargets(
            package.session, range: range, by: .chapters, options: wav, folder: package.folder.url, stem: stem
        )
        .targets.map(\.url)
    }

    static func listing(_ package: MixPackage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).sorted()
    }

    /// C5. Control: each part one frame late makes the join differ.
    @Test func theWAV24PartsJoinToTheWholeExport() throws {
        let package = try Self.package([("a", 0), ("b", 144_000), ("c", 336_000)])
        let whole = package.folder.url.appending(path: "whole.wav")
        _ = try exportMix(
            package.session, source: ExportSource(range: 0..<480_000)!, options: Self.wav, to: whole,
            package: { package.url })

        let result = try Self.export(package)

        #expect(result.files.map(\.url) == Self.targets(package))
        let parts = try result.files.map { try ExportTests.read($0.url) }
        #expect(parts.map(\.length) == [144_000, 192_000, 144_000])
        let expected = try ExportTests.read(whole)
        for channel in 0..<2 {
            #expect(parts.flatMap { $0.channels[channel] } == expected.channels[channel])
        }
    }

    /// C9. Control: a check of each target inside the loop leaves part 1 on disk.
    @Test func anExistingTargetRefusesTheSetBeforeAnyWrite() throws {
        let package = try Self.package([("a", 0), ("b", 144_000), ("c", 336_000)])
        let targets = Self.targets(package)
        try Data("old".utf8).write(to: targets[1])
        let before = try Self.listing(package)

        #expect(throws: ExportPartsError.exists([targets[1]])) { try Self.export(package) }

        #expect(try Self.listing(package) == before)
        #expect(try Data(contentsOf: targets[1]) == Data("old".utf8))
    }

    /// C9, fix check: a confirmed item that another item took the place of refuses the set first.
    @Test func aChangedConfirmedItemRefusesTheSetBeforeAnyWrite() throws {
        let package = try Self.package([("a", 0), ("b", 144_000), ("c", 336_000)])
        let targets = Self.targets(package)
        try Data("old".utf8).write(to: targets[2])
        let confirmed = try #require(ConfirmedFile(at: targets[2]))
        try FileManager.default.removeItem(at: targets[2])
        try Data("new".utf8).write(to: targets[2])
        let before = try Self.listing(package)

        #expect(throws: ExportPartsError.exists([targets[2]])) {
            try Self.export(package, replacing: [targets[2]: confirmed])
        }

        #expect(try Self.listing(package) == before)
        #expect(try Data(contentsOf: targets[2]) == Data("new".utf8))
    }

    /// C9: `--replace` replaces each confirmed item.
    @Test func aReplaceTakesOnlyTheConfirmedItems() throws {
        let package = try Self.package([("a", 0), ("b", 144_000)])
        let targets = Self.targets(package)
        try Data("old".utf8).write(to: targets[0])
        let confirmed = try #require(ConfirmedFile(at: targets[0]))

        let result = try Self.export(package, replacing: [targets[0]: confirmed])

        #expect(result.files.count == 2)
        #expect(try ExportTests.read(targets[0]).length == 144_000)
    }

    /// C4, H3. Control: `exportNameLimit` 1 byte higher fails at the `.tag.tmp` file.
    @Test func aPartAtTheLongestNameExportsToM4A() throws {
        let package = try Self.package([("A", 0)], frames: 48_000)
        var episode = Episode()
        episode.title = try EpisodeLine("Episode 12")
        package.session.setEpisode(episode)
        let stem = String(repeating: "s", count: exportNameLimit - "-01-A.m4a".utf8.count)
        let options = ExportOptions(format: .aac(.k128), layout: .stereo, rate: .session)

        let result = try Self.export(package, range: 0..<48_000, options: options, stem: stem)

        let url = try #require(result.files.first?.url)
        #expect(exportNameLimit == 209)
        #expect(url.lastPathComponent.utf8.count == exportNameLimit)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// C11. Control: equal bands for each part give 0.67 at the end of part 2.
    @Test func theProgressIsWeightedByFrames() throws {
        let package = try Self.package([("a", 0), ("b", 48_000), ("c", 96_000)])
        var calls: [ExportPartsProgress] = []

        _ = try Self.export(package) { calls.append($0) }

        let third = try #require(calls.first { $0.number == 3 })
        #expect(abs(third.fraction - 0.2) <= 0.01)
        #expect(calls.count <= 104)
        #expect(zip(calls, calls.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    }

    /// C11, N5: a part under 1 % of the frames still reports its start.
    @Test func eachPartStartReportsItsNumberAndName() throws {
        let package = try Self.package([("a", 0), ("b", 240_000), ("c", 240_100)])
        let targets = Self.targets(package)
        var calls: [ExportPartsProgress] = []

        _ = try Self.export(package) { calls.append($0) }

        #expect(calls.contains { $0.number == 2 && $0.count == 3 && $0.name == targets[1].lastPathComponent })
    }

    /// C13 old files: the stem names that the set does not write, and no other name.
    @Test func oldPartFilesAreTheStemNamesThatTheSetDoesNotWrite() throws {
        let package = try Self.package([("A", 0), ("B", 144_000)])
        let targets = exportPartTargets(
            package.session, range: 0..<480_000, by: .chapters,
            options: ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session),
            folder: package.folder.url, stem: "Ep 12")
        let folder = package.folder.url
        for name in ["Ep 12-05-Outro.mp3", "Ep 12.mp3", "Ep 13-01-A.mp3", "Ep 12-01-A.mp3"] {
            try Data("old".utf8).write(to: folder.appending(path: name))
        }

        let old = oldPartFiles(in: folder, stem: "Ep 12", pathExtension: "mp3", targets: targets.targets)

        #expect(old == [folder.appending(path: "Ep 12-05-Outro.mp3")])
        #expect(try Data(contentsOf: folder.appending(path: "Ep 12-05-Outro.mp3")) == Data("old".utf8))
    }
}
