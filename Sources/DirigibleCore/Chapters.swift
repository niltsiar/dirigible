import Foundation

extension Session {
    /// The chapter markers in `range`, by position, then by ID (as the session file).
    public func chapters(in range: Range<Frames>) -> [Marker] {
        sortedMarkers.filter { $0.kind == .chapter && range.contains($0.position) }
    }

    /// The chapters of `range` that go into a file (MP3, M4A, chapters.json), and the chapters
    /// that it drops. A chapter that starts at the millisecond of the chapter before it is dropped:
    /// two chapters at one time stop the M4A writer (probe P1 of run 2026-10-11-chapters-in-file).
    public func chapterList(in range: Range<Frames>) -> ChapterList {
        var kept: [Marker] = []
        var dropped: [Marker] = []
        for chapter in chapters(in: range) {
            if let last = kept.last,
                milliseconds(chapter.position - range.lowerBound) == milliseconds(last.position - range.lowerBound)
            {
                dropped.append(chapter)
            } else {
                kept.append(chapter)
            }
        }
        return ChapterList(chapters: kept, dropped: dropped)
    }

    /// `offset` in milliseconds at the session rate, rounded half up with integer math.
    public func milliseconds(_ offset: Frames) -> Int {
        (2 * 1000 * offset.count + sampleRate) / (2 * sampleRate)
    }

    /// The Podcasting 2.0 JSON Chapters 1.2.0 file of the chapters in `range`
    /// (https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/examples/chapters/jsonChapters.md).
    /// Each chapter of `chapterList(in:)` has `startTime` and `title`, so a chapter at the
    /// millisecond of another one is not in the file. A chapter with a URL has `url`, and a chapter
    /// with an image has `img`, the name of `chapterImages(in:imageStem:)`. `imageStem` is the file
    /// name of the JSON with no extension. `startTime` is the offset from the start of `range` in
    /// seconds, rounded half up to the millisecond with integer math. The caller checks
    /// first that `chapters(in: range)` is not empty: an empty file removes the chapters at the
    /// host. It throws the error of `JSONEncoder`, so a failed encode is not "no chapter".
    public func chaptersJSON(in range: Range<Frames>, imageStem: String) throws -> Data {
        let chapters = chapterList(in: range).chapters
        precondition(!chapters.isEmpty, "The range has no chapter")
        let file = ChaptersFile(
            chapters: chapters.enumerated().map { index, chapter in
                ChaptersFile.Chapter(
                    startTime: Double(milliseconds(chapter.position - range.lowerBound)) / 1000, title: chapter.name,
                    url: chapter.url?.text, img: chapter.image.map { imageName($0, stem: imageStem, place: index + 1) })
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }
}

extension Session {
    /// The image of each chapter of `chapterList(in: range)` that has one, and its file name beside
    /// the JSON.
    public func chapterImages(in range: Range<Frames>, imageStem: String) -> [(image: ArtworkName, name: String)] {
        chapterList(in: range).chapters.enumerated().compactMap { index, chapter in
            chapter.image.map { ($0, imageName($0, stem: imageStem, place: index + 1)) }
        }
    }
}

/// The chapters of an export range in order, and the chapters that the list drops.
public struct ChapterList: Hashable, Sendable {
    public let chapters: [Marker]
    public let dropped: [Marker]
}

/// The file name beside the JSON of the image of the chapter at `place` (from 1) in the file
/// (U5 of run 2026-10-11-chapters-in-file): `<stem>-<place>.<jpg or png>`.
private func imageName(_ image: ArtworkName, stem: String, place: Int) -> String {
    "\(stem)-\(place).\(image.isPNG ? "png" : "jpg")"
}

private struct ChaptersFile: Encodable {
    /// The encoder leaves out a nil key, so a chapter with no URL and no image keeps the text of
    /// run 2026-10-09-chapters-export.
    struct Chapter: Encodable {
        let startTime: Double
        let title: String
        let url: String?
        let img: String?
    }

    let version = "1.2.0"
    let chapters: [Chapter]
}
