import DirigibleCore

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
}
