import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The banner after an export set: a warning only when older files of the prefix stay in the
/// folder (`ExportWindowTests+Split.swift` has the set helpers).
extension ExportWindowTests {
    /// C9 (j): a set with no older file of the prefix shows no banner, because the files are in the
    /// folder. VoiceOver hears the count and the folder.
    @Test func anExportSetWithNoOlderFilesShowsNoBanner() async throws {
        let (model, studio, _) = try await window()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        try threeChapters(studio)

        try await runSet(model, studio, setTarget())

        let banners = ChromeState.reportBanners(model, studio)
        #expect(banners.isEmpty, "a set with no older file has a banner: \(banners)")
        #expect(
            heard.contains { $0.hasPrefix(leadText("announce.export.set.done")) }, "VoiceOver hears no result: \(heard)"
        )
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
