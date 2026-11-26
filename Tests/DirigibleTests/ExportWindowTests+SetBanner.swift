import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The banner after an export set: an info banner with the count and the folder, which becomes a warning
/// when older files of the prefix stay in the folder (`ExportWindowTests+Split.swift` has the set helpers).
extension ExportWindowTests {
    /// C9 (j): a set with no older file of the prefix shows an info banner with the count and the folder
    /// name, because the files are outside the window. VoiceOver hears the count, the folder, and the
    /// loudness once: the banner adds no second announcement.
    @Test func anExportSetWithNoOlderFilesShowsADoneBanner() async throws {
        let (model, studio, _) = try await window()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        try threeChapters(studio)

        try await runSet(model, studio, setTarget())

        let banners = ChromeState.reportBanners(model, studio)
        #expect(banners.count == 1 && banners.first?.kind == .info, "\(banners)")
        let name = folder.url.lastPathComponent
        #expect(banners.first?.text == L10n(rawValue: "banner.export.set.done")?.format(3, name), "\(banners)")
        await until("the done banner shows") { model.shown.banners.contains { $0.key == "exportSetDone" } }
        let lead = leadText("announce.export.set.done")
        #expect(heard.filter { $0.hasPrefix(lead) }.count == 1, "VoiceOver hears the set once: \(heard)")
        await model.close()
    }

    /// C9 (j): the info banner of a plain set has Show in Finder, which reveals the files of the set.
    @Test func theDoneBannerOfAPlainSetShowsTheFilesInFinder() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        var revealed: [URL] = []
        app.reveal = { revealed = $0 }
        try await runSet(model, studio, setTarget())

        guard case .exportSetDone(let files, let old)? = ChromeState.reportBanners(model, studio).first else {
            Issue.record("No done banner")
            return
        }
        model.showInFinder(files)

        #expect(
            old.isEmpty
                && revealed.map(\.lastPathComponent) == ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"])
        await model.close()
    }

    /// C9 (j): an older file of the prefix makes the done banner a warning.
    @Test func anOlderFileOfThePrefixMakesTheSetBannerAWarning() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        try Data("older set".utf8).write(to: file("Ep-02-Old.wav"))

        try await runSet(model, studio, setTarget())

        let done = ChromeState.reportBanners(model, studio).first { $0.key == "exportSetDone" }
        #expect(done?.kind == .warning, "\(String(describing: done))")
        guard case .exportSetDone(_, let old)? = done else {
            Issue.record("No done banner: \(String(describing: done))")
            return
        }
        #expect(old == ["Ep-02-Old.wav"], "\(old)")
        await model.close()
    }

    @Test func theDoneBannerNamesTheOldFilesOfTheStem() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        let old = Data("older set".utf8)
        for name in ["Ep-02-Old.wav", "Ep-05-Outro.wav"] { try old.write(to: file(name)) }

        try await runSet(model, studio, setTarget())

        let banners = ChromeState.reportBanners(model, studio)
        guard case .exportSetDone(let files, let names)? = banners.first else {
            Issue.record("No done banner: \(banners)")
            return
        }
        #expect(
            names == ["Ep-02-Old.wav", "Ep-05-Outro.wav"] && files.count == 3, "a sheet showed or a name is missing")
        for name in ["Ep-02-Old.wav", "Ep-05-Outro.wav"] { #expect(try Data(contentsOf: file(name)) == old) }
        await model.close()
    }

    @Test func theDoneBannerShowsTheFilesInFinder() async throws {
        let (model, studio, _) = try await window()
        try threeChapters(studio)
        try Data("older set".utf8).write(to: file("Ep-02-Old.wav"))
        var revealed: [URL] = []
        app.reveal = { revealed = $0 }
        try await runSet(model, studio, setTarget())

        guard case .exportSetDone(let files, _)? = ChromeState.reportBanners(model, studio).first else {
            Issue.record("No done banner")
            return
        }
        model.showInFinder(files)

        #expect(revealed.map(\.lastPathComponent) == ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"])
        await model.close()
    }
}
