import AppKit
import Foundation
import Testing

@testable import DirigibleApp

/// The Index item of the session toolbar.
extension ToolbarWindowTests {
    func indexItem(_ chrome: SessionChrome) throws -> (NSToolbarItem, NSButton) {
        let item = try #require(chrome.toolbar.items.first { $0.itemIdentifier == ToolbarItemID.index.identifier })
        return (item, try #require(item.view as? NSButton))
    }

    @Test func theIndexItemIsFirstInTheDefaultSet() async throws {
        let (model, _, chrome) = try await open("index-first")
        #expect(ToolbarItemID.defaults.first == ToolbarItemID.index.identifier, "\(ToolbarItemID.defaults)")
        #expect(chrome.toolbar.items.first?.itemIdentifier.rawValue == "view.index", "\(chrome.toolbar.items)")
        #expect(ToolbarItemID.index.symbol == "sidebar.leading")
        await model.close()
    }

    @Test func theIndexItemTogglesThePane() async throws {
        let (model, _, chrome) = try await open("index-toggle")
        let (_, button) = try indexItem(chrome)
        try #require(!model.leadingPane.shown)
        await until("the item is enabled") { button.isEnabled }
        button.performClick(nil)
        #expect(model.leadingPane.shown, "a click shows the pane")
        await until("the item shows its state") { button.state == .on }
        button.performClick(nil)
        #expect(!model.leadingPane.shown, "a click hides the shown pane")
        await until("the item shows its state") { button.state == .off }
        await model.close()
    }

    @Test func theIndexItemTitleFollowsTheState() async throws {
        let (model, _, chrome) = try await open("index-title")
        let (item, button) = try indexItem(chrome)
        let english = try stringsTable("en")
        let text: (L10n) -> String = { english[$0.rawValue] ?? $0.rawValue }
        #expect(indexTooltip(shown: false, text: text) == "Show Sidebar")
        #expect(indexTooltip(shown: true, text: text) == "Hide Sidebar")

        // The test process has no app tables, so the live tooltip is the key of the state.
        await until("the item has its tooltip") { item.toolTip == indexTooltip(shown: false) }
        #expect(app.indexItem(for: model).title == .menuViewIndexShow)
        model.toggleIndex()
        await until("the item follows the state") { button.state == .on }
        #expect(app.indexItem(for: model).title == .menuViewIndexHide)
        #expect(button.accessibilityLabel() == indexTooltip(shown: true))
        await model.close()
    }
}
