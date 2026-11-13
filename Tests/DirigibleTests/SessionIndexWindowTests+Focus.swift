import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The key view loop of the index pane.
extension SessionIndexWindowTests {
    /// The pull-down of the pane footer: in the pane, below the list.
    func indexFooter(below table: NSView, in window: NSWindow) -> NSPopUpButton? {
        views(NSPopUpButton.self, in: window.contentView).first {
            $0.pullsDown && frame($0).maxX < frame(table).maxX + 1 && frame($0).maxY <= frame(table).minY + 1
        }
    }

    @Test func theTabOrderRunsFromTheToolbarToTheLanes() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _, window) = try await open()
        let table = try #require(model.leadingPane.table)
        let lanes = try #require(model.timelineView?.lanes)
        let field = try #require(
            views(NSTextField.self, in: window.contentView).first { $0.isEditable && frame($0).maxX < 260 })
        window.recalculateKeyViewLoop()
        var order: [NSView] = []
        var next = field.nextValidKeyView
        while let view = next, !order.contains(view), order.count < 40 {
            order.append(view)
            next = view.nextValidKeyView
        }
        let position = { (target: NSView) in order.firstIndex { $0 === target || $0.isDescendant(of: target) } }
        let tablePosition = try #require(position(table), "the list is in the loop")
        let lanesPosition = try #require(position(lanes), "the lanes are in the loop")
        #expect(tablePosition < lanesPosition, "the list comes before the lanes")
        if let filter = views(NSSegmentedControl.self, in: window.contentView).first(where: { $0.segmentCount == 4 }),
            let filterPosition = position(filter)
        {
            #expect(filterPosition < tablePosition, "the filter comes before the list")
        }
        let footer = try #require(indexFooter(below: table, in: window), "the footer has a pull-down")
        let footerPosition = try #require(position(footer), "the footer pull-down is in the loop")
        #expect(tablePosition < footerPosition, "the footer follows the list")
        await model.close()
    }
}
