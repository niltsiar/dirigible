import AppKit
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate 2 item 1: the line region of the Transcribe sheet is one fixed height, so the sheet
/// does not jump when a check line shows or goes. Each fixed text of the region fits it in each of the
/// 8 tables.
extension TranscribeSheetTests {
    /// The height of `text` in the note font, wrapped to `width`.
    static func noteHeight(_ text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let box = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return ceil(box.height)
    }

    @MainActor @Test(arguments: AppLanguage.allCases.map { $0.rawValue })
    func theLineRegionFitsTheLongestFixedTextsOfEachTable(language: String) throws {
        let table = try stringsTable(language)
        let text: (L10n) -> String = { table[$0.rawValue] ?? $0.rawValue }
        // The sheet is 440 pt wide with 20 pt of padding; the check line of a refusal has a 16 pt
        // symbol and 6 pt of spacing beside its text.
        let (full, beside, spacing) = (CGFloat(400), CGFloat(378), CGFloat(6))
        let line = Self.noteHeight("Ag", width: full)
        let facts = [4, 6, 12, 24, 32, 7].flatMap { layers in
            [true, false].map {
                WhisperModelFacts(audioLayers: layers, textLayers: layers, melCount: 80, isMultilingual: $0)
            }
        }
        let running =
            String(format: text(.sheetTranscribeCheckRunning), "ggml-medium.bin") + " "
            + text(.sheetTranscribeCheckWait)
        var states: [(name: String, notes: [(String, CGFloat)])] = [
            ("download", [(text(.sheetTranscribeNoteDownload), full)]),
            ("running", [(running, full)]),
        ]
        for fact in facts {
            states.append(
                ("file", [(ModelCheckLine.text(of: fact, text: text), full), (text(.sheetTranscribeNoteFile), full)]))
        }
        for key in [L10n.sheetTranscribeCheckTake, .sheetTranscribeCheckBusy, .sheetTranscribeCheckChanged] {
            states.append((key.rawValue, [(text(key), beside)]))
        }

        for (name, notes) in states {
            let heights = notes.map { Self.noteHeight($0.0, width: $0.1) }
            let stack = heights.reduce(0, +) + spacing * CGFloat(notes.count - 1)
            #expect(stack <= TranscribeSheet.lineRegionHeight, "\(language) \(name): \(stack) pt")
            for height in heights {
                #expect(height <= CGFloat(TranscribeSheet.noteLineLimit) * line, "\(language) \(name): \(height) pt")
            }
        }
    }
}
