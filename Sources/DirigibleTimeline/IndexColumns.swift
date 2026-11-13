/// The optional columns of the session index list that the user shows. Name and Start always show.
public struct IndexColumns: Equatable, Sendable {
    public enum Column: String, CaseIterable, Sendable { case track, duration, end }

    public private(set) var shown: Set<Column>

    public init(shown: Set<Column> = []) { self.shown = shown }

    /// The columns of a stored value: an array of column names. A name that is no optional column is
    /// dropped. Any other value gives no optional column.
    public init(stored: Any?) {
        let names = stored as? [String] ?? []
        shown = Set(names.compactMap(Column.init(rawValue:)))
    }

    /// The value to store: the names of the shown columns, in the order of the list.
    public var stored: [String] { Column.allCases.filter(shown.contains).map(\.rawValue) }

    public mutating func toggle(_ column: Column) {
        if shown.remove(column) == nil { shown.insert(column) }
    }
}
