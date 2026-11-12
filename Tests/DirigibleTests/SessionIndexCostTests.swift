import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The work that the index list must not do again for each row it shows.
@Suite(.serialized) @MainActor struct SessionIndexCostTests {
    /// The name cells of one kind show one glyph image, also after a reload. A new image for each
    /// cell looks up its symbol and draws it again, for each row in view of each reload.
    @Test func theNameCellsOfOneKindShareOneGlyphImage() async throws {
        let windows = try SessionIndexWindowTests()
        defer { windows.defaults.removePersistentDomain(forName: windows.suite) }
        let (model, _, window, table) = try await windows.openRows()
        let source = try #require(table.dataSource as? IndexTableSource)
        func glyphs() -> [(kind: SessionIndex.Kind, image: NSImage)] {
            (0..<table.numberOfRows).compactMap { n in
                let cell = table.view(atColumn: 0, row: n, makeIfNecessary: false) as? NSTableCellView
                return cell?.imageView?.image.map { (source.rows[n].kind, $0) }
            }
        }
        let shown = glyphs()
        try #require(shown.count == 6, "each of the six rows shows a glyph")
        for kind in SessionIndex.Kind.allCases {
            let images = shown.filter { $0.kind == kind }.map(\.image)
            #expect(images.allSatisfy { $0 === images.first }, "one image for the \(kind) rows")
        }
        table.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()
        let reloaded = glyphs()
        try #require(reloaded.count == 6, "the reload shows each row again")
        for (kind, image) in reloaded {
            #expect(shown.contains { $0.kind == kind && $0.image === image }, "the reload keeps the \(kind) image")
        }
        await model.close()
    }
}
