import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Apply, the Action pop-up, the texts, and the kept settings of the Silences tab (criteria C29,
/// C33 to C36, and C38).
extension SilencesInspectorTests {
    /// Three silences: A and B of `voice`, and C at 432 000 ..< 504 000 of a 552 000 frame session.
    static let three: [Part] = [.tone(2), .quiet(2.5), .tone(1.5), .quiet(2), .tone(1), .quiet(1.5), .tone(1)]

    /// C29: Apply while stopped edits and the playhead stays stopped; while playing, it edits and the
    /// play goes on. The Marks clear, and the playhead moves by Rule M: a playhead after the cuts
    /// moves left by their length, and a playhead in a cut goes to the cut start. One Undo restores
    /// the session.
    @Test func applyInEachStartState() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio) = try await open(try await package())
        let before = studio.session
        await model.scanSilences()
        model.timeline.selection = .range(Marks(inPoint: 10_000, outPoint: 20_000, tracks: ["t1"]))
        await studio.perform(.seek(.frame(400_000)))
        model.applySilences()
        #expect(studio.session.end == 312_000, "A and B shortened: \(studio.session.end)")
        #expect(model.timeline.selection == .none, "the Marks stay")
        await model.settleTransport()
        #expect(studio.playhead == 232_000, "a playhead after both cuts: \(studio.playhead)")
        #expect(studio.playback == .stopped, "Apply started a play")
        #expect(model.silences.review == nil && model.silences.note != nil, "the list stays, or no note")
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "one Undo does not restore the session")

        await model.scanSilences()
        await studio.perform(.seek(.frame(150_000)))
        model.applySilences()
        await model.settleTransport()
        #expect(studio.playhead == 108_000, "a playhead in the cut A: \(studio.playhead)")
        try studio.undo()

        await model.scanSilences()
        await studio.perform(.seek(.frame(400_000)))
        await studio.perform(.playStop)
        await until("the play runs") { studio.playback != .stopped }
        model.applySilences()
        #expect(studio.session.end == 312_000, "Apply during a play: \(studio.session.end)")
        #expect(studio.playback != .stopped, "the play stopped")
        await model.settleTransport()
        #expect(studio.playhead < 400_000, "the playhead did not follow the cuts: \(studio.playhead)")
        await studio.perform(.pause)
        await model.close()
    }

    /// C33: the Action pop-up sets the action of the selected rows and of no other row, Delete sets
    /// the selected rows to Skip, and the summary counts each action, the time that the cuts remove,
    /// and the new length. A cut removes the silence less its keep, not the whole silence.
    @Test func theActionPopUpSetsOnlyTheSelectedRows() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, _) = try await open(try await package(tracks: [Self.three]))
        await model.scanSilences()
        #expect(rows(model).count == 3 && rows(model).allSatisfy { $0.action == .shorten }, "\(rows(model))")
        model.setSilenceAction(.mute, rows: [0, 2])
        #expect(rows(model).map(\.action) == [.mute, .shorten, .mute], "\(rows(model))")
        model.setSilenceAction(.skip, rows: [1])
        #expect(rows(model).map(\.action) == [.mute, .skip, .mute], "Delete: \(rows(model))")
        model.setSilenceAction(.shorten, rows: [0, 1, 2])
        model.setSilenceAction(.mark, rows: [1])
        let summary = try #require(model.silences.review?.summary)
        #expect(summary.counts[.shorten] == 2 && summary.counts[.mark] == 1, "\(summary)")
        #expect(summary.counts[.mute] == 0 && summary.counts[.skip] == 0, "\(summary)")
        #expect(summary.removed == 144_000, "the cuts of A and C: \(summary.removed)")
        #expect(summary.length == 408_000, "552 000 less 144 000: \(summary.length)")
        model.selectSilences([0, 2])
        #expect(model.silences.selectedAction == .shorten && model.silences.selection == [0, 2])
        model.selectSilences([0, 1])
        #expect(model.silences.selectedAction == nil, "two actions are Mixed")
        await model.close()
    }

    /// C38: an empty list gives its first sentence, and the quietest level when the scan has one,
    /// rounded up to one decimal toward 0 dBFS, so a threshold set to it gives a row.
    @Test func anEmptyListNamesTheQuietestLevel() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let english = try stringsTable("en")
        let table = { (key: L10n) in english[key.rawValue]! }
        let floor: [Part] = [
            .tone(1), .floor(1.5, dBFS: -37.96), .floor(0.05, dBFS: -50), .floor(1.45, dBFS: -37.96), .tone(1),
        ]
        let (model, _) = try await open(try await package(tracks: [floor]))
        await model.scanSilences()
        let review = try #require(model.silences.review)
        #expect(review.rows.isEmpty)
        #expect(
            review.emptyText(locale: Locale(identifier: "en"), table: table)
                == "No silences of 1 s or more at or under -40 dBFS. The quietest part is -37.9 dBFS.")
        #expect(SilenceReview.roundedUp(-37.96) == -37.9 && SilenceReview.roundedUp(-38) == -38)
        await model.close()

        let short: [Part] = [.floor(0.5, dBFS: -30)]
        let (second, _) = try await open(try await package("short", tracks: [short]))
        await second.scanSilences()
        let none = try #require(second.silences.review)
        #expect(none.scan.quietest == nil)
        #expect(
            none.emptyText(locale: Locale(identifier: "en"), table: table)
                == "No silences of 1 s or more at or under -40 dBFS.")
        await second.close()
    }

    /// C34: after Apply the tab gives the count of each action, the time removed, and the length
    /// before and after, with the `.one` key for one shortened silence, and VoiceOver announces it.
    /// It stays until the next scan or a settings change.
    @Test func theNoteGivesTheLengthBeforeAndAfter() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let english = try stringsTable("en")
        let spanish = try stringsTable("es")
        let (model, studio) = try await open(try await package())
        var announced: [String] = []
        model.chrome?.announce = { text, _ in announced.append(text) }
        await model.scanSilences()
        model.setSilenceAction(.skip, rows: [1])
        model.applySilences()
        let note = try #require(model.silences.note)
        #expect(note.shortened == 1 && note.removed == 96_000 && note.before == 480_000 && note.after == 384_000)
        let en = Locale(identifier: "en")
        #expect(
            note.text(locale: en, table: { english[$0.rawValue]! })
                == "Shortened 1 silence (removed 2.0 s, from 10.0 s to 8.0 s), muted 0, marked 0.")
        #expect(
            note.text(locale: Locale(identifier: "es"), table: { spanish[$0.rawValue]! }).contains("de 10,0 s a 8,0 s"))
        #expect(SilenceReview.seconds(Frames(360_000), rate: 48_000, locale: Locale(identifier: "es")) == "7,5")
        #expect(announced.contains("silences.note.one"), "VoiceOver announcements: \(announced)")
        model.silences.settings.threshold = -41
        #expect(model.silences.note == nil, "a settings change keeps the note")

        try studio.undo()
        await model.scanSilences()
        model.applySilences()
        #expect(
            model.silences.note?.text(locale: en, table: { english[$0.rawValue]! })
                == "Shortened 2 silences (removed 3.5 s, from 10.0 s to 6.5 s), muted 0, marked 0.")
        await model.scanSilences()
        #expect(model.silences.note == nil, "a scan keeps the note")
        await model.close()
    }

    /// C35: a row reads its time, its length, and its action, with its reason when it starts as Mark.
    @Test func aRowReadsItsTimeLengthAndAction() throws {
        let session = Session(sampleRate: 48_000)
        let silence = Frames(222 * 48_000)..<(Frames(222 * 48_000) + Frames(115_200))
        let scan = SilenceScan(
            silences: [silence], tracks: [], range: 0..<(silence.upperBound + 48_000), threshold: Gain(dB: -40)!,
            minLength: 48_000, outside: nil, quietest: nil, scanned: session)
        var review = SilenceReview(scan: scan, settings: SilenceSettings(), session: session)
        let english = try stringsTable("en")
        let label = {
            review.label(of: review.rows[0], locale: Locale(identifier: "en"), table: { english[$0.rawValue]! })
        }
        #expect(label() == "Silence at 3:42, 2.4 seconds, Shorten")
        review.rows[0].action = .mute
        #expect(label() == "Silence at 3:42, 2.4 seconds, Mute", "the label keeps the old action")
        #expect(SilenceReview.clock(Frames(3_600 * 48_000 + 62 * 48_000), rate: 48_000) == "1:01:02")
    }

    /// C36: the next scan in any window starts with the last tracks, threshold, minimum, and keep;
    /// an ID that the session does not have is ignored; a settings change after a scan turns Apply
    /// off until Scan Again.
    @Test func theSettingsStayForTheNextScan() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let music: [Part] = [.quiet(10)]
        let (first, _) = try await open(try await package(tracks: [Self.voice, music]))
        first.silences.settings.unchecked = ["t2"]
        first.silences.settings.threshold = -35
        first.silences.settings.minimum = 1_500
        first.silences.setKeep("700")
        await first.scanSilences()
        #expect(first.canApplySilences, "a list with two rows: \(rows(first))")
        first.silences.setKeep("600")
        #expect(first.silences.isStale && !first.canApplySilences, "a keep change leaves Apply on")
        first.silences.setKeep("700")
        #expect(first.canApplySilences, "the same settings again")
        first.silences.settings.threshold = -36
        #expect(!first.canApplySilences, "a threshold change leaves Apply on")
        await first.scanSilences()
        #expect(first.canApplySilences, "Scan Again")

        let (second, studio) = try await open(try await package("second"))
        let settings = second.silences.settings
        #expect(settings.unchecked == ["t2"] && settings.threshold == -36 && settings.minimum == 1_500, "\(settings)")
        #expect(settings.keep == 700 && second.silences.keepText == "700", "\(settings)")
        #expect(settings.scanned(in: studio.session) == nil, "an ID of another session is not ignored")
        await first.close()
        await second.close()
    }
}
