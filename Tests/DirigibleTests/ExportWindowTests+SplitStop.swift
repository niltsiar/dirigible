import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Holds the export in the chunk loop of the part whose temporary file starts with `prefix` in
/// `folder`, until `release`.
final class PartHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let (folder, prefix): (URL, String)
    private var held = false

    init(folder: URL, prefix: String) { (self.folder, self.prefix) = (folder, prefix) }

    var isHeld: Bool { lock.withLock { held } }

    func step() {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let hold = lock.withLock {
            guard !held, items.contains(where: { $0.hasPrefix(prefix) }) else { return false }
            held = true
            return true
        }
        if hold { semaphore.wait() }
    }

    func release() { semaphore.signal() }
}

/// Run 2026-10-28-chapter-export-files, C15: the progress sheet text and the stops of a set. The set
/// of three files is held once in part 2.
extension ExportWindowTests {
    func heldSet() async throws -> (SessionWindow, Studio, NSWindow, PartHold, Task<Void, Never>) {
        let (model, studio, nsWindow) = try await window()
        try threeChapters(studio)
        let hold = PartHold(folder: folder.url, prefix: ".Ep-02")
        studio.environment.exportChunk = { hold.step() }
        let (source, target) = (try #require(model.source(of: .session, in: studio)), setTarget())
        let split = try #require(target.split)
        let task = Task { await model.runSet(source, target.options, split, studio) }
        await until("the set holds in part 2") { hold.isHeld }
        await until("the progress hop names part 2") { studio.exportFile?.number == 2 }
        return (model, studio, nsWindow, hold, task)
    }

    @Test func theSheetShowsTheFilePlace() async throws {
        let (model, studio, _, hold, task) = try await heldSet()
        defer { hold.release() }

        let file = try #require(studio.exportFile)
        #expect((file.number, file.count, file.name) == (2, 3, "Ep-02-Talk.wav"))
        #expect(exportSheetTitle(file) == L10n.sheetExportFile.format(2, 3, "Ep-02-Talk.wav"))
        #expect(exportSheetTitle(nil) == L10n.sheetExportTitle.text)
        hold.release()
        await task.value
        await model.close()
    }

    @Test func cancelInTheSheetShowsTheCountBanner() async throws {
        let (model, studio, nsWindow, hold, task) = try await heldSet()
        let sheet = try #require(nsWindow.attachedSheet)
        try #require(sheetButton(cancel: true, in: sheet)).performClick(nil)
        hold.release()
        await task.value

        #expect(model.alert == nil, "a stop shows no alert")
        #expect(ChromeState.reportBanners(model, studio) == [.exportSetStopped(written: 1, count: 3)])
        #expect(try setFiles() == ["Ep-01-Intro.wav"])
        #expect(try temporaryFiles() == [])
        await model.close()
    }

    @Test func aTakeInAnotherWindowShowsTheCountBanner() async throws {
        let (model, studio, _, hold, task) = try await heldSet()
        let end = Task { await studio.endExport(.take, yielding: true) }
        await until("the stop reached the job") { studio.exportStop == .take }
        hold.release()
        await task.value
        await end.value

        #expect(model.alert == nil)
        #expect(ChromeState.reportBanners(model, studio) == [.exportSetStopped(written: 1, count: 3)])
        #expect(try setFiles() == ["Ep-01-Intro.wav"] && (try temporaryFiles()) == [])
        await model.close()
    }

    @Test func aFailedPartShowsItsErrorAndTheCount() async throws {
        let (model, studio, _, hold, task) = try await heldSet()
        chmod(folder.url.path, 0o500)
        defer { chmod(folder.url.path, 0o755) }
        hold.release()
        await task.value

        guard case .error(let error)? = model.alert, case .exportParts(.stopped(let stop)) = error else {
            Issue.record("No alert for the failed part: \(String(describing: model.alert))")
            return
        }
        #expect(stop.written.count == 1 && stop.remaining.count == 2 && stop.error != .cancelled)
        #expect(L10n.message(for: error).hasSuffix(L10n.bannerExportSetStopped.format(1, 3)), "no count sentence")
        #expect(studio.exportProgress == nil)
        await model.close()
    }
}
