import CoreGraphics
import DirigibleCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A chapter of the M4A chapter track: its start in output frames from the range start, and its
/// image as a JPEG. Nil shows the episode artwork (decision 0045, run 5).
struct ExportChapter: Hashable, Sendable {
    var title: String
    var start: Int
    var image: Data?
    /// The link of the chapter, in the `href` box of its title sample.
    var url: String?
}

/// The chapters of the M4A chapter track, and the chapters of the range that the file does not have.
struct M4AChapters {
    var chapters: [ExportChapter]
    var dropped: [Marker]
}

/// The M4A chapter list of `range`. It starts from `list`, the `Session.chapterList(in: range)` of
/// the caller, converts each start to the output rate, and only then drops each chapter at the start of the chapter before it and
/// each chapter at or after `outputFrames`: two text samples at one time stop the writer (probe
/// P1, plan gate G12). When the first start is after 0, it adds a chapter at 0, because the writer
/// moves a first sample to 0. The added chapter has the episode title, else the show name, else
/// `introTitle`, and the image of the first chapter. `images` holds the JPEG of each marker.
func m4aChapters(
    _ list: ChapterList, in session: Session, range: Range<Frames>, outputRate: Int, outputFrames frames: Int,
    introTitle: String, images: [MarkerID: Data]
) -> M4AChapters {
    var chapters: [ExportChapter] = []
    var dropped = list.dropped
    for marker in list.chapters {
        let start = outputFrames(
            marker.position - range.lowerBound, sessionRate: session.sampleRate, outputRate: outputRate)
        if start >= frames || start == chapters.last?.start {
            dropped.append(marker)
        } else {
            chapters.append(
                ExportChapter(title: marker.name, start: start, image: images[marker.id], url: marker.url?.text))
        }
    }
    if let first = chapters.first, first.start > 0 {
        let episode = session.episode
        let title = episode.title?.text ?? episode.show?.text ?? introTitle
        chapters.insert(ExportChapter(title: title, start: 0, image: first.image), at: 0)
    }
    return M4AChapters(chapters: chapters, dropped: dropped)
}

/// The chapters of `list` that the M4A keeps, so the export reads only their images before any file
/// exists (code gate item E7). The frame count of the encode is not known yet, so the list uses the
/// range at the output rate: no chapter of the range starts at or after it, so the list drops only a
/// chapter at the output frame of the chapter before it. The call after the encode stays the rule.
func m4aKept(_ list: ChapterList, in session: Session, range: Range<Frames>, outputRate: Int) -> [Marker] {
    let frames = outputFrames(
        range.upperBound - range.lowerBound, sessionRate: session.sampleRate, outputRate: outputRate)
    let dropped = Set(
        m4aChapters(
            list, in: session, range: range, outputRate: outputRate, outputFrames: frames, introTitle: "", images: [:]
        ).dropped.map(\.id))
    return list.chapters.filter { !dropped.contains($0.id) }
}

/// `offset` session frames at the output rate, rounded half up with integer math (plan gate G1).
func outputFrames(_ offset: Frames, sessionRate: Int, outputRate: Int) -> Int {
    (2 * offset.count * outputRate + sessionRate) / (2 * sessionRate)
}

/// The samples of the M4A image track, each to the start of the next one (criterion C5b). A chapter
/// with no image gets `artwork`, and one artwork sample spans each run of such chapters. No sample
/// when no chapter has an image. No sample and `omitted` when a chapter has no image and there is
/// no artwork: a gap would show the image of the chapter before it (probe P1, U8).
func imageSamples(_ chapters: [ExportChapter], artwork: Data?) -> (samples: [(start: Int, jpeg: Data)], omitted: Bool) {
    guard chapters.contains(where: { $0.image != nil }) else { return ([], false) }
    var samples: [(start: Int, jpeg: Data)] = []
    for (index, chapter) in chapters.enumerated() {
        guard let jpeg = chapter.image ?? artwork else { return ([], true) }
        if chapter.image == nil, index > 0, chapters[index - 1].image == nil { continue }
        samples.append((chapter.start, jpeg))
    }
    return (samples, false)
}

/// The bytes of the image of each chapter in `chapters` that has one, read once before any file
/// exists. A file that does not read throws `.chapterImageMissing` with `rate`, the session rate.
/// It reads `isCancelled()` before each image, so a take start does not wait for the reads.
func readChapterImages(
    _ chapters: [Marker], rate: Int, package: () throws(SessionFileError) -> URL, isCancelled: () -> Bool
) throws(ExportError) -> [MarkerID: Data] {
    guard chapters.contains(where: { $0.image != nil }) else { return [:] }
    let root: URL
    do { root = try package() } catch { throw .packageUnavailable }
    var images: [MarkerID: Data] = [:]
    for marker in chapters {
        guard let name = marker.image else { continue }
        if isCancelled() { throw .cancelled }
        guard let data = try? Data(contentsOf: root.appending(path: name.path)) else {
            throw .chapterImageMissing(marker, rate: rate)
        }
        images[marker.id] = data
    }
    return images
}

/// `data` as a JPEG for the M4A image track: a JPEG stays, and a PNG is drawn on white and encoded.
func m4aJPEG(_ data: Data, of name: ArtworkName) throws(ExportError) -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw .artworkMissing(name.path) }
    guard name.isPNG else { return data }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let output = NSMutableData()
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw .artworkMissing(name.path) }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(rect)
    context.draw(image, in: rect)
    guard let flat = context.makeImage() else { throw .artworkMissing(name.path) }
    CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw .artworkMissing(name.path) }
    return output as Data
}

/// The form of a chapters file: Podcasting 2.0 JSON Chapters 1.2.0, or a text list.
public enum ChaptersForm: Sendable {
    case json, text

    /// The form of a file name that ends in `.json` or `.txt`, with no case.
    public init?(of url: URL) {
        switch url.pathExtension.lowercased() {
        case "json": self = .json
        case "txt": self = .text
        default: return nil
        }
    }
}

/// Writes the chapters file of `range` to `url` in `form`. The JSON (`Session.chaptersJSON`) goes
/// after each chapter image beside it (`Session.chapterImages`) with the bytes of `Artwork/` in
/// `package`, each with an atomic write (run 2026-10-11-chapters-in-file, C3, C3b). The text list
/// (`Session.chaptersText`) has no image. The caller checks the file target. Before any write, an
/// item at the name of an image throws `.chapterImageExists(<path>)` when `replacingImages` is
/// false, and an image that does not read throws `.chapterImageMissing`. Pass `replacingImages`
/// true when the user confirmed the replace of the JSON: the images belong to it.
public func writeChapters(
    _ session: Session, in range: Range<Frames>, to url: URL, form: ChaptersForm, replacingImages: Bool,
    package: URL
) throws(ExportError) {
    guard form == .json else {
        do { try Data(session.chaptersText(in: range).utf8).write(to: url, options: .atomic) } catch {
            throw ExportError(writing: error)
        }
        return
    }
    let (folder, stem) = (url.deletingLastPathComponent(), url.deletingPathExtension().lastPathComponent)
    var copies: [(data: Data, target: URL)] = []
    for (chapter, image, name) in session.chapterImages(in: range, imageStem: stem) {
        let target = folder.appending(path: name)
        // An lstat: a dangling link is an item too.
        guard replacingImages || ConfirmedFile(at: target) == nil else { throw .chapterImageExists(target.path) }
        guard let data = try? Data(contentsOf: package.appending(path: image.path)) else {
            throw .chapterImageMissing(chapter, rate: session.sampleRate)
        }
        copies.append((data, target))
    }
    do {
        let json = try session.chaptersJSON(in: range, imageStem: stem)
        for copy in copies { try copy.data.write(to: copy.target, options: .atomic) }
        try json.write(to: url, options: .atomic)
    } catch {
        throw ExportError(writing: error)
    }
}
