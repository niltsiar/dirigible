import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// Polls `condition` every 10 ms. At the limit, it records `message` as an issue and returns.
@MainActor func until(limit: Duration = .seconds(10), _ message: String, _ condition: () -> Bool) async {
    let end = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < end else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A unique temporary folder under `parent`, removed at deinit.
final class TemporaryFolder {
    let url: URL

    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appending(path: "DirigibleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// A new session package in the folder.
    func package(_ name: String) throws -> URL {
        let url = url.appending(path: "\(name).dirigible")
        try Session.create(at: url, sampleRate: 48_000)
        return url
    }
}

extension SessionWindow {
    /// Waits until the open of the package ends with a studio.
    func opened() async -> Bool {
        await until("the window opens its package") { studio != nil }
        return studio != nil
    }
}
