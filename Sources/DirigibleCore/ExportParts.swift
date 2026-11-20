import Foundation

/// The points where an export of one file for each part splits its range (decision 0067).
public enum SplitKind: String, Sendable, CaseIterable {
    /// The markers of kind `.chapter`.
    case chapters
    /// Every marker, both kinds.
    case markers
}

/// One file of a split export: its frame range, its start, and its title.
public struct ExportPart: Hashable, Sendable {
    public enum Start: Hashable, Sendable {
        /// The part before the first split point: number 00.
        case rangeStart
        /// The part from a split point, with its number from 1.
        case point(Marker, number: Int)
    }

    public let range: Range<Frames>
    public let start: Start
    /// Nil keeps the episode title (`Session.forPart(_:)`).
    public let title: EpisodeLine?

    /// The number of the file name: 0 for the part before the first split point.
    public var number: Int {
        switch start {
        case .rangeStart: 0
        case .point(_, let number): number
        }
    }
}

/// The parts of an export range, and the split points that give no part.
public struct ExportParts: Hashable, Sendable {
    /// In range order, with no gap and no overlap. Empty when the range has no split point.
    public let parts: [ExportPart]
    /// The points at the millisecond of the point before them, or of the range end.
    public let dropped: [Marker]

    /// The digits of the number in each file name: those of the highest number, at least 2, so
    /// the names sort in part order.
    public var digits: Int { max(2, String(parts.last?.number ?? 0).count) }
}

extension Session {
    /// The parts of `range` at the markers of `kind` (decision 0067). A point whose rounded
    /// millisecond (the rule of `chapterList(in:)`) equals that of the point before it, or that of
    /// the range end, is dropped. Part k runs from point k to point k + 1, and the last part to the
    /// range end. Audio before the first point is part 00, with the name of the last point before
    /// the range start, else the episode title, else the show, else `introTitle`. A first point at
    /// the millisecond of the range start takes the range start, so no part is under 1 ms.
    public func exportParts(in range: Range<Frames>, by kind: SplitKind, introTitle: String) -> ExportParts {
        func isPoint(_ marker: Marker) -> Bool { kind == .markers || marker.kind == .chapter }
        func millisecond(_ position: Frames) -> Int { milliseconds(position - range.lowerBound) }
        let endMillisecond = millisecond(range.upperBound)
        var kept: [Marker] = []
        var dropped: [Marker] = []
        for marker in sortedMarkers where isPoint(marker) && range.contains(marker.position) {
            let at = millisecond(marker.position)
            if at == endMillisecond || kept.last.map({ millisecond($0.position) == at }) == true {
                dropped.append(marker)
            } else {
                kept.append(marker)
            }
        }
        guard let first = kept.first else { return ExportParts(parts: [], dropped: dropped) }
        var parts: [ExportPart] = []
        let partZero = millisecond(first.position) > 0
        if partZero {
            let before = sortedMarkers.last { isPoint($0) && $0.position < range.lowerBound }
            let title = before.flatMap { Self.partTitle($0.name) } ?? episode.title ?? episode.show
            parts.append(
                ExportPart(
                    range: range.lowerBound..<first.position, start: .rangeStart,
                    title: title ?? Self.partTitle(introTitle)))
        }
        for (index, marker) in kept.enumerated() {
            let end = index + 1 < kept.count ? kept[index + 1].position : range.upperBound
            let start = index == 0 && !partZero ? range.lowerBound : marker.position
            parts.append(
                ExportPart(
                    range: start..<end, start: .point(marker, number: index + 1),
                    title: Self.partTitle(marker.name)))
        }
        return ExportParts(parts: parts, dropped: dropped)
    }

    /// The session of the file of `part`: its `episode.title` is the part title, or the episode
    /// title when the part has none. The one owner of the title rule of a part file (decision 0067).
    public func forPart(_ part: ExportPart) -> Session {
        guard let title = part.title else { return self }
        var copy = self
        var episode = episode
        episode.title = title
        copy.setEpisode(episode)
        return copy
    }

    /// `<prefix>-<NN>-<title>.<pathExtension>` (decision 0067). Each character that macOS, exFAT,
    /// FAT32, or SMB refuses becomes "-", and the spaces at each end and a leading dot go; an empty
    /// title gives `<prefix>-<NN>.<pathExtension>`. A name over `limit` UTF-8 bytes loses characters
    /// from the end of the title, then from the end of the prefix, never `-<NN>` or the extension.
    /// The prefix is not cleaned.
    public static func partFileName(
        _ part: ExportPart, digits: Int, prefix: String, pathExtension: String, limit: Int
    ) -> String {
        let number = String(repeating: "0", count: max(0, digits - String(part.number).count)) + String(part.number)
        var title = fileNameText(part.title?.text ?? "")
        var prefix = prefix
        func name() -> String { "\(prefix)-\(number)\(title.isEmpty ? "" : "-\(title)").\(pathExtension)" }
        while name().utf8.count > limit, !title.isEmpty {
            title.removeLast()
            while title.last == " " { title.removeLast() }
        }
        while name().utf8.count > limit, !prefix.isEmpty { prefix.removeLast() }
        return name()
    }

    /// True for `<prefix>-<digits>.<pathExtension>` and `<prefix>-<digits>-<text>.<pathExtension>`,
    /// with two digits or more: the names of an earlier set of the prefix.
    public static func isPartFileName(_ name: String, prefix: String, pathExtension: String) -> Bool {
        let suffix = ".\(pathExtension)"
        guard name.hasPrefix("\(prefix)-"), name.hasSuffix(suffix), name.count > prefix.count + 1 + suffix.count else {
            return false
        }
        let middle = name.dropFirst(prefix.count + 1).dropLast(suffix.count)
        let digits = middle.prefix { $0.isASCII && $0.isNumber }
        guard digits.count >= 2 else { return false }
        let rest = middle.dropFirst(digits.count)
        return rest.isEmpty || (rest.first == "-" && rest.count > 1)
    }

    /// The title of a part from a marker name: each line break and tab becomes a space. A marker
    /// name passed `checkText`, so the `EpisodeLine` check does not throw. Nil for only whitespace.
    private static func partTitle(_ name: String) -> EpisodeLine? {
        let line = String(
            String.UnicodeScalarView(name.unicodeScalars.map { Character($0).isNewline || $0 == "\t" ? " " : $0 }))
        return (try? EpisodeLine(line)) ?? nil
    }

}

/// `text` as a part of an export file name, the one cleaner of the split export (decision 0067)
/// and the stem export (0078): each character that macOS, exFAT, FAT32, or SMB refuses
/// (`/ \ : * ? " < > |` and the control characters) becomes "-", and the spaces at each end and a
/// leading dot go.
func fileNameText(_ text: String) -> String {
    let refused: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    let cleaned = String(
        String.UnicodeScalarView(
            text.unicodeScalars.map { refused.contains($0) || $0.properties.generalCategory == .control ? "-" : $0 }))
    return String(cleaned.trimmingCharacters(in: .whitespaces).drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
}
