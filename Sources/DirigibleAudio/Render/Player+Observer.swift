import Foundation

extension Player {
    /// Made outside the actor: NotificationCenter calls it on an internal queue.
    nonisolated static func changed(_ player: Player) -> @Sendable (Notification) -> Void {
        { [weak player] _ in
            guard let player else { return }
            Task { await player.outputChanged() }
        }
    }

    /// A NotificationCenter observer for the life of the value.
    final class Observer: Sendable {
        /// NotificationCenter gives an opaque token that is only passed back to `removeObserver`.
        nonisolated(unsafe) private let token: any NSObjectProtocol

        init(_ token: any NSObjectProtocol) { self.token = token }

        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
