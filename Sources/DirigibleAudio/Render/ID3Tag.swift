import DirigibleCore
import Foundation

/// A chapter of the MP3 tag: its title, and its start and end in ms from the range start.
struct ID3Chapter: Hashable, Sendable {
    var title: String
    var start: Int
    var end: Int
}

/// The ID3 chapters of `chapters`, a list of `Session.chapterList(in: range)`: each chapter ends at
/// the start of the next one, and the last one at the range end. An MP3 has no added chapter at 0.
func id3Chapters(_ chapters: [Marker], in session: Session, range: Range<Frames>) -> [ID3Chapter] {
    let starts = chapters.map { session.milliseconds($0.position - range.lowerBound) }
    let ends = starts.dropFirst() + [session.milliseconds(range.upperBound - range.lowerBound)]
    return zip(chapters, zip(starts, ends)).map { ID3Chapter(title: $0.name, start: $1.0, end: $1.1) }
}

/// The ID3v2.3 tag of `episode` (decision 0045), with `artwork` as the front cover, and of
/// `chapters`: one `CTOC` and one `CHAP` for each chapter, with no byte offsets. No bytes for an
/// empty episode with no chapter. Text frames are UTF-16 with a BOM; URL frames are ISO-8859-1,
/// and `WebURL` is ASCII. It throws before any file exists: `.tooManyChapters` over
/// `maximumChapters`, and `.tagTooLarge` over `maximumTagSize`.
func id3Tag(_ episode: Episode, artwork: Data? = nil, chapters: [ID3Chapter] = []) throws(ExportError) -> [UInt8] {
    guard !episode.isEmpty || !chapters.isEmpty else { return [] }
    guard chapters.count <= maximumChapters else { throw .tooManyChapters(chapters.count) }
    var frames = episode.isEmpty ? [] : episodeFrames(episode, artwork: artwork)
    if !chapters.isEmpty {
        let ids = chapters.indices.map { Array("chp\($0)".utf8) + [0] }
        // Flags 3: the top-level table, in order.
        let head: [UInt8] = Array("toc".utf8) + [0, 3, UInt8(chapters.count)]
        let toc = head + ids.flatMap { $0 }
        frames.append(frame("CTOC", toc + frame("TIT2", [1] + utf16("Chapters"))))
        for (id, chapter) in zip(ids, chapters) {
            // 0xFFFFFFFF byte offsets: a player uses the times.
            let times = bigEndian(UInt32(chapter.start)) + bigEndian(UInt32(chapter.end))
            frames.append(
                frame(
                    "CHAP", id + times + [UInt8](repeating: 0xFF, count: 8) + frame("TIT2", [1] + utf16(chapter.title)))
            )
        }
    }
    let body = frames.flatMap { $0 }
    return Array("ID3".utf8) + [3, 0, 0] + (try tagHeaderSize(body.count)) + body
}

/// The frames of a non-empty episode.
private func episodeFrames(_ episode: Episode, artwork: Data?) -> [[UInt8]] {
    let language = episode.language?.code ?? "XXX"
    var frames: [[UInt8]] = []
    func text(_ id: String, _ value: String?) {
        if let value { frames.append(frame(id, [1] + utf16(value))) }
    }
    text("TIT2", episode.title?.text)
    text("TALB", episode.show?.text)
    text("TPE1", episode.author?.text)
    text("TPE2", episode.author?.text)
    text("TRCK", episode.number?.description)
    text("TPOS", episode.season?.description)
    if let date = episode.date {
        text("TYER", String(format: "%04d", date.year))
        text("TDAT", String(format: "%02d%02d", date.day, date.month))
    }
    text("TCON", "Podcast")
    text("TLAN", episode.language?.code)
    text("TCOP", episode.copyright?.text)
    if episode.explicit { frames.append(frame("TXXX", [1] + utf16("ITUNESADVISORY") + [0, 0] + utf16("1"))) }
    if let summary = episode.summary {
        frames.append(frame("COMM", [1] + Array(language.utf8) + utf16("") + [0, 0] + utf16(summary.text)))
    }
    text("TDES", episode.notes?.text)
    if let url = episode.episodeURL {
        frames.append(frame("WOAF", Array(url.text.utf8)))
        frames.append(frame("WXXX", [0, 0] + Array(url.text.utf8)))
    }
    // WFED as a URL frame: AVFoundation reads a text frame with its encoding byte as an empty URL.
    // Only the presence of PCST counts (LAME id3tag.c).
    if let url = episode.feedURL { frames.append(frame("WFED", Array(url.text.utf8))) }
    frames.append(frame("PCST", [0, 0, 0, 1]))
    text("TGID", episode.guid?.text)
    if let artwork, let name = episode.artwork {
        // ISO-8859-1, the MIME type, picture type 3 (front cover), and an empty description.
        let mime = name.isPNG ? "image/png" : "image/jpeg"
        frames.append(frame("APIC", [0] + Array(mime.utf8) + [0, 3, 0] + artwork))
    }
    return frames
}

/// A v2.3 frame: the ID, a plain big-endian size, no flags, and the body.
private func frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
    Array(id.utf8) + bigEndian(UInt32(body.count)) + [0, 0] + body
}

private func bigEndian(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }

/// The tag size of the header: 7 bits in each byte.
private func syncsafe(_ size: Int) -> [UInt8] {
    [21, 14, 7, 0].map { UInt8((size >> $0) & 0x7F) }
}

/// UTF-16 little-endian with a BOM.
private func utf16(_ text: String) -> [UInt8] {
    [0xFF, 0xFE] + text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
}

/// The most chapters of an MP3 export: the entry count of the ID3 table of contents is one byte.
public let maximumChapters = 255

/// The largest ID3 tag body: the size in the header has 7 bits in each of its 4 bytes.
public let maximumTagSize = (1 << 28) - 1

/// The size bytes of the tag header for a body of `size` bytes.
func tagHeaderSize(_ size: Int) throws(ExportError) -> [UInt8] {
    guard size <= maximumTagSize else { throw .tagTooLarge }
    return syncsafe(size)
}
