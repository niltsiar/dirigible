extension Kind where T == Int {
    /// A whole number in `range`, as the schema gives it. The work checks the value again for the
    /// command, which has no schema.
    static func integer(in range: ClosedRange<Int>) -> Kind {
        Kind(
            schema: ["type": "integer", "minimum": range.lowerBound, "maximum": range.upperBound],
            expected: ClipRenderWork.integerForm(range)
        ) { value in exactInteger(value).flatMap { range.contains($0) ? $0 : nil } }
    }
}
