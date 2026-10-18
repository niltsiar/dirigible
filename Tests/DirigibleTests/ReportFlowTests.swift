import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Help > Report a Problem... and the notice after an unclean end (decision 0059, criteria C33 to
/// C36). The sheet, the panel, and the alert are seams: the sheet on a window is real, the rest
/// are recorders. The windows and the Finder reveal on the screen are a manual check (M3, M4).
@Suite(.serialized) @MainActor struct ReportFlowTests {
    let folder: TemporaryFolder
    let app: AppDelegate

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        app = AppDelegate(recordings: nil, defaultFolder: folder.url.appending(path: "Music/Dirigible"))
    }

    enum Front: CaseIterable { case session, start, none }

    /// C33: the sheet opens on the session window in front, on the start window when it is the
    /// only window, and in no window (the app-modal window) when there is none.
    @Test(arguments: Front.allCases)
    func theMenuItemOpensTheReportOnTheFrontWindow(front: Front) async throws {
        var hosts: [NSWindow?] = []
        app.panels.sheet = { host, _ in hosts.append(host) }
        var expected: NSWindow?
        switch front {
        case .session: expected = await app.open(try folder.package("a")).window
        case .start:
            app.showStart()
            expected = app.start?.window
        case .none: break
        }
        try #require(front == .none || expected != nil)

        app.reportProblem()

        let host = try #require(hosts.first)
        #expect(hosts.count == 1 && host === expected, "\(front)")
        for window in app.windows.values { await window.close() }
        app.start?.close()
    }

    /// C34: the day is in the name, and the name ends in .zip.
    @Test func theDefaultNameHasTheDate() throws {
        let day = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12)))

        #expect(AppDelegate.reportFileName(on: day, format: "Dirigible Report %@") == "Dirigible Report 2026-10-07.zip")
    }

    /// C34: Return saves and Escape cancels, and the sheet is gone when the answer comes.
    @Test(arguments: [true, false]) func theSheetButtonsHaveTheDefaultAndCancelKeys(saves: Bool) async throws {
        let host = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        var answer: Bool?
        ReportWindows.sheet(on: host) { answer = $0 }
        let sheet = try #require(host.attachedSheet)
        await until(limit: .seconds(10), "the sheet draws its buttons") {
            sheet.contentView?.layoutSubtreeIfNeeded()
            return !buttons(sheet.contentView).isEmpty
        }

        let event = key(
            .keyDown, saves ? "\r" : "\u{1b}", code: saves ? 36 : 53, in: sheet)
        if !sheet.performKeyEquivalent(with: event) { sheet.sendEvent(event) }

        await until(limit: .seconds(10), "the sheet answers and goes") { answer == saves && host.attachedSheet == nil }
        host.close()
    }

    func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }

    /// The seams of one report: the progress sheet counts, and the collect waits for `release`.
    final class Run {
        var shown = 0
        var hidden = 0
        var cancel: (@MainActor () -> Void)?
        var revealed: [URL] = []
        /// The path that each collect got.
        var zips: [URL] = []
        var failures: [(folder: String, cause: String)] = []
        let gate: AsyncStream<Void>
        let release: AsyncStream<Void>.Continuation

        init() {
            let pair = AsyncStream.makeStream(of: Void.self)
            gate = pair.stream
            release = pair.continuation
        }
    }

    func prepare(_ run: Run, waits: Bool, delay: Duration, result: Result<DiagnosticBundle.Collected, BundleError>) {
        app.panels.progressDelay = delay
        app.panels.progress = { _, cancel in
            run.shown += 1
            run.cancel = cancel
            return { run.hidden += 1 }
        }
        app.panels.fail = { _, folder, cause in run.failures.append((folder, cause)) }
        app.panels.collect = { zip, _ in
            run.zips.append(zip)
            if waits { for await _ in run.gate { break } }
            if case .success = result { try? Data("zip".utf8).write(to: zip) }
            return result
        }
        app.reveal = { run.revealed += $0 }
    }

    let collected = DiagnosticBundle.Collected(logs: 1, reports: 0, skipped: [])

    /// C35: the progress sheet shows only for a collect that outlasts the delay (1 s by default).
    @Test(arguments: [true, false]) func progressShowsOnlyAfterTheDelay(slow: Bool) async throws {
        #expect(ReportPanels().progressDelay == .seconds(1))
        let run = Run()
        prepare(run, waits: slow, delay: slow ? .milliseconds(50) : .seconds(60), result: .success(collected))
        let url = folder.url.appending(path: "Report.zip")

        let writing = Task { await app.writeReport(to: url) }
        if slow {
            await until("the progress sheet shows") { run.shown == 1 }
            run.release.yield()
        }
        await writing.value

        #expect(run.shown == (slow ? 1 : 0) && run.hidden == run.shown)
        #expect(run.revealed == [url], "the saved file shows in Finder")
    }

    /// C35 and decision 0010: a write failure names the folder and the table text of its case, and
    /// the file does not show in Finder. The English reason of the library never reaches the alert.
    @Test(arguments: [
        (BundleError.exists, L10n.reportErrorExists), (.folderMissing, .reportErrorFolder),
        (.noPermission, .reportErrorPermission), (.tempFolder, .reportErrorTemporary),
        (.zipFailed(code: 640), .reportErrorZip),
    ]) func aFailedWriteNamesTheCauseAndTheFolder(error: BundleError, text: L10n) async {
        let run = Run()
        prepare(run, waits: false, delay: .seconds(60), result: .failure(error))

        await app.writeReport(to: folder.url.appending(path: "Report.zip"))

        let expected = error == .zipFailed(code: 640) ? text.format(640) : text.text
        #expect(run.failures.map(\.cause) == [expected])
        #expect(run.failures.map(\.folder) == [folder.url.lastPathComponent])
        #expect(run.revealed.isEmpty)
    }

    /// The text of each case differs, so a user can tell the causes apart.
    @Test func eachFailureCaseHasItsOwnText() {
        let errors: [BundleError] = [.exists, .folderMissing, .noPermission, .tempFolder, .zipFailed(code: 1)]

        #expect(Set(errors.map { L10n.message(for: $0) }).count == errors.count)
    }

    /// A folder for one report, so the test sees each file that the report leaves.
    func reportFolder() throws -> URL {
        let url = folder.url.appending(path: "Desktop")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func names(in folder: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path) }

    /// C35: Cancel on the progress sheet hides it, drops the late zip, and shows nothing. The
    /// file that the panel asked to replace stays, and no temporary file stays.
    @Test(arguments: [true, false]) func cancelDropsTheLateReport(replacing: Bool) async throws {
        let run = Run()
        prepare(run, waits: true, delay: .milliseconds(50), result: .success(collected))
        let desktop = try reportFolder()
        let url = desktop.appending(path: "Report.zip")
        if replacing { try Data("old".utf8).write(to: url) }

        let writing = Task { await app.writeReport(to: url) }
        await until("the progress sheet shows") { run.shown == 1 }
        run.cancel?()
        run.release.yield()
        await writing.value

        #expect(run.hidden == 1 && run.revealed.isEmpty && run.failures.isEmpty)
        #expect(try names(in: desktop) == (replacing ? ["Report.zip"] : []), "the late zip is removed")
        if replacing { #expect(try Data(contentsOf: url) == Data("old".utf8), "the old file stays") }
    }

    /// A report never deletes a file unless its new zip replaces it: the collect writes to its own
    /// path, and a failed collect leaves the old file.
    @Test func aFailedCollectKeepsTheFileItWouldReplace() async throws {
        let run = Run()
        prepare(run, waits: false, delay: .seconds(60), result: .failure(.noPermission))
        let desktop = try reportFolder()
        let url = desktop.appending(path: "Report.zip")
        try Data("old".utf8).write(to: url)

        await app.writeReport(to: url)

        #expect(run.failures.count == 1 && run.zips.count == 1 && run.zips[0] != url)
        #expect(try Data(contentsOf: url) == Data("old".utf8), "the old file stays")
        #expect(try names(in: desktop) == ["Report.zip"], "no temporary file stays")
    }

    /// A saved report replaces the file that the panel confirmed, and a new name gets the zip.
    @Test(arguments: [true, false]) func aSavedReportReplacesTheOldFile(replacing: Bool) async throws {
        let run = Run()
        prepare(run, waits: false, delay: .seconds(60), result: .success(collected))
        let desktop = try reportFolder()
        let url = desktop.appending(path: "Report.zip")
        if replacing { try Data("old".utf8).write(to: url) }

        await app.writeReport(to: url)

        #expect(try Data(contentsOf: url) == Data("zip".utf8), "the new zip is at the chosen name")
        #expect(try names(in: desktop) == ["Report.zip"], "no temporary file stays")
        #expect(run.revealed == [url] && run.failures.isEmpty)
    }

    /// C36: the notice goes to the first window that shows, once, and Not Now ends it. A launch
    /// after a clean end has none.
    @Test func theNoticeShowsOnceForEachUncleanEnd() {
        let (one, two) = (NSObject(), NSObject())
        let (first, second) = (ObjectIdentifier(one), ObjectIdentifier(two))
        defer { withExtendedLifetime((one, two)) {} }
        var launch = UncleanNotice(previousEndedUnclean: true)

        launch.windowShown(first)
        launch.windowShown(second)
        #expect(launch.shows(in: first) && !launch.shows(in: second), "the first window only")

        launch.dismiss()
        launch.windowShown(second)
        #expect(!launch.shows(in: first) && !launch.shows(in: second), "Not Now ends it")

        var clean = UncleanNotice(previousEndedUnclean: false)
        clean.windowShown(first)
        #expect(!clean.shows(in: first), "no notice after a clean end")
    }

    /// C36: the launch reads the earlier journal, and the start window shows the notice.
    @Test(arguments: [true, false]) func anUncleanEarlierLaunchGivesTheStartWindowTheNotice(unclean: Bool) throws {
        let logs = folder.url.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let last = unclean ? "take\tstart-request" : "app\tquit"
        let text = """
            dirigible-journal 1
            time\tuptime_ms\tthread\tlevel\tcategory\tevent\tfields...
            2026-10-15T10:00:00.000Z\t1\tmain\tnotice\tapp\tlaunch\tversion=0.4.8
            2026-10-15T10:05:00.000Z\t2\tmain\tnotice\t\(last)

            """
        try Data(text.utf8).write(to: logs.appending(path: "2026-10-15-100000-app-100000.tsv"))
        let app = AppDelegate(recordings: nil, defaultFolder: folder.url, logFolder: logs)

        app.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        app.showStart()

        #expect((app.start?.model.noticeApp != nil) == unclean)
        app.start?.close()
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}
