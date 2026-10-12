import Foundation

extension Player {
    /// A NotificationCenter observer for the life of the value.
    final class Observer: Sendable {
        /// NotificationCenter gives an opaque token that is only passed back to `removeObserver`.
        nonisolated(unsafe) private let token: any NSObjectProtocol

        init(_ token: any NSObjectProtocol) { self.token = token }

        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
