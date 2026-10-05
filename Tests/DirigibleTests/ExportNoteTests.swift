import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

/// Mute and solo C12 (decision 0039): the note of the export panel counts the unheard tracks of the
/// export source, or says that the file will be silent.
struct ExportNoteTests {
    func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        for id: TrackID in ["t1", "t2", "t3"] { try session.addTrack(id, name: id.rawValue, layout: .mono) }
        return session
    }

    func note(_ session: Session, tracks: Set<TrackID>? = nil) throws -> ExportNote? {
        exportNote(session, try #require(ExportSource(range: 0..<48_000, tracks: tracks)))
    }

    @Test func theNoteCountsTheUnheardTracksOfTheSource() throws {
        var session = try session()
        #expect(try note(session) == nil, "a: every track heard, no note")
        try session.setMuted(true, tracks: ["t1"])
        #expect(try note(session) == ExportNote(key: .panelExportNoteOne, count: 1), "b: one muted track")
        try session.setSoloed(true, tracks: ["t3"])
        #expect(try note(session) == ExportNote(key: .panelExportNoteMany, count: 2), "c: t1 muted and t2 not soloed")
        try session.setMuted(true, tracks: ["t3"])
        #expect(try note(session) == ExportNote(key: .panelExportNoteSilent, count: 3), "d: no track is heard")
        try session.setMuted(false, tracks: ["t1", "t3"])
        try session.setSoloed(false, tracks: ["t3"])
        try session.setMuted(true, tracks: ["t1"])
        #expect(try note(session, tracks: ["t2"]) == nil, "f: Export Selection of t2 counts only t2")
        #expect(
            try note(session, tracks: ["t1", "t2"]) == ExportNote(key: .panelExportNoteOne, count: 1),
            "f: Export Selection of t1 and t2")
    }

    /// The texts of the three notes in English and Spanish, from the tables of the app.
    @Test func theNotesReadInEnglishAndSpanish() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func text(_ table: [String: String], _ key: L10n, _ count: Int) -> String {
            String(format: table[key.rawValue] ?? "", count)
        }
        #expect(text(en, .panelExportNoteOne, 1) == "1 track muted or not soloed: not in the export.")
        #expect(text(es, .panelExportNoteOne, 1) == "1 pista silenciada o sin solo: no está en la exportación.")
        #expect(text(en, .panelExportNoteMany, 2) == "2 tracks muted or not soloed: not in the export.")
        #expect(text(es, .panelExportNoteMany, 2) == "2 pistas silenciadas o sin solo: no están en la exportación.")
        #expect(text(en, .panelExportNoteSilent, 3) == "No track is heard: the file will be silent.")
        #expect(text(es, .panelExportNoteSilent, 3) == "No se oye ninguna pista: el archivo estará en silencio.")
    }
}
