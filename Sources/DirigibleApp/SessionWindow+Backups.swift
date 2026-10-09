import DirigibleAudio
import DirigibleCore
import Foundation

/// The items of File > Revert To (decision 0043): the backups of the key window, newest first.
/// A click reverts only while the window takes an edit. With no backup or no window, the menu
/// shows one item No Backups that is off.
struct RevertMenu {
    let backups: [Backup]
    /// The title of each backup, in the order of `backups`.
    let titles: [String]
    let enabled: Bool

    @MainActor init(_ window: SessionWindow?) {
        backups = window?.studio?.backups ?? []
        titles = backupTitles(backups)
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
func backupTitle(
    _ date: Date, milliseconds: Bool = false, locale: Locale = .current, timeZone: TimeZone = .current
) -> String {
    var style = Date.FormatStyle(date: .abbreviated, time: .standard, locale: locale)
    if milliseconds { style = style.secondFraction(.fractional(3)) }
    style.timeZone = timeZone
    return date.formatted(style)
}

/// The titles of `backups`, in their order. A title that two backups share gets milliseconds, so
/// two items of the menu never have one title.
func backupTitles(_ backups: [Backup], locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
    let titles = backups.map { backupTitle($0.saved, locale: locale, timeZone: timeZone) }
    return zip(backups, titles).map { backup, title in
        titles.filter { $0 == title }.count > 1
            ? backupTitle(backup.saved, milliseconds: true, locale: locale, timeZone: timeZone) : title
    }
}
