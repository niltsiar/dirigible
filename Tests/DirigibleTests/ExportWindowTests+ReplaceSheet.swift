import AppKit
import Foundation
import Testing
import os

@testable import DirigibleApp

/// A set job that a test starts and does not await at once. `ends` waits for it with a limit.
@MainActor struct SetJob {
    private let ended = OSAllocatedUnfairLock(initialState: false)

    init(_ run: @escaping @MainActor () async -> Void) {
        let ended = ended
        Task {
            await run()
            ended.withLock { $0 = true }
        }
    }

    /// At the limit, this records an issue and returns, so a set that waits for an answer that no
    /// test gives fails the test and does not hold the test process.
    func ends(limit: Duration = .seconds(60)) async {
        await until(limit: limit, "the set job ends") { ended.withLock { $0 } }
    }
}

extension ExportWindowTests {
    /// The replace alert of `window`. The progress sheet of an earlier set can still close for up
    /// to 1.25 s after the set returned, and it is an attached sheet too. Only the replace alert
    /// has the Replace button.
    func replaceSheet(of window: NSWindow) -> NSWindow? {
        guard let sheet = window.attachedSheet,
            sheetButtons(sheet).contains(where: { $0.title == L10n.alertExportReplaceConfirm.text })
        else { return nil }
        return sheet
    }

    /// Waits for the replace alert itself and returns it.
    func untilReplaceSheet(of window: NSWindow) async throws -> NSWindow {
        await until("the replace sheet shows") { replaceSheet(of: window) != nil }
        return try #require(replaceSheet(of: window))
    }
}
