import AppKit
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate 2 item 1: the Transcribe sheet has one height in each state of its check line, drawn
/// with the table of each language. The suite is slow-gated: see `HeaderStateLineTests`.
extension HeaderStateLineTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"),
        arguments: ["en", "es", "de", "fr"])
    func theTranscribeSheetKeepsOneHeightInEachLanguage(language: String) async throws {
        let (model, _) = try await headerModel(.states)
        let medium = WhisperModelFacts(audioLayers: 24, textLayers: 24, melCount: 80, isMultilingual: true)
        let kept = KeptModelFile(
            url: URL(filePath: "/Models/ggml-medium.bin"), status: FileStatus(byteCount: 3, modified: .now),
            passed: PassedModelFile(sha256: String(repeating: "a", count: 64), facts: medium))
        let longRefusal = String(repeating: "A helper reason that runs on and on. ", count: 20)
        try await withStrings(language) {
            let lines: [ModelCheckLine?] = [
                nil, .running(name: "ggml-medium.bin", byteCount: 600_000_000), .passed(medium),
                .refused(L10n.message(for: ModelFileCheckError.refused(.file(.damaged("n_text_head 0"))))),
                .refused(L10n.sheetTranscribeCheckTake.text), .refused(longRefusal),
            ]
            for words in [0, 15] {
                for entry in [ModelEntry.catalog(.base), .file] {
                    var draft = try TranscribeSheetTests.sheet(.code("en"), kept: kept, words: words)
                    draft.select(entry)
                    let heights = lines.map { line -> CGFloat in
                        draft.check = line
                        model.transcribe.draft = draft
                        let host = NSHostingView(rootView: TranscribeSheet(model: model))
                        host.layoutSubtreeIfNeeded()
                        return host.fittingSize.height
                    }
                    print("sheet height \(language) words \(words) \(entry): \(heights)")
                    #expect(Set(heights).count == 1, "\(language) \(entry) with \(words) words: \(heights)")
                }
            }
        }
        model.transcribe.draft = nil
    }
}
