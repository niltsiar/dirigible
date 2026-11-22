import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C12 e (decision 0039): the save panel gets the note line of the unheard tracks,
/// and no alert shows, so the export goes on as before.
extension ExportWindowTests {
    @Test func thePanelGetsTheNoteOfAnUnheardTrack() async throws {
        var notes: [String?] = []
        app.chooseExport = { _, _, _, _, note, _, done in
            notes.append(note)
            done(nil)
        }
        let (model, studio, _) = try await window()
        await model.export(.session)
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMuted(true, tracks: ["t1"]) }
        await model.export(.session)

        #expect(notes == [nil, L10n.panelExportNoteSilent.format(1)], "the notes of the panel: \(notes)")
        #expect(model.alert == nil, "no alert")
        await model.close()
    }
}
