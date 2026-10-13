import DirigibleAudio
import DirigibleCore

/// The result of the last Remove Unused Files and the session revision after it: the banners
/// go at the next change of the session.
struct PruneReportShown: Equatable {
    let report: PruneReport
    let revision: Int
}

extension SessionWindow {
    /// File > Remove Unused Files… (decision 0047): the scan, then the confirmation sheet. With no
    /// file to move, an alert says so with the kept line. With a busy studio, it does nothing. A
    /// typed track name saves first. The app clipboard keeps the files of its clips.
    func removeUnusedFiles() {
        guard let studio = idleStudio else { return }
        commitDrafts()
        pruneReport = nil
        Task {
            do throws(StudioError) {
                let scan = try await studio.unusedFiles(clipboard: app?.clipboard)
                if scan.items.isEmpty { alert = .noUnusedFiles(scan) } else { unusedFiles = scan }
            } catch {
                alert = .error(error)
            }
        }
    }

    /// Move to Trash in the sheet: the studio scans again and moves the files that are in both
    /// lists. A banner gives the count and the size, and an error banner names each file that
    /// did not move. A studio that became busy refuses, and the alert says so, unless the window
    /// closes.
    func moveUnusedFiles(_ scan: UnusedFiles) {
        unusedFiles = nil
        guard case .open(let studio) = phase else { return }
        Task {
            do throws(StudioError) {
                let report = try await studio.removeUnusedFiles(scan, clipboard: app?.clipboard)
                pruneReport = PruneReportShown(report: report, revision: studio.sessionRevision)
            } catch {
                // A window that closes refuses as busy; the close owns its alerts.
                guard case .open = phase else { return }
                alert = .error(error)
            }
        }
    }
}
