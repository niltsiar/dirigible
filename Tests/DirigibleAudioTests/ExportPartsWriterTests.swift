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
        _ package: MixPackage, range: Range<Frames> = 0..<480_000, tracks: Set<TrackID>? = nil,
        by kind: SplitKind = .chapters, options: ExportOptions = wav, prefix: String = "Ep",
        replacing: [URL: ConfirmedFile] = [:], progress: (ExportPartsProgress) -> Void = { _ in }
    ) throws(ExportPartsError) -> ExportPartsResult {
        try exportParts(
            package.session, source: ExportSource(range: range, tracks: tracks)!, by: kind, options: options,
            folder: package.folder.url, prefix: prefix, replacing: replacing, package: { package.url },
            progress: progress)
    }

    static func targets(_ package: MixPackage, range: Range<Frames> = 0..<480_000, prefix: String = "Ep") -> [URL] {
        exportPartTargets(
            package.session, range: range, by: .chapters, options: wav, folder: package.folder.url, prefix: prefix
        )
        .targets.map(\.url)
    }

    static let mp3 = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session)
    static let m4a = ExportOptions(format: .aac(.k128), layout: .stereo, rate: .session)

    /// Chapters "Intro" at 0 and "Interview" at 3 s, the episode title "Episode 12", and the show.
    static func titled(_ first: String = "Intro") throws -> MixPackage {
        let package = try Self.package([(first, 0), ("Interview", 144_000)], frames: 288_000)
        var episode = Episode()
        episode.title = try EpisodeLine("Episode 12")
        episode.show = try EpisodeLine("The Show")
        package.session.setEpisode(episode)
        return package
    }

    /// C7. Control: the session of the set for each part gives "Episode 12" in every file.
    @Test func anMP3PartHasThePartTitle() async throws {
        let result = try Self.export(try Self.titled(), range: 0..<288_000, options: Self.mp3)
        let frames = try await ID3TagTests.frames(result.files[1].url)
        #expect(frames["id3/TIT2"] == "Interview")
        #expect(frames["id3/TALB"] == "The Show")
    }

    /// C7.
    @Test func anM4APartHasThePartTitle() async throws {
        let result = try Self.export(try Self.titled(), range: 0..<288_000, options: Self.m4a)
        #expect(try await M4ATagTests.atoms(result.files[1].url)["itsk/%A9nam"] == "Interview")
    }

    /// C7: a part title of only whitespace keeps the episode title.
    @Test func aPartWithNoTitleKeepsTheEpisodeTitle() async throws {
        let result = try Self.export(try Self.titled("   "), range: 0..<288_000, options: Self.mp3)
        #expect(try await ID3TagTests.frames(result.files[0].url)["id3/TIT2"] == "Episode 12")
    }

    /// C8: the part of chapter "Interview" has one chapter at 0 with its title.
    @Test func anM4APartHasItsOneChapterAtZero() async throws {
        let result = try Self.export(try Self.titled(), range: 0..<288_000, options: Self.m4a)
        let groups = try await M4AChapterTests.groups(result.files[1].url)
        #expect(groups.map(\.title) == ["Interview"])
        #expect(groups.first?.start.hasPrefix("0/") == true)
    }

    /// C8: a markers split at a plain marker gives a part with no chapter.
    @Test func aPlainMarkerPartHasNoChapter() async throws {
        let package = try Self.titled()
        try package.session.setMarker(Marker(id: MarkerID("plain"), name: "Plain", position: 216_000, kind: .marker))
        let result = try Self.export(package, range: 0..<288_000, by: .markers, options: Self.m4a)
        #expect(result.files.count == 3)
        #expect(try await M4AChapterTests.groups(result.files[2].url).isEmpty)
    }

    /// C6: chapters 6 LU apart each read the target. Control: one gain for the set leaves them 6 LU apart.
    @Test func eachPartIsNormalizedByItself() throws {
        let package = try MixPackage()
        let tone = ExportTests.tone(frames: 480_000, rms: -30) + ExportTests.tone(frames: 480_000, rms: -24)
        try package.addFile("f1", channels: [tone])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 960_000)
        for (name, position) in [("Quiet", Frames(0)), ("Loud", Frames(480_000))] {
            try package.session.setMarker(Marker(id: MarkerID(name), name: name, position: position, kind: .chapter))
        }
        var options = Self.wav
        options.loudness = .podcast

        let reports = try Self.export(package, range: 0..<960_000, options: options).files.map {
            try #require($0.result.loudness)
        }

        #expect(reports.count == 2)
        for report in reports { #expect(abs(try #require(report.output).value - -16) <= 0.1) }
        #expect(abs(reports[0].gain.dB - reports[1].gain.dB - 6) <= 0.2)
    }

    /// C6, U7, probe P2: a part of 300 ms has no 400 ms block, so no measurement and no gain.
    @Test func aShortPartWithATargetGetsNoGain() throws {
        let package = try Self.package([("a", 0), ("short", 465_600)])
        var options = Self.wav
        options.loudness = .podcast

        let report = try #require(try Self.export(package, options: options).files.last?.result.loudness)

        #expect(report.measured == nil)
        #expect(report.gain.dB == 0)
    }

    /// C8: a chapter at the millisecond of the range end has no file; it is a chapter of the part
    /// before it, at its own millisecond.
    @Test func aDroppedChapterStaysInThePartBeforeIt() throws {
        let package = try Self.package([("a", 0), ("z", 479_990)])

        let result = try Self.export(package, options: Self.mp3)

        #expect(result.dropped.map(\.id) == [MarkerID("z")])
        #expect(result.files.count == 1)
        let chapters = ChapterTagTests.chapters(try ChapterTagTests.tag(result.files[0].url))
        #expect(chapters.map(\.start) == [0, 10_000])
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

    /// Code gate 1 item 5: each part source keeps the range and the tracks of the set source, so the
    /// parts of a selection of track t1, which leaves out the t2 tone, join to its whole export.
    @Test func eachPartKeepsTheTracksOfTheSource() throws {
        let package = try Self.package([("a", 0), ("b", 144_000), ("c", 336_000)])
        try package.addFile("f2", channels: [ExportTests.tone(frames: 480_000, rms: -12, sign: -1)])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 480_000)
        let source = try #require(ExportSource(range: 48_000..<432_000, tracks: ["t1"]))
        let whole = package.folder.url.appending(path: "whole.wav")
        _ = try exportMix(package.session, source: source, options: Self.wav, to: whole, package: { package.url })

        let result = try Self.export(package, range: source.range, tracks: source.tracks)

        let parts = try result.files.map { try ExportTests.read($0.url) }
        #expect(parts.map(\.length) == [96_000, 192_000, 96_000])
        let expected = try ExportTests.read(whole)
        for channel in 0..<2 {
            let same = parts.flatMap { $0.channels[channel] } == expected.channels[channel]
            #expect(same, "channel \(channel)")
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
        let prefix = String(repeating: "s", count: exportNameLimit - "-01-A.m4a".utf8.count)
        let options = ExportOptions(format: .aac(.k128), layout: .stereo, rate: .session)

        let result = try Self.export(package, range: 0..<48_000, options: options, prefix: prefix)

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

    /// C13 old files: the prefix names that the set does not write, and no other name.
    @Test func oldPartFilesAreTheStemNamesThatTheSetDoesNotWrite() throws {
        let package = try Self.package([("A", 0), ("B", 144_000)])
        let targets = exportPartTargets(
            package.session, range: 0..<480_000, by: .chapters,
            options: ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session),
            folder: package.folder.url, prefix: "Ep 12")
        let folder = package.folder.url
        for name in ["Ep 12-05-Outro.mp3", "Ep 12.mp3", "Ep 13-01-A.mp3", "Ep 12-01-A.mp3"] {
            try Data("old".utf8).write(to: folder.appending(path: name))
        }

        let besides = Set(targets.targets.map(\.url.lastPathComponent))

        let old = oldPartFiles(in: folder, prefix: "Ep 12", format: .mp3(.k128), besides: besides)

        #expect(old == [folder.appending(path: "Ep 12-05-Outro.mp3")])
        #expect(try Data(contentsOf: folder.appending(path: "Ep 12-05-Outro.mp3")) == Data("old".utf8))
        // Code gate 1 item 6: the format gives the extension, so an M4A set sees no MP3 file.
        #expect(oldPartFiles(in: folder, prefix: "Ep 12", format: .aac(.k128), besides: []) == [])
        try Data("old".utf8).write(to: folder.appending(path: "Ep 12-02-B.m4a"))
        #expect(
            oldPartFiles(in: folder, prefix: "Ep 12", format: .aac(.k128), besides: [])
                == [folder.appending(path: "Ep 12-02-B.m4a")])
    }
}
