import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

extension InspectorTests {
    /// C10: the read-only Effects row. Clips on renders of one amount show it; renders of two
    /// amounts, or a render with a plain clip, show Mixed; plain clips have no row. The texts of
    /// the English and Spanish tables.
    @Test func effectsRow() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "T1", layout: .mono)
        func render(_ id: FileID, _ decibels: Int) throws -> AudioFile {
            let noise = try #require(NoiseReduction(decibels: decibels))
            let origin = RenderOrigin(source: "f", offset: 0, treatment: Treatment(.noise(noise)), addedGain: .zero)
            return AudioFile(id: id, path: "Clips/\(id.rawValue).wav", layout: .mono, length: 480_000, origin: origin)
        }
        for file in [
            AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000), try render("f NR", 12),
            try render("f NR 2", 12), try render("f NR 3", 20),
        ] {
            try session.addFile(file)
        }
        for (id, file, start) in [
            ("P", "f", 0), ("Q", "f", 1), ("A", "f NR", 2), ("B", "f NR 2", 3), ("C", "f NR 3", 4),
        ]
            as [(ClipID, FileID, Int)]
        {
            try session.place(
                Clip(id: id, file: file, start: Frames(start * 48_000), offset: 0, length: 48_000), on: "t1")
        }
        for (language, value, mixed) in [
            ("en", "Reduce Noise 12 dB", "Mixed"), ("es", "Reducir ruido 12 dB", "Varios"),
        ] {
            let table = try stringsTable(language)
            func text(_ clips: [ClipID]) -> String? {
                InspectorView.effectsText(clips, in: session) { table[$0.rawValue] ?? $0.rawValue }
            }
            #expect(text(["P"]) == nil, "\(language) a plain clip")
            #expect(text(["P", "Q"]) == nil, "\(language) two plain clips")
            #expect(text(["A"]) == value, "\(language) one render")
            #expect(text(["A", "B"]) == value, "\(language) two renders of one amount")
            #expect(text(["A", "C"]) == mixed, "\(language) two amounts")
            #expect(text(["P", "A"]) == mixed, "\(language) a render and a plain clip")
        }
    }
}
