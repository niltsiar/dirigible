import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate 1 of run 2026-10-28-chapter-export-files: where a set result reaches the user.
extension ExportWindowTests {
    /// Item 1: a set whose media is missing keeps its files, its loudness reports, and its done
    /// banner, and the alert names each part file with faults.
    @Test func aSetWithFaultsKeepsTheDoneBannerAndNamesEachFaultyPart() async throws {
        let (model, studio, _) = try await window(audio: false)
        try threeChapters(studio)

        try await runSet(model, studio, setTarget(options: Self.podcast))

        let parts = ["Ep-01-Intro.wav", "Ep-02-Talk.wav", "Ep-03-Outro.wav"]
        #expect(try setFiles() == parts)
        #expect(model.alert == .exportedSet(media: ["f1.wav"], parts: parts))
        let shown = try #require(model.exportSet, "a set with faults has no done banner")
        #expect(shown.files.map(\.lastPathComponent) == parts && shown.loudness.count == 3)
        guard case .exportSetDone(let files, _, _, _)? = ChromeState.reportBanners(model, studio).first else {
            Issue.record("No done banner: \(ChromeState.reportBanners(model, studio))")
            return
        }
        #expect(files.count == 3)
        await model.close()
    }
}
