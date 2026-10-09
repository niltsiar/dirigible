import DirigibleAudio
import DirigibleCore
import Foundation

/// The items of File > Revert To (decision 0043): the backups of the key window, newest first.
/// A click reverts only while the window takes an edit. With no backup or no window, the menu
/// shows one item No Backups that is off.
struct RevertMenu {
    let backups: [Backup]
    let enabled: Bool

    @MainActor init(_ window: SessionWindow?) {
        backups = window?.studio?.backups ?? []
        enabled = window?.canEdit == true
    }
}

extension SessionWindow {
    /// Reverts the session to `backup` as one undo entry. VoiceOver hears the backup date. An
    /// error shows the window alert of a refused edit.
    func revert(to backup: Backup) {
        guard let studio = idleStudio else { return }
        Task {
            do throws(StudioError) {
                try await studio.revert(to: backup)
                chrome?.announce(L10n.revertedTo.format(backupTitle(backup.saved)), .high)
            } catch {
                alert = .error(error)
            }
        }
    }
}

/// The title of a backup in File > Revert To: its date and time with seconds, in the locale and
/// the time zone of the Mac. No relative "Today": it would be wrong after midnight.
func backupTitle(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    var style = Date.FormatStyle(date: .abbreviated, time: .standard, locale: locale)
    style.timeZone = timeZone
    return date.formatted(style)
}
