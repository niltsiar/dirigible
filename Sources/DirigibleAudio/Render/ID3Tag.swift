import DirigibleCore
import Foundation

/// The ID3v2.3 tag of `episode` (decision 0045), or no bytes for an empty episode. Text frames
/// are UTF-16 with a BOM; URL frames are ISO-8859-1, and `WebURL` is ASCII. The frame list is
/// the place where run 5 adds CHAP and CTOC.
func id3Tag(_ episode: Episode) -> [UInt8] {
    guard !episode.isEmpty else { return [] }
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
    let body = frames.flatMap { $0 }
    return Array("ID3".utf8) + [3, 0, 0] + syncsafe(body.count) + body
}

/// A v2.3 frame: the ID, a plain big-endian size, no flags, and the body.
private func frame(_ id: String, _ body: [UInt8]) -> [UInt8] {
    let size = UInt32(body.count)
    return Array(id.utf8) + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: size >> $0) } + [0, 0] + body
}

/// The tag size of the header: 7 bits in each byte.
private func syncsafe(_ size: Int) -> [UInt8] {
    [21, 14, 7, 0].map { UInt8((size >> $0) & 0x7F) }
}

/// UTF-16 little-endian with a BOM.
private func utf16(_ text: String) -> [UInt8] {
    [0xFF, 0xFE] + text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
}
