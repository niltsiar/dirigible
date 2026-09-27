import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// The empty session and the route menu of a track with no input (ui-shell criterion A22).
@Suite(.serialized) @MainActor struct EmptyStateTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        folder = try TemporaryFolder()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// The views of `type` under `view`, depth first.
    func views<V: NSView>(_ type: V.Type, under view: NSView?) -> [V] {
        guard let view else { return [] }
        return ((view as? V).map { [$0] } ?? []) + view.subviews.flatMap { views(type, under: $0) }
    }

    /// The steps text in both tables names the three actions.
    @Test func theEmptyStateSaysWhatToDo() throws {
        #expect(
            try stringsTable("en")[L10n.emptySteps.rawValue]
                == "Add a track for each voice, choose its input, then press Record.")
        #expect(try stringsTable("es")[L10n.emptySteps.rawValue]?.isEmpty == false)
        #expect(try stringsTable("en")[L10n.trackRouteChoose.rawValue] == "Choose Input…")
    }

    @Test func anEmptySessionOffersAddTrack() async throws {
        let url = folder.url.appending(path: "empty.dirigible")
        try await Task.detached { try Session.create(at: url, sampleRate: 48_000) }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        let window = try #require(model.window)
        var button: NSButton?
        // The empty content has one button; SwiftUI hosts its label, so the title is empty.
        await until(limit: .seconds(10), "the empty state shows its Add Track button") {
            window.contentView?.layoutSubtreeIfNeeded()
            button = views(NSButton.self, under: window.contentView).first
            return button != nil
        }
        #expect(views(NSButton.self, under: window.contentView).count == 1)
        model.leafCalls = []
        try #require(button).performClick(nil)

        #expect(studio.session.tracks.count == 1, "the button added no track")
        #expect(model.leafCalls == ["addTrack"], "the button did not go through run(.addTrack)")
        model.leafCalls = nil
        await model.close()
    }

    /// A track with no route shows "Choose Input…" as the route menu label. SwiftUI fills the menu
    /// only when it opens, so "No Input" inside the menu is a manual check.
    @Test func aTrackWithNoRouteAsksForAnInput() async throws {
        let url = folder.url.appending(path: "noroute.dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "T1", layout: .mono)
            try session.write(to: url)
        }.value
        let model = await app.open(url)
        _ = await model.opened()
        let window = try #require(model.window)
        var menu: NSPopUpButton?
        await until(limit: .seconds(10), "the route menu shows") {
            window.contentView?.layoutSubtreeIfNeeded()
            menu = views(NSPopUpButton.self, under: window.contentView).first
            return menu != nil
        }
        let route = try #require(menu)
        #expect(route.title == L10n.trackRouteChoose.text, "label \(route.title)")
        await model.close()
    }
}
