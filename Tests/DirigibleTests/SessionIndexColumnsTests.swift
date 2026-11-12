import AppKit
import Foundation
import Testing

@testable import DirigibleApp

/// The columns of the index list.
@Suite(.serialized) @MainActor struct SessionIndexColumnsTests {
    @Test func theDefaultColumnsAreNameAndStart() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, _) = try await windows.open()
        let table = try #require(model.leadingPane.table)
        #expect(table.tableColumns.map(\.identifier.rawValue) == ["name", "start"], "name and start only")
        #expect(table.tableColumns.map(\.title) == [L10n.markerName.text, L10n.indexColumnStart.text])
        await until("the table shows its rows") { table.numberOfRows == 6 }
        let start = try #require(table.view(atColumn: 1, row: 3, makeIfNecessary: true) as? NSTableCellView)
        #expect(start.textField?.stringValue == "0:00:01.000", "b starts at 48,000 frames")
        let name = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(name.textField?.stringValue == "Capture/take1-1-1", "the clip name, not the file ID")
        await model.close()
    }
}
