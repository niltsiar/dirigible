import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 9a criterion 20: the loudness report of an export with a target, on a real session
/// window. The tests are in the serialized suite `ExportWindowTests` and use its fixtures.
extension ExportWindowTests {
    /// Run 9a criterion 20: a clean export with a target shows the report in a banner, not in a
    /// modal alert, and VoiceOver reads it. The next export start removes it.
    @Test func aTargetExportShowsTheReportBanner() async throws {
        let (model, studio, _) = try await window()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        let source = try #require(model.source(of: .session, in: studio))

        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)

        #expect(model.alert == nil, "the report is a modal alert: \(String(describing: model.alert))")
        let report = try #require(model.exportReport?.report)
        await until("the report banner shows") { model.shown.banners.contains(.exportReport(report, file: "mix.wav")) }
        #expect(heard.contains(WindowBanner.exportReport(report, file: "mix.wav").text), "no announcement: \(heard)")
        let off = ExportTarget(url: folder.url.appending(path: "off.wav"), options: Self.options, confirmed: nil)
        await model.run(source, off, studio)
        #expect(model.exportReport == nil)
        await until("the report banner goes") { !model.shown.banners.contains { $0.key == "exportReport" } }
        await model.close()
    }

    /// Run 9a criterion 20: no modal alert or sheet holds the window while the report shows, so
    /// Record starts a take, and the take start removes the report.
    @Test func recordStartsWhileTheReportShows() async throws {
        let (model, studio, window) = try await window()
        let source = try #require(model.source(of: .session, in: studio))
        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)
        await until("the report banner shows") { model.shown.banners.contains { $0.key == "exportReport" } }
        // The progress sheet ends its close after the export; under load it shows a little longer.
        await until("the progress sheet goes") { window.attachedSheet == nil }
        #expect(model.alert == nil && model.canRecord)
        #expect(model.shown.banners.contains { $0.key == "exportReport" }, "the report went with the sheet")

        await model.record()

        #expect(studio.transport == .recording(take: 1))
        #expect(model.exportReport == nil)
        await until("the report banner goes") { !model.shown.banners.contains { $0.key == "exportReport" } }
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// Run 9a criterion 20: with a silent file, one alert names the file and has the report, and
    /// no banner shows.
    @Test func silentFilesAndTheReportShareOneAlert() async throws {
        let (model, studio, _) = try await window(audio: false)
        let source = try #require(model.source(of: .session, in: studio))

        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)

        guard case .exported(let paths, let report) = model.alert else {
            Issue.record("No report alert: \(String(describing: model.alert))")
            return
        }
        #expect(paths == ["f1.wav"] && report != nil, "\(paths) \(String(describing: report))")
        #expect(model.exportReport == nil)
        await model.close()
    }

    /// Code gate 1: the banner names the exported file, and the first session edit after the
    /// export removes it, because the file no longer matches the session.
    @Test func aSessionEditRemovesTheReport() async throws {
        let (model, studio, _) = try await window()
        let source = try #require(model.source(of: .session, in: studio))
        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)
        let report = try #require(model.exportReport?.report)
        await until("the report banner shows") {
            model.shown.banners.contains(.exportReport(report, file: "mix.wav"))
        }

        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Renamed") }

        await until("the report banner goes") { !model.shown.banners.contains { $0.key == "exportReport" } }
        await model.close()
    }

    /// Code gate 2: an edit while the export runs is not in the file, so no report banner shows
    /// after the export.
    @Test func anEditDuringTheExportShowsNoReport() async throws {
        let (model, studio, _) = try await window()
        // The first chunk waits for the release; the other chunks run at once.
        let (release, first) = (release, OSAllocatedUnfairLock(initialState: true))
        studio.environment.exportChunk = {
            let isFirst = first.withLock { value in
                defer { value = false }
                return value
            }
            guard isFirst else { return }
            if release.wait(timeout: .now() + 30) == .timedOut { Issue.record("No release in 30 s") }
        }
        let source = try #require(model.source(of: .session, in: studio))
        let target = ExportTarget(url: out, options: Self.podcast, confirmed: nil)
        let export = Task { await model.run(source, target, studio) }
        await until("the export starts") { studio.exportProgress != nil }

        try studio.edit { session throws(SessionError) in try session.renameTrack("t1", to: "Renamed") }
        release.signal()
        await export.value

        #expect(model.exportReport != nil && model.alert == nil, "the export did not end clean")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!model.shown.banners.contains { $0.key == "exportReport" }, "a report for a file that does not match")
        await model.close()
    }

    /// Code gate 1: a gain over the 20 dB auto-level limit (a -60 LUFS selection) shows as a
    /// warning; a usual gain shows as info. Both texts name the file and the report.
    @Test func aLargeGainReportIsAWarning() throws {
        func report(gain: Double) throws -> LoudnessReport {
            LoudnessReport(
                target: LUFS(value: -16), measured: LUFS(value: -16 - gain), gain: try #require(Gain(dB: gain)),
                output: LUFS(value: -16), truePeak: -1)
        }
        #expect(WindowBanner.exportReport(try report(gain: 44), file: "a.wav").kind == .warning)
        #expect(WindowBanner.exportReport(try report(gain: 14), file: "a.wav").kind == .info)
        #expect(WindowBanner.exportReport(try report(gain: -21), file: "a.wav").kind == .warning)
        let large = try report(gain: 44)
        #expect(WindowBanner.exportReport(large, file: "a.wav").text.hasSuffix(L10n.reportGainLarge.text))
        #expect(WindowAlert.exported(["f.wav"], large).text.hasSuffix(L10n.reportGainLarge.text))
        #expect(
            !WindowBanner.exportReport(try report(gain: 14), file: "a.wav").text.contains(L10n.reportGainLarge.text))
        for language in ["en", "es"] {
            let text = (try? stringsTable(language))?["banner.export.report"] ?? ""
            #expect(text.contains("%1$@") && text.contains("%2$@"), "\(language): \(text)")
        }
    }
}
