import AVFoundation
import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DirigibleAudio

/// The artwork import and the artwork in the exports (decision 0045, criteria C4, C5, C6).
struct ArtworkTests {
    let package: MixPackage

    init() throws {
        package = try ExportTests.package([ExportTests.tone(frames: 96_000)])
    }

    var artworkNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: artworkFolderName).path))
            ?? []).sorted()
    }

    func image(_ width: Int, _ height: Int, _ type: UTType = .jpeg) throws -> URL {
        try Self.image(width, height, type, in: package.folder.url)
    }

    /// Writes a one-color image of `width` x `height` pixels in `type` in `folder`.
    static func image(_ width: Int, _ height: Int, _ type: UTType = .jpeg, in folder: URL) throws -> URL {
        let url = folder.appending(path: "\(width)x\(height).\(type.preferredFilenameExtension ?? "img")")
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }

    func refusal(_ source: URL) -> ArtworkError? {
        do throws(ArtworkError) {
            _ = try importArtwork(source, into: package.url)
            return nil
        } catch {
            return error
        }
    }

    @Test func aSquareJPEGIsCopiedIntoArtwork() throws {
        let source = try image(300, 300)
        let name = try importArtwork(source, into: package.url)
        #expect(name.name.hasSuffix(".jpg") && !name.isPNG)
        #expect(try Data(contentsOf: package.url.appending(path: name.path)) == Data(contentsOf: source))
        #expect(artworkNames == [name.name], "no temporary file stays")
    }

    @Test func aSideOf3000Passes() throws {
        let source = try image(3000, 3000, .png)
        #expect(refusal(source) == nil, "the 3000 x 3000 PNG passes")
    }

    @Test func aSideOf3001IsRefused() throws {
        #expect(refusal(try image(3001, 3001)) == .tooLarge(side: 3001), "the 3001 x 3001 JPEG is refused")
    }

    @Test func aNonSquareImageIsRefused() throws {
        #expect(refusal(try image(1400, 1401)) == .notSquare(width: 1400, height: 1401), "1400 x 1401 is refused")
    }

    @Test func aGIFIsRefused() throws {
        #expect(refusal(try image(300, 300, .gif)) == .notJPEGOrPNG(type: "com.compuserve.gif"))
        #expect(artworkNames == [])
    }

    @Test func aFileThatIsNotOnThisMacIsRefused() throws {
        let source = try image(300, 300)
        #expect(throws: ArtworkError.notDownloaded(file: source.lastPathComponent)) {
            try importArtwork(source, into: package.url, isDownloaded: { _ in false })
        }
    }

    /// Undo and the backups keep their image: a second import never replaces the first file.
    @Test func aSecondImportGetsANewNameAndKeepsTheFirst() throws {
        let source = try image(300, 300)
        let first = try importArtwork(source, into: package.url)
        let second = try importArtwork(source, into: package.url)
        #expect(first != second && artworkNames == [first.name, second.name].sorted())
    }

    @Test func aLeftoverTemporaryArtworkIsSwept() throws {
        let name = try importArtwork(try image(300, 300), into: package.url)
        let leftover = package.url.appending(
            path: "\(artworkFolderName)/\(temporaryArtwork(of: ArtworkName(png: true)))")
        try Data("left".utf8).write(to: leftover)
        package.session.removeTemporaryFiles(in: package.url)
        #expect(artworkNames == [name.name])
    }

    func export(_ episode: Episode, _ format: ExportFormat, to url: URL) throws(ExportError) {
        var session = package.session
        session.setEpisode(episode)
        _ = try exportMix(
            session, source: ExportSource(range: 0..<96_000)!,
            options: ExportOptions(format: format, layout: .stereo, rate: .session), to: url,
            package: { package.url })
    }

    @Test func theMP3AndTheM4AHoldTheArtwork() async throws {
        let source = try image(300, 300, .png)
        var episode = Episode()
        episode.artwork = try importArtwork(source, into: package.url)
        let bytes = try Data(contentsOf: source)
        let cases: [(ExportFormat, AVMetadataFormat, String, String)] = [
            (.mp3(.k128), .id3Metadata, "id3/APIC", "mp3"), (.aac(.k128), .iTunesMetadata, "itsk/covr", "m4a"),
        ]
        for (format, metadata, key, suffix) in cases {
            let url = package.folder.url.appending(path: "art.\(suffix)")
            try export(episode, format, to: url)
            let items = try await AVURLAsset(url: url).loadMetadata(for: metadata)
            let item = items.first { $0.identifier?.rawValue == key }
            #expect(try await item?.load(.dataValue) == bytes, "\(key) holds the image: \(items.map(\.identifier))")
        }
    }

    @Test func aMissingArtworkFileThrowsBeforeAnyFile() throws {
        var episode = Episode()
        episode.artwork = ArtworkName(png: false)
        let url = package.folder.url.appending(path: "art.mp3")
        #expect(throws: ExportError.artworkMissing) { try export(episode, .mp3(.k128), to: url) }
        let names = try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path)
        #expect(!names.contains { $0.hasPrefix(".art.mp3") || $0 == "art.mp3" }, "files: \(names)")
    }
}

/// `Studio.setArtwork`: a blocking run with one undo entry (decision 0045, criterion C4).
@MainActor
struct StudioArtworkTests {
    @Test func setArtworkIsOneUndoEntryAndKeepsTheFile() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        let source = try ArtworkTests.image(300, 300, in: fixture.package.folder.url)

        try await studio.setArtwork(from: source)

        let name = try #require(studio.session.episode.artwork)
        #expect(try Data(contentsOf: fixture.url.appending(path: name.path)) == Data(contentsOf: source))
        #expect(try Session(contentsOf: fixture.url).episode.artwork == name, "the run saved the session")
        try studio.undo()
        #expect(studio.session.episode.artwork == nil && !studio.canUndo)
        #expect(FileManager.default.fileExists(atPath: fixture.url.appending(path: name.path).path))
    }

    @Test func aRefusedImageChangesNothing() async throws {
        let fixture = try await ImportStudioFixture.make()
        let studio = try await fixture.open()
        let source = try ArtworkTests.image(300, 301, in: fixture.package.folder.url)
        await #expect(throws: StudioError.artwork(.notSquare(width: 300, height: 301))) {
            try await studio.setArtwork(from: source)
        }
        #expect(studio.session.episode.isEmpty && !studio.canUndo)
    }
}
