import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// ID3 `CHAP` and `CTOC` frames in an MP3 export (run 2026-10-11-chapters-in-file, criteria C4,
/// C4b, C5f, C5g). Each package has a 3 s tone at 48 kHz made in the test.
struct ChapterTagTests {
    /// One frame of a tag: its ID and its body.
    struct Frame {
        let id: String
        let body: [UInt8]
    }

    /// One `CHAP` frame: the element ID, the times in ms, the offsets, and the sub-frames.
    struct Chapter {
        let element: String
        let start: Int
        let end: Int
        let offsets: [UInt8]
        let frames: [Frame]

        var title: String? { frames.first { $0.id == "TIT2" }.map { ChapterTagTests.text($0.body) } }
    }

    let package: MixPackage
    let url: URL

    init() throws {
        package = try ExportTests.package([ExportTests.tone(frames: 144_000)])
        url = package.folder.url.appending(path: "mix.mp3")
    }

    static func int(_ bytes: ArraySlice<UInt8>) -> Int { bytes.reduce(0) { $0 << 8 | Int($1) } }

    /// The frames of a byte run of v2.3 frames.
    static func frames(_ bytes: ArraySlice<UInt8>) -> [Frame] {
        var result: [Frame] = []
        var at = bytes.startIndex
        while at + 10 <= bytes.endIndex, bytes[at] != 0 {
            let size = int(bytes[(at + 4)..<(at + 8)])
            let id = String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
            result.append(Frame(id: id, body: Array(bytes[(at + 10)..<min(bytes.endIndex, at + 10 + size)])))
            at += 10 + size
        }
        return result
    }

    /// The frames of the ID3 tag at the start of `url`, or none.
    static func tag(_ url: URL) throws -> [Frame] {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count > 10, bytes[0..<3] == [0x49, 0x44, 0x33] else { return [] }
        let size = bytes[6..<10].reduce(0) { $0 << 7 | Int($1) }
        return frames(bytes[10..<(10 + size)])
    }

    /// The text of a `TIT2` body in UTF-16 with a BOM.
    static func text(_ body: [UInt8]) -> String {
        let units = stride(from: 3, to: body.count - 1, by: 2).map { UInt16(body[$0]) | UInt16(body[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
    }

    static func chapters(_ frames: [Frame]) -> [Chapter] {
        frames.filter { $0.id == "CHAP" }.map { frame in
            let body = frame.body[...]
            let zero = body.firstIndex(of: 0) ?? body.endIndex
            let at = zero + 1
            return Chapter(
                element: String(decoding: body[..<zero], as: UTF8.self), start: int(body[at..<(at + 4)]),
                end: int(body[(at + 4)..<(at + 8)]), offsets: Array(body[(at + 8)..<(at + 16)]),
                frames: Self.frames(body[(at + 16)...]))
        }
    }

    static func chapter(_ name: String, at position: Frames) -> Marker {
        Marker(id: MarkerID(name.lowercased()), name: name, position: position, kind: .chapter)
    }

    /// Exports the markers and the episode as MP3 of `range`.
    @discardableResult
    func export(
        _ markers: [Marker], episode: Episode = Episode(), range: Range<Frames> = 0..<144_000
    ) throws(ExportError) -> ExportResult {
        var session = package.session
        for marker in markers {
            do { try session.setMarker(marker) } catch { Issue.record("setMarker: \(error)") }
        }
        session.setEpisode(episode)
        return try exportMix(
            session, source: ExportSource(range: range)!, options: MP3ExportTests.mp3(), to: url,
            package: { package.url })
    }

    /// C4. One CTOC with each child in time order, and one CHAP per chapter with its title, its
    /// times in ms, and no byte offsets. The chapter after the range is not in the file.
    @Test func anMP3WithChaptersReadsBackEachTitleAndStart() async throws {
        let plain = package.folder.url.appending(path: "plain.mp3")
        _ = try exportMix(
            package.session, source: ExportSource(range: 0..<144_000)!, options: MP3ExportTests.mp3(), to: plain,
            package: { package.url })
        var episode = Episode()
        episode.title = try EpisodeLine("Ep")
        try export(
            [Self.chapter("One", at: 0), Self.chapter("Two", at: 72_024), Self.chapter("Late", at: 150_000)],
            episode: episode)
        let frames = try Self.tag(url)
        let toc = try #require(frames.first { $0.id == "CTOC" }, "no CTOC")
        let ids: [[UInt8]] = [Array("toc".utf8), [0, 0x03, 2], Array("chp0".utf8), [0], Array("chp1".utf8), [0]]
        let head = ids.flatMap { $0 }
        #expect(Array(toc.body.prefix(head.count)) == head, "CTOC head \(toc.body.prefix(head.count))")
        let tocTitle = Self.frames(toc.body[head.count...]).first { $0.id == "TIT2" }.map { Self.text($0.body) }
        #expect(tocTitle == "Chapters", "CTOC title \(String(describing: tocTitle))")
        let chapters = Self.chapters(frames)
        #expect(chapters.map(\.element) == ["chp0", "chp1"], "elements \(chapters.map(\.element))")
        #expect(chapters.map(\.title) == ["One", "Two"], "titles \(chapters.map(\.title))")
        #expect(chapters.map(\.start) == [0, 1_501] && chapters.map(\.end) == [1_501, 3_000], "times")
        #expect(chapters.allSatisfy { $0.offsets == [UInt8](repeating: 0xFF, count: 8) }, "offsets")
        let frameCounts = (try AVAudioFile(forReading: url).length, try AVAudioFile(forReading: plain).length)
        #expect(frameCounts.0 == frameCounts.1, "frames \(frameCounts.0), with no chapter \(frameCounts.1)")
        #expect(frames.contains { $0.id == "TIT2" }, "the episode frames stay")
        // AVFoundation gives the ID3 chapter titles the locale "und", as for an ffmpeg MP3.
        let groups = try await AVURLAsset(url: url).loadChapterMetadataGroups(
            withTitleLocale: Locale(identifier: "und"), containingItemsWithCommonKeys: [])
        var read: [String] = []
        for group in groups {
            var titles: [String] = []
            for item in group.items { titles.append(try await item.load(.stringValue) ?? "") }
            read.append("\(group.timeRange.start.value)/\(group.timeRange.start.timescale) \(titles)")
        }
        #expect(read == ["0/1000 [\"One\"]", "1501/1000 [\"Two\"]"], "AVFoundation \(read)")
    }

    /// C4. Chapters with an empty episode give a tag with only CTOC and CHAP.
    @Test func chaptersWithNoEpisodeWriteOnlyChapterFrames() throws {
        try export([Self.chapter("One", at: 0)])
        let ids = try Self.tag(url).map(\.id)
        #expect(ids == ["CTOC", "CHAP"], "frames \(ids)")
    }

    /// C4. No chapter and an empty episode: no tag, as before.
    @Test func noChapterAndNoEpisodeWritesNoTag() throws {
        try export([Marker(id: "plain", name: "Plain", position: 0, kind: .marker)])
        #expect(try Self.tag(url).isEmpty, "a tag")
    }

    /// Export Selection: a range from frame N gives a chapter at N + k the start k / rate.
    @Test func exportSelectionShiftsTheChapters() throws {
        try export([Self.chapter("One", at: 48_000), Self.chapter("Two", at: 72_000)], range: 48_000..<144_000)
        let chapters = Self.chapters(try Self.tag(url))
        #expect(chapters.map(\.start) == [0, 500] && chapters.map(\.end) == [500, 2_000], "times")
    }

    /// C4, C5f, C5g. The MP3 gets the core list: no second chapter at one start, and no added
    /// chapter at 0.
    @Test func anMP3GetsTheCoreChapterList() throws {
        let result = try export([
            Self.chapter("A", at: 0), Marker(id: "b", name: "B", position: 72_000, kind: .chapter),
            Marker(id: "c", name: "C", position: 72_000, kind: .chapter),
        ])
        #expect(Self.chapters(try Self.tag(url)).map(\.title) == ["A", "B"], "titles")
        #expect(result.droppedChapters.map(\.id) == ["c"], "dropped \(result.droppedChapters.map(\.id))")
        try FileManager.default.removeItem(at: url)
        var episode = Episode()
        episode.title = try EpisodeLine("Ep")
        try export([Self.chapter("One", at: 48_000), Self.chapter("Two", at: 96_000)], episode: episode)
        let late = Self.chapters(try Self.tag(url))
        #expect(late.map(\.title) == ["One", "Two"] && late.map(\.start) == [1_000, 2_000], "no added chapter")
    }

    /// C4b. 255 chapters pass; 256 throw before any file exists.
    @Test func the255thChapterPassesAndThe256thThrows() throws {
        let markers = (0..<256).map { Self.chapter("C\($0)", at: Frames($0 * 480)) }
        try export(Array(markers.prefix(maximumChapters)))
        #expect(Self.chapters(try Self.tag(url)).count == 255, "chapters")
        try FileManager.default.removeItem(at: url)
        #expect(throws: ExportError.tooManyChapters(256)) { try export(markers) }
        try MP3ExportTests.expectNoOutput(package)
    }

    /// C4b. The header size has 28 bits: a body of `maximumTagSize` passes, one byte more throws.
    @Test func aTagOverTheLimitThrows() throws {
        #expect(try tagHeaderSize(maximumTagSize) == [0x7F, 0x7F, 0x7F, 0x7F])
        #expect(throws: ExportError.tagTooLarge) { try tagHeaderSize(maximumTagSize + 1) }
    }
}
