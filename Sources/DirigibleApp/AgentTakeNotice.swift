import Foundation
import UserNotifications

/// The notification of an agent take that starts in the background (decision 0050, C14): the
/// take, the tracks, and the quoted name, with a Stop action. Tests give their own closures and
/// never touch the real center: a test process has no bundle for it.
struct AgentTakeNotice {
    static let category = "agent-take"
    static let stopAction = "stop"
    /// The user info keys: the package path and the take number.
    static let packageKey = "package"
    static let takeKey = "take"

    /// Asks for the permission. The system shows its prompt only one time.
    var authorize: @MainActor () -> Void = {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
    var post: @MainActor (_ id: String, _ title: String, _ body: String, _ info: [String: String]) -> Void = {
        id, title, body, info in
        let content = UNMutableNotificationContent()
        (content.title, content.body, content.userInfo) = (title, body, info)
        content.categoryIdentifier = AgentTakeNotice.category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    var remove: @MainActor (_ id: String) -> Void = {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [$0])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [$0])
    }

    /// The identifier of the notification of `take` in `package`.
    static func id(_ package: URL, take: Int) -> String { "\(category) \(take) \(package.path)" }
}
