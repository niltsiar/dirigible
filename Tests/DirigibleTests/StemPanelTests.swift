import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp

/// The save panel of File > Export Stems... (decision 0078): its message states the scope and
/// counts the tracks that the stems leave out, and its labels name a folder.
@MainActor struct StemPanelTests {
    /// Five tracks, each with a clip of 1200 s, so the session ends at 1200 s.
    func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 57_600_000))
        for number in 1...5 {
            let id = TrackID("t\(number)")
            try session.addTrack(id, name: id.rawValue, layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(number)"), file: "f", start: 0, offset: 0, length: 57_600_000), on: id)
        }
        return session
    }

    func source(_ session: Session, tracks: Set<TrackID>?, marks: Range<Frames>? = nil) throws -> ExportSource {
        try #require(ExportSource(range: marks ?? .zero..<session.end, tracks: tracks))
    }

    @Test func theMessageStatesTheScope() throws {
        let session = try session()
        let three: Set<TrackID> = ["t1", "t2", "t3"]
        #expect(
            stemPanelMessage(session, try source(session, tracks: three)) == L10n.panelStemsScopeWhole.format(3, 5),
            "3 selected of 5, no Marks: the whole session")
        #expect(
            stemPanelMessage(session, try source(session, tracks: three, marks: 34_752_000..<53_280_000))
                == L10n.panelStemsScopeRange.format(3, 5, "12:04", "18:30"),
            "3 selected of 5, with Marks: the Marks range")
        #expect(
            stemPanelMessage(session, try source(session, tracks: nil)) == L10n.panelStemsScopeWhole.format(5, 5),
            "no track selected: every track")
    }

    @Test func theMessageCountsTheUnheardTracks() throws {
        var session = try session()
        let three: Set<TrackID> = ["t1", "t2", "t3"]
        let scope = L10n.panelStemsScopeWhole.format(3, 5)
        let line = L10n.panelExportNoteMany.format(2)
        #expect(stemPanelMessage(session, try source(session, tracks: three)) == scope, "every track heard: no line")
        try session.setMuted(true, tracks: ["t2", "t3"])
        #expect(stemPanelMessage(session, try source(session, tracks: three)) == scope + "\n" + line, "2 muted")
        try session.setMuted(false, tracks: ["t2", "t3"])
        try session.setSoloed(true, tracks: ["t1"])
        #expect(
            stemPanelMessage(session, try source(session, tracks: three)) == scope + "\n" + line,
            "t1 soloed: t2 and t3 of the set are not heard, with no track muted")
        try session.setMuted(true, tracks: ["t2"])
        try session.setSoloed(false, tracks: ["t1"])
        #expect(
            stemPanelMessage(session, try source(session, tracks: three))
                == scope + "\n" + L10n.panelExportNoteOne.format(1),
            "one track muted")
    }

    @Test func thePanelNamesAFolderAndSaysWhatAStemHolds() throws {
        let panel = ExportPanel.stemsPanel(name: "Show stems", message: "the scope")
        #expect(panel.nameFieldLabel == L10n.panelStemsFolderName.text, "not the default Save As: label")
        #expect(panel.prompt == L10n.alertExportConfirm.text, "not the default Save button")
        #expect(panel.message == "the scope" && panel.nameFieldStringValue == "Show stems")
        #expect(panel.canCreateDirectories)

        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func text(_ table: [String: String], _ key: L10n) -> String { table[key.rawValue] ?? key.rawValue }
        #expect(
            text(en, .panelStemsFolderName) == "Folder name:"
                && text(es, .panelStemsFolderName) == "Nombre de la carpeta:")
        #expect(text(en, .alertExportConfirm) == "Export" && text(es, .alertExportConfirm) == "Exportar")
        #expect(
            text(en, .panelStemsContent)
                == "Each stem file holds its tracks with their gain and effects, as in the mix.")
        #expect(
            text(es, .panelStemsContent)
                == "Cada archivo de stem contiene sus pistas con su ganancia y sus efectos, como en la mezcla.")
    }

    /// The item titles of each pop-up that `view` shows, in order.
    func popUps(_ view: some View) -> [[String]] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        func walk(_ view: NSView) -> [[String]] {
            let own = (view as? NSPopUpButton).map { [$0.itemTitles] } ?? []
            return own + view.subviews.flatMap(walk)
        }
        return walk(host)
    }

    /// The session rate item gives kHz with the decimal mark of the locale, and no zero decimal.
    @Test func sessionRateItemUsesTheLocaleDecimalMark() {
        let es = Locale(identifier: "es_ES")
        let en = Locale(identifier: "en_US")
        #expect(sessionRateItemText(44_100, locale: es, format: "Sesión (%@ kHz)") == "Sesión (44,1 kHz)")
        #expect(sessionRateItemText(48_000, locale: es, format: "Sesión (%@ kHz)") == "Sesión (48 kHz)")
        #expect(sessionRateItemText(44_100, locale: en, format: "Session (%@ kHz)") == "Session (44.1 kHz)")
    }

    /// The item must fit the pop-up of the 420 pt accessory in each language: no ellipsis.
    @Test func sessionRateItemIsShortInEveryLanguage() throws {
        for language in AppLanguage.allCases.map(\.rawValue) {
            let format = try #require(try stringsTable(language)["panel.export.rate.session"])
            let item = sessionRateItemText(44_100, locale: Locale(identifier: "en_US"), format: format)
            #expect(item.count <= 20, "\(language): \(item)")
            #expect(format.contains("%@ kHz"), "\(language): \(format)")
        }
    }

    /// The mix panel and the stem panel list the same bit depths, channels, and sample rates, so a new
    /// case cannot show in one panel only.
    @Test func bothPanelsOfferTheSameFormatPickers() throws {
        let sessionRate = 48_000
        let mix = popUps(
            ExportAccessory(
                settings: ExportSettings(defaults: nil), sessionRate: sessionRate, note: nil,
                savePreset: { _, _ in nil },
                name: { "Show" },
                changed: {}))
        let stems = popUps(StemAccessory(settings: StemSettings(defaults: nil), sessionRate: sessionRate))
        let expected = [
            BitDepth.allCases.map { "\($0.rawValue)" },
            [L10n.panelExportChannelsStereo.text, L10n.panelExportChannelsMono.text],
            [
                sessionRateItemText(sessionRate), L10n.panelExportRate44100.text,
                L10n.panelExportRate48000.text,
            ],
        ]

        try #require(!mix.isEmpty && !stems.isEmpty, "the pop-ups were not found: mix \(mix), stems \(stems)")
        for list in expected {
            #expect(mix.contains(list), "the mix panel lacks \(list): \(mix)")
            #expect(stems.contains(list), "the stem panel lacks \(list): \(stems)")
        }
    }
}
