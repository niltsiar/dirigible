import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Observation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Export run criteria 26 to 28: the export items, the media question, the report, and the
/// progress sheet, on a real session window. The save panel is manual check M1: the tests give
/// the app a panel that answers at once.
@Suite(.serialized) @MainActor struct ExportWindowTests {
    static let options = ExportOptions(format: .wav(.bits16), layout: .stereo, rate: .session)
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    /// Frees the first chunk of a held export, with a limit of 30 s.
    let release = DispatchSemaphore(value: 0)
    /// The calls of the save panel.
    let panels = OSAllocatedUnfairLock(initialState: 0)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        let (target, panels) = (
            ExportTarget(url: folder.url.appending(path: "mix.wav"), options: Self.options, confirmed: nil), panels
        )
        app.chooseExport = { _, _, _, done in
            panels.withLock { $0 += 1 }
            done(target)
        }
    }

    var out: URL { folder.url.appending(path: "mix.wav") }
    var target: ExportTarget { ExportTarget(url: out, options: Self.options, confirmed: nil) }
    var panelCalls: Int { panels.withLock { $0 } }

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasSuffix(".tmp") }
    }

    /// A window of a package in `folder` (default: the test folder) with track `t1` on channel 1
    /// of `duo` (the counting HAL), and a clip of `f1`: 10 s of silence, or a missing file with
    /// `audio: false`.
    func window(audio: Bool = true, in folder: URL? = nil) async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await timelinePackage(in: folder ?? self.folder.url, tracks: 1, seconds: 10, audio: audio)
        let model = await app.open(package)
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        try studio.edit { session throws(SessionError) in
            try session.setRoute(Route(deviceUID: "duo", channels: .mono(1)), track: "t1")
        }
        return (model, studio, try #require(model.window))
    }

    /// The first chunk waits for `release` (30 s limit); the other chunks take 2 s each. So the
    /// export runs until the test acts, and a cancel after that ends it within one chunk.
    func hold(_ studio: Studio) {
        let (release, chunks) = (release, OSAllocatedUnfairLock(initialState: 0))
        studio.environment.exportChunk = {
            let first = chunks.withLock { count in
                count += 1
                return count == 1
            }
            if first {
                if release.wait(timeout: .now() + 30) == .timedOut { Issue.record("No release in 30 s") }
            } else {
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    /// Criterion 28 and probe S1 on the production window: the sheet attaches, the close button
    /// is off, and the sheet Cancel ends the export with no file and no alert.
    @Test func theProgressSheetShowsAndCancels() async throws {
        let (model, studio, window) = try await window()
        hold(studio)
        let (source, target) = (try #require(model.source(of: .session, in: studio)), target)
        let export = Task { await model.run(source, target, studio) }

        await until("the progress sheet shows") { window.attachedSheet != nil }
        #expect(window.standardWindowButton(.closeButton)?.isEnabled == false)
        let sheet = try #require(window.attachedSheet)
        try #require(sheetButton(cancel: true, in: sheet)).performClick(nil)
        release.signal()
        await export.value

        #expect(studio.exportProgress == nil)
        #expect(model.alert == nil)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try temporaryFiles() == [])
        await until("the sheet goes") { window.attachedSheet == nil }
        await model.close()
    }

    /// Criterion 28: the Record button of the sheet starts a take; the export stops with no file
    /// and no alert, and the sheet goes. The take goes on and gets its clip.
    @Test func recordInTheProgressSheetStartsATake() async throws {
        let (model, studio, window) = try await window()
        hold(studio)
        let (source, target) = (try #require(model.source(of: .session, in: studio)), target)
        let export = Task { await model.run(source, target, studio) }
        await until("the progress sheet shows") { window.attachedSheet != nil }

        let sheet = try #require(window.attachedSheet)
        try #require(sheetButton(cancel: false, in: sheet)).performClick(nil)
        release.signal()
        await export.value
        await until("the take starts") { studio.transport == .recording(take: 1) }

        #expect(studio.exportProgress == nil)
        #expect(model.alert == nil)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try temporaryFiles() == [])
        await until("the sheet goes") { window.attachedSheet == nil }
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        #expect(studio.session.track("t1")?.clips.contains { $0.file != "f1" } == true)
        await model.close()
    }

    /// Code gate 1, item 1: a Record in the sheet that the route check refuses keeps the export,
    /// and the sheet shows the error at once. No window alert waits behind the sheet. The error
    /// goes when the export ends.
    @Test func aRefusedRecordInTheSheetShowsItsError() async throws {
        let (model, studio, window) = try await window()
        try studio.edit { session throws(SessionError) in
            try session.setRoute(Route(deviceUID: "duo", channels: .mono(3)), track: "t1")
        }
        hold(studio)
        let (source, target) = (try #require(model.source(of: .session, in: studio)), target)
        let export = Task { await model.run(source, target, studio) }
        await until("the progress sheet shows") { window.attachedSheet != nil }

        let sheet = try #require(window.attachedSheet)
        try #require(sheetButton(cancel: false, in: sheet)).performClick(nil)
        await until("the take start ends") { model.recordRefusal != nil || model.alert != nil }

        #expect(model.recordRefusal == .channelOutOfRange("t1"))
        #expect(model.alert == nil)
        #expect(studio.exportProgress != nil && window.attachedSheet != nil)
        model.cancelExport()
        release.signal()
        await export.value
        #expect(model.recordRefusal == nil)
        #expect(model.alert == nil)
        await model.close()
    }

    /// Code gate 1, item 2: Record in window A ends the export of window B before the take
    /// starts, and B tells why. The app gives each studio the studios of the other windows.
    @Test func recordInAnotherWindowEndsTheExport() async throws {
        let (modelA, studioA, _) = try await window()
        let other = folder.url.appending(path: "b")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let (modelB, studioB, _) = try await window(in: other)
        hold(studioB)
        let targetB = ExportTarget(url: other.appending(path: "mix.wav"), options: Self.options, confirmed: nil)
        let source = try #require(modelB.source(of: .session, in: studioB))
        let export = Task { await modelB.run(source, targetB, studioB) }
        await until("B exports") { studioB.exportProgress != nil }

        let record = Task { await modelA.record() }
        release.signal()
        await record.value
        await export.value

        #expect(studioA.transport == .recording(take: 1))
        #expect(modelB.alert == .error(.exportYielded))
        #expect(!FileManager.default.fileExists(atPath: targetB.url.path))
        await hal.feed(seconds: 0.5)
        await modelA.stop()
        await until("the take finalizes") { studioA.transport == .idle }
        await modelA.close()
        await modelB.close()
    }

    /// Criterion 26: Export needs an idle studio with no pending take, no export step, and no
    /// export; Export Selection also needs a selection. Record stays on during the media check
    /// and the export, and is off during the question and the panel.
    @Test func theExportItemsFollowTheState() async throws {
        let (model, studio, _) = try await window()
        #expect(model.canExport && !model.canExportSelection && model.canRecord)
        #expect(!model.isOn(.exportSelection) && model.isOn(.showInFinder))
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        #expect(model.canExportSelection && model.isOn(.export) && model.isOn(.exportSelection))

        let asking = ExportStep.asking(try #require(model.source(of: .session, in: studio)), [:])
        for (step, record) in [(ExportStep.checking, true), (asking, false), (.choosing, false)] {
            model.exportStep = step
            #expect(!model.canExport && !model.canExportSelection, "\(step)")
            #expect(model.canRecord == record, "\(step)")
        }
        model.exportStep = nil

        hold(studio)
        let (source, target) = (try #require(model.source(of: .session, in: studio)), target)
        let export = Task { await model.run(source, target, studio) }
        await until("the export starts") { studio.exportProgress != nil }
        #expect(!model.canExport && !model.canExportSelection && !model.isOn(.export))
        #expect(model.canRecord)
        model.cancelExport()
        release.signal()
        await export.value

        await model.record()
        #expect(!model.canExport && !model.canExportSelection)
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        #expect(model.canExport)

        let clips = model.url.appending(path: clipsFolderName)
        await model.record()
        await hal.feed(seconds: 0.5)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }
        await model.stop()
        await until("the finalize fails") { studio.transport == .idle }
        try #require(studio.pendingTake != nil)
        #expect(!model.canExport && !model.canExportSelection)
        await model.close()
    }

    /// Criterion 26: a take start during the media check drops the check result: no question, no
    /// panel, and Export is on again. The first step of a take start makes the studio busy, so the
    /// test sets that step when the check starts.
    @Test func aTakeDuringTheMediaCheckDropsItsResult() async throws {
        let (model, studio, _) = try await window()
        withObservationTracking {
            _ = model.exportStep
        } onChange: {
            MainActor.assumeIsolated { studio.isStarting = true }
        }

        await model.export(.session)

        #expect(model.exportStep == nil)
        #expect(panelCalls == 0)
        studio.isStarting = false
        #expect(model.canExport)
        await model.close()
    }

    /// Criterion 27: a file with a fault in the range asks first, with its path. Cancel ends the
    /// flow with no panel. Export opens the panel, and the report names the file.
    @Test func aMissingFileAsksFirst() async throws {
        let (model, studio, _) = try await window(audio: false)

        await model.export(.session)

        guard case .asking(_, let faults) = model.exportStep else {
            Issue.record("No question: \(String(describing: model.exportStep))")
            return
        }
        #expect(faults == ["f1": .missing])
        #expect(model.exportQuestionPaths == ["f1.wav"])
        #expect(panelCalls == 0)
        model.answerExportQuestion(export: false)
        #expect(model.exportStep == nil && panelCalls == 0)

        await model.export(.session)
        model.answerExportQuestion(export: true)
        #expect(panelCalls == 1)
        await until("the report shows") { model.alert != nil }
        #expect(model.alert == .exported(["f1.wav"]))
        #expect(FileManager.default.fileExists(atPath: out.path) && studio.exportProgress == nil)
        await model.close()
    }

    /// Criterion 27: with no fault, Export goes to the panel at once, and a clean export shows no
    /// alert.
    @Test func aWholeSessionExportsWithNoQuestion() async throws {
        let (model, studio, _) = try await window()

        await model.export(.session)

        #expect(panelCalls == 1)
        await until("the export ends") {
            FileManager.default.fileExists(atPath: out.path) && studio.exportProgress == nil
        }
        #expect(model.exportStep == nil)
        #expect(model.alert == nil)
        let file = try AVAudioFile(forReading: out)
        #expect(file.length == 480_000 && file.fileFormat.channelCount == 2)
        await model.close()
    }

    /// Criterion 28: a failed export shows the message of its error, and Export is on again.
    @Test func aFailedExportShowsItsError() async throws {
        let (model, studio, _) = try await window()
        let source = try #require(model.source(of: .session, in: studio))
        let missing = ExportTarget(
            url: folder.url.appending(path: "none/mix.wav"), options: Self.options, confirmed: nil)

        await model.run(source, missing, studio)

        guard case .error(.export) = model.alert else {
            Issue.record("No export error: \(String(describing: model.alert))")
            return
        }
        #expect(model.canExport)
        await model.close()
    }
}

/// A button of the progress sheet: Cancel has the Escape key (`.cancelAction`), Record has no
/// key. SwiftUI gives the buttons no accessibility label, so the key tells them apart.
@MainActor func sheetButton(cancel: Bool, in sheet: NSWindow) -> NSButton? {
    func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    sheet.contentView?.layoutSubtreeIfNeeded()
    return sheet.contentView.map(buttons)?.first { ($0.keyEquivalent == "\u{1b}") == cancel }
}
