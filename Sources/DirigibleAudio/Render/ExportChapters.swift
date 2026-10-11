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
}

/// The chapters of the M4A chapter track, and the chapters of the range that the file does not have.
struct M4AChapters {
    var chapters: [ExportChapter]
    var dropped: [Marker]
}

/// The M4A chapter list of `range`. It starts from `Session.chapterList(in:)`, converts each start
/// to the output rate, and only then drops each chapter at the start of the chapter before it and
/// each chapter at or after `outputFrames`: two text samples at one time stop the writer (probe
/// P1, plan gate G12). When the first start is after 0, it adds a chapter at 0, because the writer
/// moves a first sample to 0. The added chapter has the episode title, else the show name, else
/// `introTitle`, and the image of the first chapter. `images` holds the JPEG of each marker.
func m4aChapters(
    in session: Session, range: Range<Frames>, outputRate: Int, outputFrames frames: Int, introTitle: String,
    images: [MarkerID: Data]
) -> M4AChapters {
    let list = session.chapterList(in: range)
    var chapters: [ExportChapter] = []
    var dropped = list.dropped
    for marker in list.chapters {
        let start = outputFrames(
            marker.position - range.lowerBound, sessionRate: session.sampleRate, outputRate: outputRate)
        if start >= frames || start == chapters.last?.start {
            dropped.append(marker)
        } else {
            chapters.append(ExportChapter(title: marker.name, start: start, image: images[marker.id]))
        }
    }
    if let first = chapters.first, first.start > 0 {
        let episode = session.episode
        let title = episode.title?.text ?? episode.show?.text ?? introTitle
        chapters.insert(ExportChapter(title: title, start: 0, image: first.image), at: 0)
    }
    return M4AChapters(chapters: chapters, dropped: dropped)
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

/// The JPEG of each chapter image in `names` for an M4A export, read once before any file exists.
/// The writer takes no PNG input (probe P1), so a PNG becomes a JPEG on white: JPEG has no alpha.
/// A file that does not read or decode throws `.artworkMissing(<path>)`.
func readChapterImages(
    _ names: [MarkerID: ArtworkName], package: () throws(SessionFileError) -> URL
) throws(ExportError) -> [MarkerID: Data] {
    guard !names.isEmpty else { return [:] }
    let root: URL
    do { root = try package() } catch { throw .packageUnavailable }
    var images: [MarkerID: Data] = [:]
    for (id, name) in names {
        guard let data = try? Data(contentsOf: root.appending(path: name.path)) else {
            throw .artworkMissing(name.path)
        }
        images[id] = try m4aJPEG(data, of: name)
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
