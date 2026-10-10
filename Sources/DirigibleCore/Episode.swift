import Foundation

/// A refused episode field value. The CLI and the MCP tools print `message`.
public struct EpisodeFieldError: Error, Hashable, Sendable {
    public let message: String
}

/// The episode metadata of a session (decision 0045). Each field is optional; genre is always
/// Podcast and is not stored. The value types validate at the boundary, so the fields are
/// always valid.
public struct Episode: Hashable, Sendable {
    public var title: EpisodeLine?
    public var show: EpisodeLine?
    public var author: EpisodeLine?
    public var number: EpisodeNumber?
    public var season: EpisodeNumber?
    public var date: CalendarDate?
    public var language: LanguageCode?
    public var copyright: EpisodeLine?
    public var explicit = false
    /// The short description.
    public var summary: EpisodeNotes?
    /// The long episode notes.
    public var notes: EpisodeNotes?
    public var episodeURL: WebURL?
    public var feedURL: WebURL?
    public var guid: EpisodeLine?
    /// The image file in `Artwork/`.
    public var artwork: ArtworkName?

    public init() {}

    /// True when no field has a value. An empty episode raises no file version and writes no tag.
    public var isEmpty: Bool { self == Episode() }

    /// The text of a field: the stored value, or empty for no value.
    public func text(of field: EpisodeField) -> String {
        switch field {
        case .title: title?.text ?? ""
        case .show: show?.text ?? ""
        case .author: author?.text ?? ""
        case .season: season?.description ?? ""
        case .number: number?.description ?? ""
        case .date: date?.description ?? ""
        case .language: language?.code ?? ""
        case .copyright: copyright?.text ?? ""
        case .summary: summary?.text ?? ""
        case .notes: notes?.text ?? ""
        case .episodeURL: episodeURL?.text ?? ""
        case .feedURL: feedURL?.text ?? ""
        case .guid: guid?.text ?? ""
        }
    }

    /// Sets `text` on `field` through the field type. A blank text clears the field. The one text
    /// rule of the Episode pane, the CLI, and the MCP tools.
    public mutating func set(_ field: EpisodeField, text: String) throws(EpisodeFieldError) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let blank = trimmed.isEmpty
        switch field {
        case .title: title = try EpisodeLine(text)
        case .show: show = try EpisodeLine(text)
        case .author: author = try EpisodeLine(text)
        case .season: season = blank ? nil : try EpisodeNumber(text: trimmed)
        case .number: number = blank ? nil : try EpisodeNumber(text: trimmed)
        case .date: date = blank ? nil : try CalendarDate(trimmed)
        case .language: language = blank ? nil : try LanguageCode(trimmed)
        case .copyright: copyright = try EpisodeLine(text)
        case .summary: summary = try EpisodeNotes(text)
        case .notes: notes = try EpisodeNotes(text)
        case .episodeURL: episodeURL = blank ? nil : try WebURL(trimmed)
        case .feedURL: feedURL = blank ? nil : try WebURL(trimmed)
        case .guid: guid = try EpisodeLine(text)
        }
    }
}

/// A text field of an episode: all fields except explicit and the artwork.
public enum EpisodeField: CaseIterable, Sendable {
    case title, show, author, season, number, date, language, copyright, summary, notes, episodeURL, feedURL, guid
}

/// An episode or season number: a whole number of 1 or more.
public struct EpisodeNumber: Hashable, Sendable, CustomStringConvertible {
    public let value: Int

    public init(_ value: Int) throws(EpisodeFieldError) {
        guard value >= 1 else {
            throw EpisodeFieldError(message: "An episode or season number is 1 or more, not \(value).")
        }
        self.value = value
    }

    public init(text: String) throws(EpisodeFieldError) {
        guard let value = Int(text) else { throw EpisodeFieldError(message: "\"\(text)\" is not a whole number.") }
        try self.init(value)
    }

    public var description: String { String(value) }
}

/// An `http` or `https` URL with a host, kept as its ASCII `absoluteString` (ID3 W frames are
/// ISO-8859-1). Foundation gives the punycode host and a percent-encoded path (probe url).
public struct WebURL: Hashable, Sendable {
    public let text: String

    public init(_ text: String) throws(EpisodeFieldError) {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host, !host.isEmpty, url.absoluteString.allSatisfy(\.isASCII)
        else { throw EpisodeFieldError(message: "\"\(text)\" is not an http or https URL.") }
        self.text = url.absoluteString
    }
}

/// A day of the calendar, written `YYYY-MM-DD`.
public struct CalendarDate: Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws(EpisodeFieldError) {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...9999).contains(year), (1...12).contains(month), (1...days[month - 1]).contains(day) else {
            throw Self.refused(String(format: "%04d-%02d-%02d", year, month, day))
        }
        (self.year, self.month, self.day) = (year, month, day)
    }

    public init(_ text: String) throws(EpisodeFieldError) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [4, 2, 2], parts.allSatisfy({ $0.allSatisfy(\.isASCII) }), let year = Int(parts[0]),
            let month = Int(parts[1]), let day = Int(parts[2])
        else {
            throw Self.refused(text)
        }
        try self.init(year: year, month: month, day: day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func refused(_ text: String) -> EpisodeFieldError {
        EpisodeFieldError(message: "\"\(text)\" is not a date in the form YYYY-MM-DD.")
    }
}

/// An ISO 639-2 language code: three lowercase letters. A bibliographic (B) code maps to its
/// terminology (T) code. The check uses no ICU data, so a saved code always reads back.
public struct LanguageCode: Hashable, Sendable {
    public let code: String

    public init(_ text: String) throws(EpisodeFieldError) {
        guard text.count == 3, text.allSatisfy({ ("a"..."z").contains($0) }) else {
            throw EpisodeFieldError(
                message: "\"\(text)\" is not an ISO 639-2 language code of three lowercase letters.")
        }
        code = Self.terminology[text] ?? text
    }

    /// The 20 ISO 639-2 codes whose bibliographic (B) code differs from the terminology (T) code.
    static let terminology = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]
}

/// One line of text: no line break, no tab, and no other control character.
public struct EpisodeLine: Hashable, Sendable {
    public let text: String

    /// Nil for a text of only whitespace.
    public init?(_ text: String) throws(EpisodeFieldError) {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        if text.contains(where: { $0.isNewline || $0 == "\t" }) {
            throw EpisodeFieldError(message: "A title, show, author, copyright, or GUID is one line, with no tab.")
        }
        try checkCharacters(text)
        self.text = text
    }
}

/// A text that keeps its line breaks and tabs. CR LF, CR, a vertical tab, and a form feed become LF.
public struct EpisodeNotes: Hashable, Sendable {
    public let text: String

    /// Nil for a text of only whitespace.
    public init?(_ text: String) throws(EpisodeFieldError) {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0B}", with: "\n").replacingOccurrences(of: "\u{0C}", with: "\n")
        try checkCharacters(lines, allowing: ["\n", "\t"])
        self.text = lines
    }
}

/// The name of an artwork file in `Artwork/`: a UUID with `.jpg` or `.png`, so it has no slash.
/// An import always makes a new name, so undo and the backups keep their image.
public struct ArtworkName: Hashable, Sendable {
    public let name: String

    public init(_ name: String) throws(EpisodeFieldError) {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, ["jpg", "png"].contains(parts[1]) else {
            throw EpisodeFieldError(message: "\"\(name)\" is not an artwork file name.")
        }
        self.name = name
    }

    /// A new name for an import.
    package init(png: Bool) { name = "\(UUID().uuidString).\(png ? "png" : "jpg")" }

    public var isPNG: Bool { name.hasSuffix(".png") }
    /// The path in the package.
    public var path: String { "\(artworkFolderName)/\(name)" }
}

/// XML 1.0 cannot hold the other control characters (`Session.checkText`).
private func checkCharacters(_ text: String, allowing allowed: Set<Unicode.Scalar> = []) throws(EpisodeFieldError) {
    guard text.unicodeScalars.allSatisfy({ $0.isStorableInSession || allowed.contains($0) }) else {
        throw EpisodeFieldError(message: "The text has a control character.")
    }
}
