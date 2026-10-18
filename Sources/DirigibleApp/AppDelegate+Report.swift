import AppKit
import DirigibleAudio

/// The windows and the collect of Help > Report a Problem... Tests give their own, so no sheet,
/// panel, or alert shows and no bundle is made.
struct ReportPanels {
    /// The sheet, and the answer: true for Save Report....
    var sheet: @MainActor (NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void = ReportWindows.sheet
    /// The save panel with a default name, and the chosen file. Nil: Cancel.
    var save: @MainActor (NSWindow?, String, @escaping @MainActor (URL?) -> Void) -> Void = ReportWindows.save
    /// The progress sheet with its Cancel action. The result hides it.
    var progress: @MainActor (NSWindow?, @escaping @MainActor () -> Void) -> @MainActor () -> Void =
        ReportWindows.progress
    /// The alert of a failed report, with the name of the folder and the cause.
    var fail: @MainActor (NSWindow?, String, String) -> Void = ReportWindows.fail
    /// Writes the zip at the first URL from the journals in the second URL.
    var collect: @MainActor (URL, URL) async -> Result<DiagnosticBundle.Collected, BundleError> = { zip, logs in
        let facts = AppDelegate.buildFacts
        do throws(BundleError) {
            return .success(
                try await DiagnosticBundle.collect(
                    to: zip, logs: logs, reports: DiagnosticBundle.reportFolders, version: facts.version,
                    commit: facts.commit))
        } catch {
            return .failure(error)
        }
    }
    /// A collect that takes longer than this shows the progress sheet.
    var progressDelay = Duration.seconds(1)
}

/// The progress sheet of one report and the answer to its Cancel.
@MainActor private final class ReportRun {
    private(set) var cancelled = false
    private var hide: (@MainActor () -> Void)?

    func show(_ hide: @escaping @MainActor () -> Void) { self.hide = hide }

    func cancel() {
        cancelled = true
        finish()
    }

    func finish() {
        hide?()
        hide = nil
    }
}

/// The notice after a launch whose earlier launch ended with no quit line (decision 0059). It
/// shows in the first window that shows, until Not Now or Report a Problem.... The journal of the
/// earlier launch holds the state, so each unclean end gives one notice.
struct UncleanNotice: Equatable {
    private enum State: Equatable {
        case none, waiting
        case showing(ObjectIdentifier)
    }

    private var state: State

    init(previousEndedUnclean: Bool) { state = previousEndedUnclean ? .waiting : .none }

    func shows(in window: ObjectIdentifier) -> Bool { state == .showing(window) }

    /// A window shows. The first one after the launch gets the notice.
    mutating func windowShown(_ window: ObjectIdentifier) {
        if state == .waiting { state = .showing(window) }
    }

    mutating func dismiss() { state = .none }
}

extension AppDelegate {
    /// The version and the commit of the app bundle. A build with no bundle has the defaults.
    static var buildFacts: (version: String, commit: String) {
        let info = Bundle.main.infoDictionary
        return (
            info?["CFBundleShortVersionString"] as? String ?? "0.0.0", info?["DirigibleCommit"] as? String ?? "none"
        )
    }

    /// `Dirigible Report <yyyy-MM-dd>.zip`: `format` has one `%@` for the day.
    static func reportFileName(on date: Date, format: String = L10n.reportFileName.text) -> String {
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        return String(format: format, day) + ".zip"
    }

    /// The window that gets the sheet: the start window when it is key, else the key session window,
    /// else any session window that shows, else the start window. Nil: no window.
    var reportHost: NSWindow? {
        if let start = start?.window, start.isKeyWindow { return start }
        return key?.window ?? windows.values.compactMap(\.window).first { $0.isVisible } ?? start?.window
    }

    /// A window shows: the first one after an unclean end gets the notice.
    func noticeWindowShown(_ window: NSWindow?) {
        guard let window else { return }
        if !noticeRead {
            noticeRead = true
            uncleanNotice = UncleanNotice(previousEndedUnclean: log.previousEndedUnclean)
        }
        let id = ObjectIdentifier(window)
        let showedBefore = uncleanNotice.shows(in: id)
        uncleanNotice.windowShown(id)
        if !showedBefore && uncleanNotice.shows(in: id) {
            postAnnouncement(L10n.noticeUncleanText.text, priority: .medium)
        }
    }

    /// Help > Report a Problem... and the button of the notice: the sheet, then the save panel,
    /// then the collect.
    func reportProblem() {
        noticeRead = true
        uncleanNotice.dismiss()
        panels.sheet(reportHost) { [weak self] saves in
            guard saves, let self else { return }
            panels.save(reportHost, Self.reportFileName(on: .now)) { [weak self] url in
                guard let self, let url else { return }
                Task { await self.writeReport(to: url) }
            }
        }
    }

    /// Makes the zip at `url`, which the save panel confirmed. The collect writes to a hidden file
    /// next to `url`, and the zip replaces `url` only when the collect succeeds. The progress
    /// sheet shows when the collect takes longer than `progressDelay`. Then a VoiceOver
    /// announcement, and Finder shows the file. A Cancel of the progress sheet drops the result.
    func writeReport(to url: URL) async {
        let host = reportHost
        let (panels, logFolder) = (panels, logFolder)
        let run = ReportRun()
        let timer = Task {
            try? await Task.sleep(for: panels.progressDelay)
            if !Task.isCancelled { run.show(panels.progress(host) { run.cancel() }) }
        }
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appending(path: ".Dirigible-report-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = await panels.collect(temporary, logFolder)
        timer.cancel()
        run.finish()
        if run.cancelled { return }
        let name = FileManager.default.displayName(atPath: folder.path)
        switch result {
        case .success:
            do {
                try Self.place(temporary, at: url)
            } catch {
                return panels.fail(host, name, error.cause)
            }
            postAnnouncement(L10n.reportSaved.text, priority: .high)
            reveal([url])
        case .failure(let error):
            panels.fail(host, name, error.cause)
        }
    }

    /// Moves `zip` to `url`, and replaces the file that is there.
    private static func place(_ zip: URL, at url: URL) throws(BundleError) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: zip)
            } else {
                try FileManager.default.moveItem(at: zip, to: url)
            }
        } catch {
            throw .cannotWrite("the file cannot be replaced")
        }
    }
}

extension BundleError {
    /// The reason in English, as the library gives it.
    fileprivate var cause: String {
        switch self {
        case .exists: "a file or a folder is at that place"
        case .cannotWrite(let reason): reason
        }
    }
}
