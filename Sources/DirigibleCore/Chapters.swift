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
    /// Each chapter of `chapterList(in:)` has `startTime` and `title` only, so a chapter at the
    /// millisecond of another one is not in the file. `startTime` is the offset from the start of
    /// `range` in seconds, rounded half up to the millisecond with integer math. The caller checks
    /// first that `chapters(in: range)` is not empty: an empty file removes the chapters at the
    /// host. It throws the error of `JSONEncoder`, so a failed encode is not "no chapter".
    public func chaptersJSON(in range: Range<Frames>) throws -> Data {
        let chapters = chapterList(in: range).chapters
        precondition(!chapters.isEmpty, "The range has no chapter")
        let file = ChaptersFile(
            chapters: chapters.map {
                ChaptersFile.Chapter(
                    startTime: Double(milliseconds($0.position - range.lowerBound)) / 1000, title: $0.name)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }
}

/// The chapters of an export range in order, and the chapters that the list drops.
public struct ChapterList: Hashable, Sendable {
    public let chapters: [Marker]
    public let dropped: [Marker]
}

private struct ChaptersFile: Encodable {
    struct Chapter: Encodable {
        let startTime: Double
        let title: String
    }

    let version = "1.2.0"
    let chapters: [Chapter]
}
