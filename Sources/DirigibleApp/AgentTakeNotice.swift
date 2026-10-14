import Foundation
import UserNotifications

/// The notification of an agent take that starts in the background (decision 0050, C14): the
/// take, the tracks, and the quoted name, with a Stop action. Tests give their own closures and
/// never touch the real center: a test process has no bundle for it.
struct AgentTakeNotice {
    static let category = "agent-take"
    static let stopAction = "stop"
    /// The user info key of the notice ID. The ID does not come from the path, so a move of the
    /// package or a trailing slash cannot make Stop miss the take.
    static let idKey = "id"

    /// Asks for the permission. The system shows its prompt only one time. The system calls the
    /// handler on its own queue, so the handler is not main-actor isolated.
    var authorize: @MainActor () -> Void = {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { @Sendable _, _ in }
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

    /// The notice ID of the user info of a notification.
    static func id(of info: [AnyHashable: Any]) -> String? { info[idKey] as? String }
}
