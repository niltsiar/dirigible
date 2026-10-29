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
}
