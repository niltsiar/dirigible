import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The iTunes metadata pass of an M4A export (decision 0045, criterion C6): the atoms, the
/// cancel, the flush before the move, and the sweep of `.tag.tmp` files.
struct M4ATagTests {
    let package: MixPackage
    let url: URL
    let source = ExportSource(range: 0..<96_000)!
    let options = ExportOptions(format: .aac(.k128), layout: .stereo, rate: .session)

    init() throws {
        package = try ExportTests.package([ExportTests.tone(frames: 96_000)])
        url = package.folder.url.appending(path: "mix.m4a")
    }

    func session(_ episode: Episode) -> Session {
        var session = package.session
        session.setEpisode(episode)
        return session
    }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).filter { $0.hasSuffix(".tmp") }
    }

    /// The flush calls of an export, in order, with the target state at each call.
    final class Flushes {
        var calls: [(path: String, targetExists: Bool)] = []
    }

    func export(
        _ episode: Episode, to target: URL? = nil, replacing: ConfirmedFile? = nil, flushes: Flushes = Flushes(),
        progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }
    ) throws(ExportError) {
        let target = target ?? url
        _ = try exportMix(
            session(episode), source: source, options: options, to: target, replacing: replacing,
            package: { package.url }, progress: progress, isCancelled: isCancelled,
            flush: { path in
                flushes.calls.append((path, FileManager.default.fileExists(atPath: target.path)))
                return fullFlush(path: path)
            })
    }

    /// The iTunes atoms that AVFoundation reads, by identifier.
    static func atoms(_ url: URL) async throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try await AVURLAsset(url: url).loadMetadata(for: .iTunesMetadata) {
            let value = try await item.load(.value)
            result[item.identifier?.rawValue ?? "?"] =
                if let data = value as? Data { "data:\(data.count)" } else {
                    value.map { "\($0)" } ?? "nil"
                }
        }
        return result
    }

    @Test func aTaggedM4AReadsBackEveryAtom() async throws {
        let episode = try ID3TagTests.fullEpisode()
        let plain = package.folder.url.appending(path: "plain.m4a")
        try export(Episode(), to: plain)
        try export(episode)

        let atoms = try await Self.atoms(url)
        let expected = [
            "itsk/%A9nam": "Episodio 12: Café ñandú", "itsk/%A9alb": "The Show", "itsk/%A9ART": "Ana Pérez",
            "itsk/aART": "Ana Pérez", "itsk/tves": "12", "itsk/tvsn": "3", "itsk/%A9day": "2026-10-09",
            "itsk/%A9gen": "Podcast", "itsk/cprt": "© 2026 Ana", "itsk/rtng": "1", "itsk/desc": "Short description",
            "itsk/ldes": episode.notes!.text, "itsk/purl": "https://example.com/feed.xml", "itsk/pcst": "1",
            "itsk/egid": "urn:uuid:1234",
        ]
        for (identifier, value) in expected {
            #expect(atoms[identifier] == value, "\(identifier) reads \(atoms[identifier] ?? "nothing")")
        }
        let gapless = "itlk/com.apple.iTunes.iTunSMPB"
        let plainAtoms = try await Self.atoms(plain)
        #expect(atoms[gapless] != nil && atoms[gapless] == plainAtoms[gapless], "iTunSMPB changed")
        let lengths = (try AVAudioFile(forReading: url).length, try AVAudioFile(forReading: plain).length)
        #expect(lengths.0 == lengths.1, "tagged \(lengths.0) frames, plain \(lengths.1)")
        #expect(try temporaryFiles() == [])
    }

    @Test func anEmptyEpisodeSkipsTheTagPass() async throws {
        let flushes = Flushes()
        try export(Episode(), flushes: flushes)
        let paths = flushes.calls.map(\.path)
        #expect(paths.count == 2 && paths[0].hasSuffix(".tmp") && !paths[0].hasSuffix(".tag.tmp"), "flushes: \(paths)")
        #expect(try await Self.atoms(url)["itsk/%A9nam"] == nil, "an empty episode wrote a title")
    }

    /// The flush of the moved file comes after the tag pass and before the move.
    @Test func theTaggedFileIsFlushedBeforeTheMove() throws {
        let flushes = Flushes()
        try export(try ID3TagTests.fullEpisode(), flushes: flushes)
        let calls = flushes.calls
        let tagged = calls.first { $0.path.hasSuffix(".tag.tmp") }
        #expect(tagged?.targetExists == false, "no flush of the tagged file before the move: \(calls.map(\.path))")
        #expect(calls.last?.path == package.folder.url.path, "the folder flush is last")
    }

    /// The cancel turns true in the tag pass: the first cancel read after the encode is the check
    /// before the pass, the second is the read of the pass.
    @Test func aCancelInTheTagPassLeavesTheOldFile() throws {
        try Data("old".utf8).write(to: url)
        var (encoded, reads, sawEnd) = (false, 0, false)
        let episode = try ID3TagTests.fullEpisode()
        #expect(throws: ExportError.cancelled) {
            try export(
                episode, replacing: ConfirmedFile(at: url),
                progress: { value in
                    if value >= 0.95 { encoded = true }
                    if value == 1 { sawEnd = true }
                },
                isCancelled: {
                    if encoded { reads += 1 }
                    return reads >= 2
                })
        }
        #expect(!sawEnd, "the pass ended before the cancel")
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try temporaryFiles() == [])
    }

    /// The M4A copy of `aCancelAfterTheLastChunkLeavesNoFile`: a cancel after the pass ends throws
    /// before the flush and the move.
    @Test func aCancelAfterTheTagPassLeavesNoFile() throws {
        try Data("old".utf8).write(to: url)
        var cancelled = false
        let flushes = Flushes()
        let episode = try ID3TagTests.fullEpisode()
        #expect(throws: ExportError.cancelled) {
            try export(
                episode, replacing: ConfirmedFile(at: url), flushes: flushes,
                progress: { value in if value == 1 { cancelled = true } }, isCancelled: { cancelled })
        }
        #expect(flushes.calls.isEmpty, "a flush ran after the cancel")
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try temporaryFiles() == [])
    }

    /// The live case: a second export keeps the `.tag.tmp` file of an export that holds its
    /// locked `.tmp` file.
    @Test func twoExportsToOneTargetKeepTheirTagFiles() throws {
        let uuid = UUID().uuidString
        let live = package.folder.url.appending(path: ".mix.m4a.\(uuid).tmp")
        let liveTag = package.folder.url.appending(path: ".mix.m4a.\(uuid).tag.tmp")
        let held = open(live.path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC, 0o644)
        try #require(held >= 0)
        defer { close(held) }
        try Data("tag".utf8).write(to: liveTag)

        try export(try ID3TagTests.fullEpisode())

        #expect(try temporaryFiles().sorted() == [live.lastPathComponent, liveTag.lastPathComponent].sorted())
    }

    /// A dead `.tmp` file (no lock) and its `.tag.tmp` file both go.
    @Test func aLeftoverTagFileBesideADeadTmpIsSwept() throws {
        let uuid = UUID().uuidString
        for name in [".mix.m4a.\(uuid).tmp", ".mix.m4a.\(uuid).tag.tmp", ".mix.m4a.\(UUID().uuidString).tag.tmp"] {
            try Data("left".utf8).write(to: package.folder.url.appending(path: name))
        }
        try export(Episode())
        #expect(try temporaryFiles() == [])
    }
}
