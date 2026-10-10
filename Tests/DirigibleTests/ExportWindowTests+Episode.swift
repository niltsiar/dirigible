import AVFoundation
import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate item 1: Export commits a typed episode field first, so the file has it.
extension ExportWindowTests {
    @Test func aTypedTitleIsInTheExportTag() async throws {
        let (model, studio, _) = try await window()
        let mp3 = folder.url.appending(path: "mix.mp3")
        app.chooseExport = { _, _, _, _, _, done in
            done(
                ExportTarget(
                    url: mp3, options: ExportOptions(format: .mp3(.k128), layout: .stereo, rate: .session),
                    confirmed: nil))
        }
        model.showEpisodeInfo()
        model.typeEpisode("Typed title", in: .title)

        model.run(.export)
        await until("the export ends") {
            studio.exportProgress == nil && FileManager.default.fileExists(atPath: mp3.path)
        }

        let items = try await AVURLAsset(url: mp3).loadMetadata(for: .id3Metadata)
        let title = try await items.first { $0.identifier?.rawValue == "id3/TIT2" }?.load(.stringValue)
        #expect(title == "Typed title", "the export tag has \(String(describing: title))")
        await model.close()
    }
}
