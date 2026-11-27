import AppKit
import DirigibleCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 9a criterion 20: the loudness report of an export with a target, on a real session
/// window. The tests are in the serialized suite `ExportWindowTests` and use its fixtures.
/// The text of a key up to its first format specifier. A test process has no localized table, so
/// `L10n.text` gives the key itself there: a test compares with this text and not with a literal.
func leadText(_ key: String) -> String {
    String((L10n(rawValue: key)?.text ?? key).prefix { $0 != "%" })
}

extension ExportWindowTests {
    /// A window of 10 s of noise at -36 dB, so an export with a target needs a gain over the 20 dB limit
    /// and shows its report as a warning banner.
    func loudWindow() async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window) = try await self.window(noise: true)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setGain(Gain(dB: -36)!, clip: "c1")
        }
        return (model, studio, window)
    }

    /// C9 (i): an export with a usual gain shows an info banner with the file and its report, because the
    /// file lands outside the window. VoiceOver reads the banner once.
    @Test func aPlainExportShowsABannerAndIsAnnounced() async throws {
        let (model, studio, _) = try await window(noise: true)
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        let source = try #require(model.source(of: .session, in: studio))

        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)

        #expect(model.alert == nil, "\(String(describing: model.alert))")
        let banner = try #require(ChromeState.reportBanners(model, studio).first { $0.key.hasPrefix("exportReport") })
        #expect(banner.kind == .info && banner.text.hasPrefix(leadText("banner.export.report")), "\(banner)")
        #expect(!banner.text.contains(L10n.reportGainLarge.text), "the fixture has a large gain: \(banner.text)")
        await until("the report banner shows") { model.shown.banners.contains { $0.key == banner.key } }
        #expect(heard.filter { $0 == banner.text }.count == 1, "VoiceOver hears the banner once: \(heard)")
        await model.close()
    }

    /// C9 (i): an export with no loudness target shows an info banner with the file name only.
    @Test func anExportWithNoTargetShowsADoneBanner() async throws {
        let (model, studio, _) = try await window()
        let source = try #require(model.source(of: .session, in: studio))

        await model.run(source, target, studio)

        let banner = try #require(ChromeState.reportBanners(model, studio).first { $0.key.hasPrefix("exportReport") })
        #expect(banner.kind == .info, "\(banner)")
        #expect(banner.text == L10n(rawValue: "banner.export.done")?.format("mix.wav"), "\(banner.text)")
        await model.close()
    }

    /// Run 9a criterion 20: a clean export with a target and a gain over the limit shows the report in a
    /// warning banner, not in a modal alert, and VoiceOver reads it. The next export start removes it.
    @Test func aTargetExportShowsTheReportBanner() async throws {
        let (model, studio, _) = try await loudWindow()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        let source = try #require(model.source(of: .session, in: studio))

        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)

        #expect(model.alert == nil, "the report is a modal alert: \(String(describing: model.alert))")
        let report = try #require(model.exportReport?.report)
        #expect(report.exceedsLevelLimit, "the fixture has a usual gain: \(report.gain)")
        await until("the report banner shows") {
            model.shown.banners.contains(.exportReport(report, file: "mix.wav", url: out))
        }
        #expect(WindowBanner.exportReport(report, file: "mix.wav", url: out).kind == .warning)
        #expect(
            heard.contains(WindowBanner.exportReport(report, file: "mix.wav", url: out).text),
            "no announcement: \(heard)")
        let off = ExportTarget(url: folder.url.appending(path: "off.wav"), options: Self.options, confirmed: nil)
        await model.run(source, off, studio)
        #expect(model.exportReport?.file == "off.wav")
        await until("the report banner goes") { !model.shown.banners.contains { $0.key == "exportReport.mix.wav" } }
        await model.close()
    }

    /// Run 9a criterion 20: no modal alert or sheet holds the window while the report shows, so
    /// Record starts a take, and the take start removes the report.
    @Test func recordStartsWhileTheReportShows() async throws {
        let (model, studio, window) = try await loudWindow()
        let source = try #require(model.source(of: .session, in: studio))
        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)
        await until("the report banner shows") { model.shown.banners.contains { $0.key.hasPrefix("exportReport") } }
        // The progress sheet ends its close after the export; under load it shows a little longer.
        await until("the progress sheet goes") { window.attachedSheet == nil }
        #expect(model.alert == nil && model.canRecord)
        #expect(model.shown.banners.contains { $0.key.hasPrefix("exportReport") }, "the report went with the sheet")

        await model.record()

        #expect(studio.transport == .recording(take: 1))
        #expect(model.exportReport == nil)
        await until("the report banner goes") { !model.shown.banners.contains { $0.key.hasPrefix("exportReport") } }
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
        let (model, studio, _) = try await loudWindow()
        let source = try #require(model.source(of: .session, in: studio))
        await model.run(source, ExportTarget(url: out, options: Self.podcast, confirmed: nil), studio)
        let report = try #require(model.exportReport?.report)
        await until("the report banner shows") {
            model.shown.banners.contains(.exportReport(report, file: "mix.wav", url: out))
        }

        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Renamed") }

        await until("the report banner goes") { !model.shown.banners.contains { $0.key.hasPrefix("exportReport") } }
        await model.close()
    }

    /// Code gate 2: an edit while the export runs is not in the file, so no report banner shows
    /// after the export.
    @Test func anEditDuringTheExportShowsNoReport() async throws {
        let (model, studio, _) = try await loudWindow()
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

        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Renamed") }
        release.signal()
        await export.value

        #expect(model.exportReport != nil && model.alert == nil, "the export did not end clean")
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            !model.shown.banners.contains { $0.key.hasPrefix("exportReport") },
            "a report for a file that does not match")
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
        let url = URL(filePath: "/a.wav")
        #expect(WindowBanner.exportReport(try report(gain: 44), file: "a.wav", url: url).kind == .warning)
        #expect(WindowBanner.exportReport(try report(gain: 14), file: "a.wav", url: url).kind == .info)
        #expect(WindowBanner.exportReport(try report(gain: -21), file: "a.wav", url: url).kind == .warning)
        let large = try report(gain: 44)
        #expect(
            WindowBanner.exportReport(large, file: "a.wav", url: url).text
                == L10n.bannerExportReportLarge.format("a.wav", 44.0))
        #expect(WindowAlert.exported(["f.wav"], large).text.hasSuffix(L10n.reportGainLarge.text))
        #expect(
            !WindowBanner.exportReport(try report(gain: 14), file: "a.wav", url: url).text.contains(
                L10n.reportGainLarge.text))
        for language in AppLanguage.allCases.map(\.rawValue) {
            let text = (try? stringsTable(language))?["banner.export.report"] ?? ""
            #expect(text.contains("%1$@") && text.contains("%2$.1f"), "\(language): \(text)")
        }
    }

    /// Run 2026-10-11-chapters-in-file, C5f: an MP3 export leaves out a second chapter at one
    /// start, and a warning banner names it. A session edit removes the banner.
    @Test func aDroppedChapterShowsAWarningBanner() async throws {
        let (model, studio, _) = try await window()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "a", name: "A", position: 192_000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "C", position: 192_000, kind: .chapter))
        }
        let source = try #require(model.source(of: .session, in: studio))
        let mp3 = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session)
        let target = ExportTarget(url: folder.url.appending(path: "mix.mp3"), options: mp3, confirmed: nil)

        await model.run(source, target, studio)

        #expect(model.alert == nil, "\(String(describing: model.alert))")
        let banner = WindowBanner.chaptersDropped(["C"], file: "mix.mp3")
        await until("the banner shows") { model.shown.banners.contains(banner) }
        #expect(banner.kind == .warning)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Renamed") }
        await until("the banner goes") { !model.shown.banners.contains { $0.key.hasPrefix("chaptersDropped") } }
        // Code gate item D6: the text also gives the second reason, a chapter after the audio.
        let texts = [
            "en": "mix.mp3 leaves out C. Give each chapter its own start inside the audio.",
            "es": "mix.mp3 omite C. Da a cada capítulo su propio inicio dentro del audio.",
        ]
        for (language, expected) in texts {
            let format = (try? stringsTable(language))?["banner.export.chapter.dropped"] ?? ""
            #expect(String(format: format, "mix.mp3", "C") == expected, "\(language): \(format)")
        }
        await model.close()
    }

    /// Run 2026-10-11-chapters-in-file, C5b, C10: an M4A export with a chapter image, a chapter with
    /// none, and no episode artwork shows a warning banner.
    @Test func omittedChapterImagesShowAWarningBanner() async throws {
        let (model, studio, _) = try await window()
        let image = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        let file = model.url.appending(path: image.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try #require(
            CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "a", name: "A", position: 0, kind: .chapter, image: image))
            try session.setMarker(Marker(id: "b", name: "B", position: 192_000, kind: .chapter))
        }
        let source = try #require(model.source(of: .session, in: studio))
        let m4a = ExportOptions(format: .aac(.k128), layout: .stereo, rate: .session)
        let target = ExportTarget(url: folder.url.appending(path: "mix.m4a"), options: m4a, confirmed: nil)

        await model.run(source, target, studio)

        #expect(model.alert == nil, "\(String(describing: model.alert))")
        let banner = WindowBanner.chapterImagesOmitted(file: "mix.m4a")
        await until("the banner shows") { model.shown.banners.contains(banner) }
        #expect(banner.kind == .warning)
        for language in AppLanguage.allCases.map(\.rawValue) {
            let text = (try? stringsTable(language))?["banner.export.chapter.images.omitted"] ?? ""
            #expect(text.contains("%@"), "\(language): \(text)")
        }
        await model.close()
    }

    /// C18: an MP3 export of an episode with no title shows a warning banner with the file name. A
    /// WAV export, and an MP3 export with a title, show none. A session edit removes the banner.
    @Test func exportWithNoTitleShowsTheBanner() async throws {
        let (model, studio, _) = try await window()
        let source = try #require(model.source(of: .session, in: studio))
        let mp3 = ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session)
        let target = ExportTarget(url: folder.url.appending(path: "mix.mp3"), options: mp3, confirmed: nil)

        await model.run(source, target, studio)

        #expect(model.alert == nil, "\(String(describing: model.alert))")
        let banner = WindowBanner.titleMissing(file: "mix.mp3")
        await until("the banner shows") { model.shown.banners.contains(banner) }
        #expect(banner.kind == .warning)
        for language in AppLanguage.allCases.map(\.rawValue) {
            let text = (try? stringsTable(language))?["banner.export.title.missing"] ?? ""
            #expect(text.contains("%@"), "\(language): \(text)")
        }
        try studio.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Renamed") }
        await until("the banner goes") { !model.shown.banners.contains { $0.key.hasPrefix("titleMissing") } }

        await model.run(source, self.target, studio)
        #expect(model.alert == nil && FileManager.default.fileExists(atPath: out.path), "the WAV export ran")
        #expect(model.chapterWarnings == nil, "a WAV file has no title tag")

        try studio.edit(ripple: false) { session throws(SessionError) in
            var episode = session.episode
            episode.title = try? EpisodeLine("Episode 1")
            session.setEpisode(episode)
        }
        let titled = ExportTarget(url: folder.url.appending(path: "titled.mp3"), options: mp3, confirmed: nil)
        await model.run(source, titled, studio)
        #expect(model.alert == nil && FileManager.default.fileExists(atPath: titled.url.path), "the MP3 export ran")
        #expect(model.chapterWarnings == nil, "an episode with a title has a title tag")
        await model.close()
    }
}
