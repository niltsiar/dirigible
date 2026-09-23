import Foundation
import Testing

/// DirigibleCore imports only Foundation (decision 0002). SwiftPM cannot stop a target from
/// importing a system framework, so this test reads the sources.
struct ImportRuleTests {
    @Test func coreImportsOnlyFoundation() throws {
        let core = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/DirigibleCore").standardized
        let files = try #require(FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "No Swift files in \(core.path)")

        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            for line in lines {
                if let module = importedModule(String(line)), module != "Foundation" {
                    Issue.record("\(file.lastPathComponent) imports \(module)")
                }
            }
        }
    }

    @Test func patternFindsEveryImportForm() {
        #expect(importedModule("import AppKit") == "AppKit")
        #expect(importedModule("  import AVFoundation") == "AVFoundation")
        #expect(importedModule("@preconcurrency import CoreAudio") == "CoreAudio")
        #expect(importedModule("@_exported import SwiftUI") == "SwiftUI")
        #expect(importedModule("public import Combine") == "Combine")
        #expect(importedModule("@testable internal import OSLog") == "OSLog")
        #expect(importedModule("import struct AVFAudio.AVAudioFormat") == "AVFAudio")
        #expect(importedModule("import func Darwin.fcntl") == "Darwin")
        #expect(importedModule("import Foundation") == "Foundation")
        #expect(importedModule("// import AppKit") == nil)
        #expect(importedModule("let important = 1") == nil)
    }

    private func importedModule(_ line: String) -> String? {
        let pattern =
            /^\s*(?:@\w+\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)/
        guard let match = try? pattern.firstMatch(in: line) else { return nil }
        return String(match.1)
    }
}
