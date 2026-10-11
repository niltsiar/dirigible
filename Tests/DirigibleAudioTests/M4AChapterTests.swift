import AVFoundation
import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DirigibleAudio

/// The chapter track and the chapter images of an M4A export (run 2026-10-11-chapters-in-file,
/// criteria C5 to C5h). Each package has a 3 s tone made in the test.
struct M4AChapterTests {
    /// One chapter group that AVFoundation reads. `start` is "value/timescale".
    struct Group {
        let title: String?
        let start: String
        let end: CMTime
        let artwork: Data?
        let artworkType: String?
    }

    let package: MixPackage
    let url: URL

    init() throws {
        package = try Self.package(rate: 44_100)
        url = package.folder.url.appending(path: "mix.m4a")
    }

    static func package(rate: Int) throws -> MixPackage {
        try ExportTests.package([ExportTests.tone(frames: 3 * rate, rate: Double(rate))], rate: rate)
    }

    static let aac = ExportOptions(format: .aac(.k128), layout: .stereo, rate: .session)

    static func chapter(_ name: String, at position: Frames) -> Marker {
        Marker(id: MarkerID(name.lowercased()), name: name, position: position, kind: .chapter)
    }

    /// Exports the markers and the episode with the package as AAC of the whole session. `images`
    /// gives the marker of each ID its image. The export runs on a GCD
    /// thread, as `Studio` runs it: the writer of the chapter copy does not finish while each
    /// thread of the Swift concurrency pool waits (tests in parallel).
    @discardableResult
    func export(
        _ markers: [Marker], episode: Episode = Episode(), package: MixPackage? = nil, from start: Frames = 0,
        options: ExportOptions = aac, images: [MarkerID: ArtworkName] = [:], to target: URL? = nil,
        replacing: ConfirmedFile? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws(ExportError) -> ExportResult {
        let folder = (package ?? self.package).url
        var session = (package ?? self.package).session
        for var marker in markers {
            marker.image = images[marker.id] ?? marker.image
            do { try session.setMarker(marker) } catch { Issue.record("setMarker: \(error)") }
        }
        session.setEpisode(episode)
        let (target, sessionCopy) = (target ?? url, session)
        let result = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: Result { () throws(ExportError) in
                        try exportMix(
                            sessionCopy, source: ExportSource(range: start..<sessionCopy.end)!, options: options,
                            to: target,
                            replacing: replacing, package: { folder }, progress: progress, isCancelled: isCancelled)
                    })
            }
        }
        return try result.get()
    }

    static func groups(_ url: URL) async throws -> [Group] {
        var result: [Group] = []
        for group in try await AVURLAsset(url: url).loadChapterMetadataGroups(
            withTitleLocale: Locale(identifier: "en"), containingItemsWithCommonKeys: [.commonKeyArtwork])
        {
            var (title, artwork, type): (String?, Data?, String?) = (nil, nil, nil)
            for item in group.items {
                if item.commonKey == .commonKeyArtwork {
                    artwork = try await item.load(.dataValue)
                    type = item.dataType
                } else if item.commonKey == .commonKeyTitle {
                    title = try await item.load(.stringValue)
                }
            }
            let start = group.timeRange.start
            result.append(
                Group(
                    title: title, start: "\(start.value)/\(start.timescale)", end: group.timeRange.end,
                    artwork: artwork,
                    artworkType: type))
        }
        return result
    }

    /// The frames that a player decodes: an LPCM read with `AVAssetReader`.
    static func decodedFrames(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        reader.startReading()
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        return frames
    }

    static func videoTracks(_ url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .video).count
    }

    /// Writes a square image of `size` px in `Artwork/` of the package and gives its name. The color
    /// has the alpha `alpha`; a PNG keeps it.
    func artwork(_ size: Int, _ type: UTType = .jpeg, red: CGFloat = 0.2, alpha: CGFloat = 1) throws -> ArtworkName {
        let name = ArtworkName(png: type == .png)
        let folder = package.url.appending(path: artworkFolderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = type == .png ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue))
        context.setFillColor(red: red, green: 0.4, blue: 0.8, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                folder.appending(path: name.name) as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return name
    }

    func bytes(_ name: ArtworkName) throws -> Data { try Data(contentsOf: package.url.appending(path: name.path)) }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).filter { $0.hasSuffix(".tmp") }
    }

    /// C5, C5h. The chapter after the range is not in the file.
    @Test func anM4AWithChaptersReadsBackEachTitleAndStart() async throws {
        let plain = package.folder.url.appending(path: "plain.m4a")
        try await export([], to: plain)
        let result = try await export([Self.chapter("One", at: 0), Self.chapter("Two", at: 66_200)])
        let groups = try await Self.groups(url)
        #expect(groups.map(\.title) == ["One", "Two"], "titles \(groups.map(\.title))")
        #expect(groups.map(\.start) == ["0/1", "66200/44100"], "starts \(groups.map(\.start))")
        #expect(try AVAudioFile(forReading: url).length == 132_300, "AVAudioFile length")
        #expect(try await Self.decodedFrames(url) == 132_300, "decoded frames")
        #expect(try await Self.decodedFrames(plain) == 132_300, "decoded frames of the export with no chapter")
        let audio = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let range = try await audio.load(.timeRange)
        #expect(range.duration == CMTime(value: 132_300, timescale: 44_100), "audio track time range \(range.duration)")
        let gapless = "itlk/com.apple.iTunes.iTunSMPB"
        let (atoms, plainAtoms) = (try await M4ATagTests.atoms(url), try await M4ATagTests.atoms(plain))
        #expect(atoms[gapless] != nil && atoms[gapless] == plainAtoms[gapless], "iTunSMPB changed")
        #expect(try await Self.videoTracks(url) == 0, "no chapter image: no video track")
        #expect(!result.chapterImagesOmitted && result.droppedChapters.isEmpty)
        #expect(try temporaryFiles() == [])
    }

    /// G16. Chapters with an empty episode get the atoms of the export with no chapter: only the
    /// encoder atoms.
    @Test func chaptersWithAnEmptyEpisodeKeepTheEncoderAtoms() async throws {
        let plain = package.folder.url.appending(path: "plain.m4a")
        try await export([], to: plain)
        try await export([Self.chapter("One", at: 0)])
        let (atoms, plainAtoms) = (try await M4ATagTests.atoms(url), try await M4ATagTests.atoms(plain))
        #expect(atoms == plainAtoms, "atoms \(atoms.keys.sorted()), plain \(plainAtoms.keys.sorted())")
        #expect(try await Self.groups(url).map(\.title) == ["One"], "the chapter track")
    }

    /// C5, C5h, G1. A 48 kHz session at 44.1 kHz: each start converts to the output rate, half up.
    @Test func a48kHzSessionAt44100ReadsEachChapterAtTheOutputRate() async throws {
        let package48 = try Self.package(rate: 48_000)
        var options = Self.aac
        options.rate = .hz44100
        let plain = package48.folder.url.appending(path: "plain.m4a")
        let target = package48.folder.url.appending(path: "mix.m4a")
        try await export([], package: package48, options: options, to: plain)
        try await export(
            [Self.chapter("One", at: 72_000), Self.chapter("Two", at: 120_003)], package: package48, options: options,
            to: target)
        let groups = try await Self.groups(target)
        #expect(groups.map(\.start) == ["0/1", "66150/44100", "110253/44100"], "starts \(groups.map(\.start))")
        let duration = try await AVURLAsset(url: target).load(.duration)
        #expect(groups.last?.end == duration, "the last group ends at \(String(describing: groups.last?.end))")
        let frames = (try await Self.decodedFrames(target), try await Self.decodedFrames(plain))
        #expect(frames.0 == frames.1, "decoded \(frames.0), with no chapter \(frames.1)")
    }

    /// C5, G12. Offsets 215 and 216 are both frame 198 at 44.1 kHz: the second leaves the file.
    @Test func twoStartsAtOneOutputFrameWriteOneGroup() async throws {
        let package48 = try Self.package(rate: 48_000)
        var options = Self.aac
        options.rate = .hz44100
        let target = package48.folder.url.appending(path: "mix.m4a")
        let result = try await export(
            [Self.chapter("A", at: 0), Self.chapter("B", at: 215), Self.chapter("C", at: 216)], package: package48,
            options: options, to: target)
        #expect(try await Self.groups(target).map(\.title) == ["A", "B"], "two groups")
        #expect(result.droppedChapters.map(\.id) == ["c"], "dropped \(result.droppedChapters.map(\.id))")
    }

    /// C5f. Two chapters at one time stop the writer; the list keeps the first.
    @Test func twoChaptersAtOneTimeWriteAFile() async throws {
        let result = try await export([
            Self.chapter("A", at: 0), Marker(id: "b", name: "B", position: 66_150, kind: .chapter),
            Marker(id: "c", name: "C", position: 66_150, kind: .chapter),
        ])
        #expect(try await Self.groups(url).map(\.title) == ["A", "B"], "titles")
        #expect(try await Self.decodedFrames(url) == 132_300, "decoded frames")
        #expect(result.droppedChapters.map(\.id) == ["c"], "dropped \(result.droppedChapters.map(\.id))")
    }

    /// C5g. With no sample from 0 the writer moves the first chapter to 0, so the copy adds one.
    @Test func aLateFirstChapterReadsBackAtItsStart() async throws {
        var episode = Episode()
        episode.title = try EpisodeLine("Ep")
        let image = try artwork(300)
        try await export(
            [Self.chapter("One", at: 44_100), Self.chapter("Two", at: 88_200)], episode: episode,
            images: ["one": image, "two": try artwork(300, red: 0.9)])
        let groups = try await Self.groups(url)
        #expect(groups.map(\.title) == ["Ep", "One", "Two"], "titles \(groups.map(\.title))")
        #expect(groups.map(\.start) == ["0/1", "44100/44100", "88200/44100"], "starts \(groups.map(\.start))")
        #expect(groups.first?.artwork == (try bytes(image)), "the added chapter shows the image of One")
    }

    /// Export Selection: a range from frame N gives a chapter at N + k the start k / rate.
    @Test func exportSelectionShiftsTheChapters() async throws {
        try await export([Self.chapter("One", at: 44_100), Self.chapter("Two", at: 66_200)], from: 44_100)
        let groups = try await Self.groups(url)
        #expect(groups.map(\.start) == ["0/1", "22100/44100"], "starts \(groups.map(\.start))")
    }

    /// C5c. The 16-bit sample length counts UTF-8 bytes: 40000 "é" are 80000 bytes, cut to 32767.
    @Test func aLongTitleIsCutAtACharacterBoundary() async throws {
        let marker = Marker(id: "long", name: String(repeating: "é", count: 40_000), position: 0, kind: .chapter)
        do { try await export([marker]) } catch { Issue.record("title of a failed export: \(error)") }
        let title = try? await Self.groups(url).first?.title
        let cut = title == String(repeating: "é", count: 32_767)
        #expect(cut, "title of \(title?.count ?? 0) characters, last \(String(describing: title?.last))")
    }
}
