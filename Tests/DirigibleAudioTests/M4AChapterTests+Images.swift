import AVFoundation
import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import os

@testable import DirigibleAudio

/// The chapter images and the cancel of the M4A chapter copy (criteria C5b, C5d, C5e).
extension M4AChapterTests {
    /// The image samples of the video track.
    static func imageSamples(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let buffer = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(buffer) }
        return count
    }

    /// The RGBA bytes of the center pixel of an image, and its size.
    static func centerPixel(_ data: Data) throws -> (pixel: [UInt8], width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (pixel, image.width, image.height)
    }

    /// C5b. JPEG images of two sizes, byte-equal to the files.
    @Test func anImageTrackHoldsEachChapterImage() async throws {
        let (small, large) = (try artwork(300), try artwork(600, red: 0.9))
        let result = try await export(
            [Self.chapter("One", at: 0), Self.chapter("Two", at: 66_150)], images: ["one": small, "two": large])
        let groups = try await Self.groups(url)
        #expect(groups.map(\.title) == ["One", "Two"], "titles \(groups.map(\.title))")
        #expect(
            groups.map(\.artwork) == [try bytes(small), try bytes(large)], "the group images differ from the files")
        #expect(groups.first?.artworkType == "com.apple.metadata.datatype.JPEG")
        #expect(!result.chapterImagesOmitted)
    }

    /// C5e. The writer refuses a PNG input, so the copy makes a JPEG; the PNG in `Artwork/` stays.
    @Test func aPNGChapterImageBecomesAJPEGSample() async throws {
        let png = try artwork(600, .png)
        let before = try bytes(png)
        try await export([Self.chapter("One", at: 0)], images: ["one": png])
        let group = try #require(try await Self.groups(url).first)
        let data = try #require(group.artwork, "the group has no artwork")
        #expect(group.artworkType == "com.apple.metadata.datatype.JPEG", "type \(group.artworkType ?? "none")")
        #expect(data.prefix(3) == Data([0xFF, 0xD8, 0xFF]), "the artwork starts with \(Array(data.prefix(4)))")
        let size = try Self.centerPixel(data)
        #expect(size.width == 600 && size.height == 600, "size \(size.width) x \(size.height)")
        #expect(try bytes(png) == before, "the PNG in Artwork/ changed")
    }

    /// C5e. JPEG has no alpha: the step draws on white first.
    @Test func aTransparentPNGPixelBecomesWhite() async throws {
        let png = try artwork(64, .png, alpha: 0)
        try await export([Self.chapter("One", at: 0)], images: ["one": png])
        let data = try #require(try await Self.groups(url).first?.artwork, "the group has no artwork")
        let pixel = try Self.centerPixel(data).pixel
        #expect(pixel.prefix(3).allSatisfy { $0 >= 250 }, "the transparent pixel decodes as \(pixel)")
    }

    /// C5e, code gate item D2. A PNG that ImageIO cannot decode throws before any file exists, and
    /// the error names the chapter.
    @Test func anUnreadablePNGThrowsBeforeAnyFile() async throws {
        let png = ArtworkName(png: true)
        let folder = package.url.appending(path: artworkFolderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a png".utf8).write(to: folder.appending(path: png.name))
        let before = try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).sorted()
        let chapter = Marker(id: "one", name: "One", position: 0, kind: .chapter, image: png)
        await #expect(throws: ExportError.chapterImageMissing(chapter, rate: package.session.sampleRate)) {
            try await export([Self.chapter("One", at: 0)], images: ["one": png])
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).sorted()
        #expect(after == before, "the export made \(Set(after).subtracting(before))")
    }

    /// C5b, U8. A chapter with no image shows the episode artwork, not the image before it.
    @Test func aChapterWithNoImageGetsTheEpisodeArtwork() async throws {
        var episode = Episode()
        episode.artwork = try artwork(300, red: 0.9)
        let image = try artwork(300)
        try await export(
            [Self.chapter("One", at: 0), Self.chapter("Two", at: 66_150)], episode: episode, images: ["one": image])
        let groups = try await Self.groups(url)
        #expect(groups.map(\.artwork) == [try bytes(image), try bytes(episode.artwork!)], "the group images")
    }

    /// C5b, G4, C5e. One artwork sample spans the run "Two", "Three"; a PNG episode artwork becomes a JPEG.
    @Test func aRunOfChaptersWithNoImageIsOneSample() async throws {
        var episode = Episode()
        episode.artwork = try artwork(300, .png)
        try await export(
            [Self.chapter("One", at: 0), Self.chapter("Two", at: 44_100), Self.chapter("Three", at: 88_200)],
            episode: episode, images: ["one": try artwork(300)])
        #expect(try await Self.imageSamples(url) == 2, "image samples")
        let groups = try await Self.groups(url)
        #expect(groups.dropFirst().allSatisfy { $0.artworkType == "com.apple.metadata.datatype.JPEG" }, "types")
    }

    /// C5b. No episode artwork: no image track, each title, and the flag.
    @Test func noEpisodeArtworkMeansNoImageTrack() async throws {
        let result = try await export(
            [Self.chapter("One", at: 0), Self.chapter("Two", at: 66_150)], images: ["one": try artwork(300)])
        #expect(try await Self.videoTracks(url) == 0, "a video track")
        #expect(try await Self.groups(url).map(\.title) == ["One", "Two"], "titles")
        #expect(result.chapterImagesOmitted, "chapterImagesOmitted is false")
    }

    /// C5d. Read 1 after the encode is the check before the copy; reads 2 to 5 are the chapter
    /// samples (two titles, two images); read 6 and later are in the audio loop or the finish wait.
    @Test(arguments: [2, 5, 6, 7])
    func aCancelInTheChapterCopyLeavesTheOldFile(cancelAt: Int) async throws {
        try Data("old".utf8).write(to: url)
        let state = OSAllocatedUnfairLock(initialState: (encoded: false, reads: 0, sawEnd: false))
        var episode = Episode()
        episode.artwork = try artwork(300, red: 0.9)
        let image = try artwork(300)
        await #expect(throws: ExportError.cancelled) {
            try await export(
                [Self.chapter("One", at: 0), Self.chapter("Two", at: 66_150)], episode: episode,
                images: ["one": image], replacing: ConfirmedFile(at: url),
                progress: { value in
                    state.withLock {
                        if value >= 0.95 { $0.encoded = true }
                        if value == 1 { $0.sawEnd = true }
                    }
                },
                isCancelled: {
                    state.withLock {
                        if $0.encoded { $0.reads += 1 }
                        return $0.reads >= cancelAt
                    }
                })
        }
        #expect(!state.withLock { $0.sawEnd }, "the copy ended before the cancel")
        #expect(state.withLock { $0.reads } == cancelAt, "the copy read the cancel again after it was true")
        #expect(try Data(contentsOf: url) == Data("old".utf8), "the old target changed")
        #expect(try temporaryFiles() == [], "temporary files stay")
    }

    /// C5d. A cancel after the copy ends throws before the flush and the move.
    @Test func aCancelAfterTheChapterCopyLeavesNoFile() async throws {
        try Data("old".utf8).write(to: url)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        await #expect(throws: ExportError.cancelled) {
            try await export(
                [Self.chapter("One", at: 0)], replacing: ConfirmedFile(at: url),
                progress: { value in if value == 1 { cancelled.withLock { $0 = true } } },
                isCancelled: { cancelled.withLock { $0 } })
        }
        #expect(try Data(contentsOf: url) == Data("old".utf8), "the old target changed")
        #expect(try temporaryFiles() == [], "temporary files stay")
    }

    /// Run 2026-10-11-chapters-in-file slice 4, C5b: the image of the marker in the session goes
    /// into the image track.
    @Test func aChapterImageFromTheMarkerIsInTheImageTrack() async throws {
        let image = try artwork(300)
        try await export([Marker(id: "one", name: "One", position: 0, kind: .chapter, image: image)])
        let groups = try await Self.groups(url)
        let same = groups.first?.artwork == (try bytes(image))
        #expect(groups.count == 1 && same, "the group artwork is not the marker image")
    }

    /// C5c. The URL of a chapter reads back as the HREF attribute of its title item.
    @Test func aChapterURLReadsBackAsHREF() async throws {
        try await export([
            Marker(
                id: "one", name: "One", position: 0, kind: .chapter, url: try WebURL("https://example.com/one")),
            Self.chapter("Two", at: 66_150),
        ])
        var links: [String?] = []
        for group in try await AVURLAsset(url: url).loadChapterMetadataGroups(
            withTitleLocale: Locale(identifier: "en"), containingItemsWithCommonKeys: [])
        {
            let title = group.items.first { $0.commonKey == .commonKeyTitle }
            let attributes = try await title?.load(.extraAttributes)
            links.append(attributes?[AVMetadataExtraAttributeKey(rawValue: "HREF")] as? String)
        }
        #expect(links == ["https://example.com/one", nil], "links \(links)")
    }

    /// C5c. A URL of 255 bytes gets its `href` box; one of 256 bytes gets none, and the writer does
    /// not trap. `setMarker` refuses such a URL, so the test calls the sample function.
    @Test func aURLOver255BytesGetsNoHrefBox() throws {
        let head = "https://example.com/"
        let url255 = head + String(repeating: "a", count: 255 - head.utf8.count)
        let url256 = url255 + "a"
        let title = Data([0, 1]) + Data("T".utf8)
        let box = Data([0, 0, 1, 13]) + Data("href".utf8) + Data([0, 0, 0, 1, 255]) + Data(url255.utf8) + Data([0])
        let with255 = textSample("T", url: url255) == title + box
        #expect(with255, "the 255-byte URL has no href box of the 3GPP layout")
        #expect(textSample("T", url: url256) == title, "a 256-byte URL has an href box")
    }
}
