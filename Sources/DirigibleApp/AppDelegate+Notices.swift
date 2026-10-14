import AppKit
import UserNotifications

/// The Stop action of the notification of an agent take (decision 0050, C14).
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Registers the category with Stop and takes the actions. Only the launch calls it.
    func watchNotices() {
        let stop = UNNotificationAction(identifier: AgentTakeNotice.stopAction, title: L10n.transportStop.text)
        let category = UNNotificationCategory(
            identifier: AgentTakeNotice.category, actions: [stop], intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == AgentTakeNotice.stopAction else { return }
        let info = response.notification.request.content.userInfo
        guard let path = info[AgentTakeNotice.packageKey] as? String,
            let take = (info[AgentTakeNotice.takeKey] as? String).flatMap(Int.init)
        else { return }
        await noticeStop(URL(filePath: path), take: take)
    }

    /// Stop of a notification: it ends only that agent take, while it records.
    func noticeStop(_ package: URL, take: Int) async {
        await windows[package]?.stopAgentTake(take)
    }
}
