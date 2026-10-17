import Foundation

/// The refusal of a chapters file.
public enum ChaptersFileError: Error, Hashable, Sendable {
    /// The data is not a JSON object.
    case notAnObject
    /// The file has no `chapters` array, or an empty one.
    case noChapters
    /// The `version` is absent or does not start with "1.".
    case unsupportedVersion(String?)
    /// Chapter `place` (from 1) has no `startTime` that is a number of seconds, 0 or more.
    case startTime(place: Int)
    /// The title of chapter `place` has a character that a session cannot store.
    case title(place: Int)
}

/// A Podcasting 2.0 JSON Chapters 1.x file, parsed at the boundary into a typed list. Foundation
/// only. `Session.importChapters` turns it into markers.
public struct ImportedChapters: Hashable, Sendable {
    public struct Chapter: Hashable, Sendable {
        /// Seconds from the start of the file: finite, 0 or more.
        public let startTime: Double
        /// Nil: the import names the marker "Chapter N".
        public let title: String?
        /// False for `toc` false: the import makes a marker of the kind `marker`.
        public let isChapter: Bool
        /// The http or https `url`, when the file has one that a marker can hold.
        public let url: WebURL?
        /// The file names an `img`. The import copies no image.
        public let hasImage: Bool
    }

    /// In file order.
    public let chapters: [Chapter]
    /// The places (from 1) of the chapters whose `url` is dropped: not an http or https link, or
    /// over `Marker.maximumURLBytes`.
    public let droppedURLs: [Int]

    private enum Key: String, CodingKey { case version, chapters, startTime, title, toc, url, img }

    /// A value of the wrong type reads as absent, so the check of the field names the chapter.
    private struct File: Decodable {
        let version: String?
        let chapters: [Entry]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            version = try? container.decode(String.self, forKey: .version)
            chapters = try? container.decode([Entry].self, forKey: .chapters)
        }
    }

    private struct Entry: Decodable {
        var startTime: Double?
        var title: String?
        var toc: Bool?
        var url: String?
        var img: String?

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Key.self) else { return }
            startTime = try? container.decode(Double.self, forKey: .startTime)
            title = try? container.decode(String.self, forKey: .title)
            toc = try? container.decode(Bool.self, forKey: .toc)
            url = try? container.decode(String.self, forKey: .url)
            img = try? container.decode(String.self, forKey: .img)
        }
    }

    /// Reads `data`. The checks come in this order: a JSON object, a non-empty `chapters` array, a
    /// `version` that starts with "1.", then each chapter in file order (`startTime`, then
    /// `title`). A `title` that is empty after the spaces at its edges is no title.
    public init(data: Data) throws(ChaptersFileError) {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw .notAnObject }
        guard let entries = file.chapters, !entries.isEmpty else { throw .noChapters }
        guard let version = file.version, version.hasPrefix("1.") else { throw .unsupportedVersion(file.version) }
        var chapters: [Chapter] = []
        var dropped: [Int] = []
        for (index, entry) in entries.enumerated() {
            let place = index + 1
            guard let startTime = entry.startTime, startTime.isFinite, startTime >= 0 else {
                throw .startTime(place: place)
            }
            let title = entry.title?.trimmingCharacters(in: .whitespaces)
            guard title?.unicodeScalars.allSatisfy(\.isStorableInSession) ?? true else { throw .title(place: place) }
            var url: WebURL?
            if let text = entry.url {
                do throws(EpisodeFieldError) { url = try Marker.url(fromText: text) } catch { dropped.append(place) }
            }
            chapters.append(
                Chapter(
                    startTime: startTime, title: title?.isEmpty == false ? title : nil, isChapter: entry.toc ?? true,
                    url: url, hasImage: entry.img?.isEmpty == false))
        }
        (self.chapters, droppedURLs) = (chapters, dropped)
    }
}

extension Session {
    /// Adds a marker for each chapter of `file`, from timeline frame `at`, in one change, and gives
    /// their IDs in file order. A chapter is a marker of the kind `chapter`, or `marker` when
    /// `toc` is false. `imagesLeft` counts the chapters with an `img` that got no image: the
    /// import copies none.
    ///
    /// With `replacing`, it first removes each chapter marker and keeps each plain marker. A
    /// removed chapter with an image gives it to the first file chapter with `toc` true that is at
    /// the same millisecond (the rule of the export, `chaptersJSON`), counted from `at`; the export
    /// writes no image of a plain marker. When a removed image finds no chapter, the import throws
    /// `.chapterImageNotKept` and changes nothing: it never drops an image that the file does not
    /// replace. A `toc` false chapter with the name and frame of a plain marker adds no marker and
    /// gives the ID of that marker, so a second import of one file gives the same markers.
    ///
    /// The frame of each chapter is checked against `Frames.limit` before `Int(...)`, as
    /// `importTranscript`, so a `startTime` of 1e300 throws `.chapterOutOfRange` and does not trap.
    @discardableResult
    public mutating func importChapters(_ file: ImportedChapters, at: Frames, replacing: Bool)
        throws(SessionError) -> (markers: [MarkerID], imagesLeft: Int)
    {
        guard at.isInRange else { throw .frameOutOfRange }
        var frames: [Frames] = []
        for (index, chapter) in file.chapters.enumerated() {
            let count = (chapter.startTime * Double(sampleRate)).rounded()
            guard count <= Double(Frames.limit.count) else { throw .chapterOutOfRange(place: index + 1) }
            let frame = Frames(Int(count)) + at
            guard frame.isInRange else { throw .chapterOutOfRange(place: index + 1) }
            frames.append(frame)
        }
        let removed = replacing ? sortedMarkers.filter { $0.kind == .chapter } : []
        var images: [Int: ArtworkName] = [:]
        var lost: [Marker] = []
        for old in removed {
            guard let image = old.image else { continue }
            // `startTime` x 1000 is under 2^40 x 1000 here, as the frame check above holds.
            let match =
                old.position < at
                ? nil
                : file.chapters.indices.first { index in
                    images[index] == nil && file.chapters[index].isChapter
                        && Int((file.chapters[index].startTime * 1000).rounded()) == milliseconds(old.position - at)
                }
            if let match { images[match] = image } else { lost.append(old) }
        }
        guard lost.isEmpty else { throw .chapterImageNotKept(lost) }
        var next = self
        for old in removed { try next.removeMarker(old.id) }
        var plain = replacing ? next.sortedMarkers.filter { $0.kind == .marker } : []
        var ids: [MarkerID] = []
        for (index, chapter) in file.chapters.enumerated() {
            let name = chapter.title ?? "Chapter \(index + 1)"
            if !chapter.isChapter,
                let kept = plain.firstIndex(where: { $0.name == name && $0.position == frames[index] })
            {
                ids.append(plain.remove(at: kept).id)
                continue
            }
            let marker = Marker(
                id: MarkerID(), name: name, position: frames[index], kind: chapter.isChapter ? .chapter : .marker,
                url: chapter.url, image: images[index])
            try next.setMarker(marker)
            ids.append(marker.id)
        }
        self = next
        return (ids, file.chapters.indices.filter { file.chapters[$0].hasImage && images[$0] == nil }.count)
    }
}
