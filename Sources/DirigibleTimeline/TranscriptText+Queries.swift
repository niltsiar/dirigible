import DirigibleCore
import Foundation

extension TranscriptText {
    /// The text location of the first unit of the current paragraph at `frame`: the last paragraph
    /// whose first unit starts at or before `frame`, else the first paragraph. Nil with no unit.
    public func paragraphStart(at frame: Frames) -> Int? {
        var first: Int?
        var current: Int?
        var index = 0
        for header in headers {
            while index < units.count, units[index].text.lowerBound < header.range.upperBound { index += 1 }
            guard index < units.count else { break }
            let unit = units[index]
            first = first ?? unit.text.lowerBound
            if unit.frames.lowerBound <= frame { current = unit.text.lowerBound }
        }
        return current ?? first
    }

    /// The unit that holds the text location `location`, or nil on a header, a track name, or a
    /// line break (P5).
    public func unit(atTextLocation location: Int) -> Unit? {
        var (low, high) = (0, units.count)
        while low < high {
            let middle = (low + high) / 2
            if units[middle].text.lowerBound <= location { low = middle + 1 } else { high = middle }
        }
        guard low > 0, units[low - 1].text.contains(location) else { return nil }
        return units[low - 1]
    }

    /// The first unit of the paragraph whose header holds `location`, the end of the header
    /// included, or nil elsewhere (P21).
    public func headerUnit(atTextLocation location: Int) -> Unit? {
        guard let header = headers.first(where: { $0.range.lowerBound <= location && location <= $0.range.upperBound })
        else { return nil }
        return units.first { $0.text.lowerBound > header.range.upperBound }
    }

    // MARK: Selection (P8, P9, P16)

    /// The indexes of the units that the text range `range` touches. For a collapsed range: the
    /// unit that holds it inside, or none at the index of the next unit.
    public func unitIndexes(touching range: Range<Int>) -> Range<Int> {
        var (low, high) = (0, units.count)
        while low < high {
            let middle = (low + high) / 2
            if units[middle].text.upperBound <= range.lowerBound { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < units.count, units[end].text.lowerBound < range.upperBound { end += 1 }
        return low..<end
    }

    /// The text range from the first to the last unit that `range` touches, or nil when it touches
    /// none: a collapsed range, or a range of header, track name, or line break text only.
    public func snapped(_ range: Range<Int>) -> Range<Int>? {
        let found = unitIndexes(touching: range)
        guard !range.isEmpty, let first = found.first, let last = found.last else { return nil }
        return units[first].text.lowerBound..<units[last].text.upperBound
    }

    /// The frames of the units that `range` touches: the earliest start to the latest end, so a
    /// long cue in the middle can set the end (P9). Nil when it touches no unit.
    public func frames(inText range: Range<Int>) -> Range<Frames>? {
        let found = units[unitIndexes(touching: range)]
        guard !range.isEmpty, let start = found.map(\.frames.lowerBound).min(),
            let end = found.map(\.frames.upperBound).max()
        else { return nil }
        return start..<end
    }

    /// The index of the unit after the next sentence end at or after the unit `boundary`, or the
    /// unit count. A sentence ends at a unit whose text ends in ".", "?", "!", or "\u{2026}", or at
    /// the last unit of a line (P8).
    public func nextSentenceBoundary(after boundary: Int) -> Int {
        let words = string as NSString
        return (min(max(0, boundary), units.count)..<units.count).first { isSentenceEnd($0, in: words) }
            .map { $0 + 1 } ?? units.count
    }

    /// The index of the unit after the last sentence end before the unit `boundary - 1`, or 0.
    public func previousSentenceBoundary(before boundary: Int) -> Int {
        let words = string as NSString
        let last = min(boundary - 2, units.count - 1)
        guard last >= 0 else { return 0 }
        return (0...last).last { isSentenceEnd($0, in: words) }.map { $0 + 1 } ?? 0
    }

    private func isSentenceEnd(_ index: Int, in words: NSString) -> Bool {
        let end = units[index].text.upperBound
        if end == words.length || words.character(at: end) == 0x0A { return true }
        // A period, a question mark, an exclamation mark, or an ellipsis.
        return [0x2E, 0x3F, 0x21, 0x2026].contains(words.character(at: end - 1))
    }

    /// The units of `tracks` whose midpoint is inside `frames`, in text order (P9).
    private func tinted(_ frames: Range<Frames>, tracks: Set<TrackID>) -> [Int] {
        units.indices.filter { index in
            let unit = units[index]
            let middle = unit.frames.lowerBound + Frames((unit.frames.upperBound - unit.frames.lowerBound).count / 2)
            return tracks.contains(unit.track) && frames.contains(middle)
        }
    }

    /// The text ranges of the tint of a range: one range for each run of adjacent tinted units on
    /// one line, with the spaces between them.
    public func tintRuns(_ frames: Range<Frames>, tracks: Set<TrackID>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var previous: Int?
        for index in tinted(frames, tracks: tracks) {
            let text = units[index].text
            if let last = runs.last, previous == index - 1, sameLine(index - 1, index) {
                runs[runs.count - 1] = last.lowerBound..<text.upperBound
            } else {
                runs.append(text)
            }
            previous = index
        }
        return runs
    }

    /// The text of the tinted units of a range (P16): one space between two units of a line, a
    /// line break between two lines, no header and no track name. Nil when no unit is tinted.
    public func copyText(_ frames: Range<Frames>, tracks: Set<TrackID>) -> String? {
        let found = tinted(frames, tracks: tracks)
        guard let first = found.first else { return nil }
        let words = string as NSString
        var out = words.substring(with: NSRange(units[first].text))
        for (before, index) in zip(found, found.dropFirst()) {
            out += sameLine(before, index) ? " " : "\n"
            out += words.substring(with: NSRange(units[index].text))
        }
        return out
    }

    /// True when the units `first` and `second` are on one line.
    private func sameLine(_ first: Int, _ second: Int) -> Bool { lines[first] == lines[second] }
}
