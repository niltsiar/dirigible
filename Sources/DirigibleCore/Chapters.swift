import Foundation

extension Session {
    /// The chapter markers in `range`, by position, then by ID (as the session file).
    public func chapters(in range: Range<Frames>) -> [Marker] {
        markers.values.filter { $0.kind == .chapter && range.contains($0.position) }
            .sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    /// The Podcasting 2.0 JSON Chapters 1.2.0 file of the chapters in `range`
    /// (https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/examples/chapters/jsonChapters.md).
    /// Each chapter has `startTime` and `title` only. `startTime` is the offset from the start of
    /// `range` in seconds, rounded half up to the millisecond with integer math. The caller checks
    /// first that `chapters(in: range)` is not empty: an empty file removes the chapters at the
    /// host. It throws the error of `JSONEncoder`, so a failed encode is not "no chapter".
    public func chaptersJSON(in range: Range<Frames>) throws -> Data {
        let chapters = chapters(in: range)
        precondition(!chapters.isEmpty, "The range has no chapter")
        let rate = sampleRate
        let file = ChaptersFile(
            chapters: chapters.map {
                let offset = ($0.position - range.lowerBound).count
                let milliseconds = (2 * 1000 * offset + rate) / (2 * rate)
                return ChaptersFile.Chapter(startTime: Double(milliseconds) / 1000, title: $0.name)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }
}

private struct ChaptersFile: Encodable {
    struct Chapter: Encodable {
        let startTime: Double
        let title: String
    }

    let version = "1.2.0"
    let chapters: [Chapter]
}
