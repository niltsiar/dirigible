import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Import Transcript and the empty state of the Transcript tab (criteria P2 and P6).
extension TranscriptPaneTests {
    /// A Whisper JSON file with the words `spoken` at the given seconds.
    func transcriptFile(_ words: [(Double, Double, String)], name: String = "episode.json") throws -> URL {
        let json =
            #"{"words":["#
            + words.map { #"{"word":" \#($0.2)","start":\#($0.0),"end":\#($0.1)}"# }.joined(separator: ",") + "]}"
        let url = folder.url.appending(path: name)
        try Data(json.utf8).write(to: url)
        return url
    }

    func finishImport(_ model: SessionWindow) async {
        await until(limit: .seconds(10), "the import job ends") { model.importJob == nil }
    }

    /// P6: the import is one edit and one undo step.
    @Test func importIsOneUndoStep() async throws {
        let (model, studio, _, _) = try await open(try await package(spoken: false))
        #expect(studio.session.transcriptNames.isEmpty && !studio.canUndo)
        let file = try transcriptFile([(1, 1.5, "Hello"), (1.5, 2, "there"), (6, 6.5, "Second")])
        model.importTranscript(from: file, track: "t1")
        #expect(model.importJob != nil, "the import is a job from the panel answer")
        #expect(!model.isOn(.importTranscript), "the item is off during the job")
        await finishImport(model)
        #expect(studio.session.words().map(\.text) == ["Hello", "there", "Second"])
        var steps = 0
        while studio.canUndo {
            model.undo()
            steps += 1
        }
        #expect(steps == 1, "one undo step")
        #expect(studio.session.transcriptNames.isEmpty)
        await model.close()
    }

    /// P6: a file that does not parse shows the alert and changes nothing.
    @Test func badImportChangesNothing() async throws {
        let (model, studio, _, _) = try await open(try await package(spoken: false))
        let before = studio.session
        let url = folder.url.appending(path: "notes.txt")
        try Data("this is not a transcript".utf8).write(to: url)
        model.importTranscript(from: url, track: "t1")
        await finishImport(model)
        #expect(model.alert == .transcriptImport(L10n.alertTranscriptBadFile.format("notes.txt")))
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// P6: a take that starts between the panel answer and the edit refuses the import with an alert.
    @Test func takeDuringTheParseRefusesTheImport() async throws {
        let (model, studio, _, _) = try await open(try await package(spoken: false))
        let file = try transcriptFile([(1, 1.5, "Hello")])
        model.importTranscript(from: file, track: "t1")
        // No await between the call and this edit: the import task has not run its edit yet.
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t1"]))
        }
        await finishImport(model)
        #expect(model.alert == .transcriptImport(L10n.alertTranscriptTake.text))
        #expect(studio.session.transcriptNames.isEmpty, "nothing imported")
        await model.close()
    }

    /// P6: a word with no clip shows in a banner, in the "Label: N" form, in English and Spanish.
    @Test func importReportShowsTheCounts() async throws {
        let (model, studio, _, _) = try await open(try await package(spoken: false))
        let file = try transcriptFile([(1, 1.5, "Hello"), (1000, 1000.5, "Late")])
        model.importTranscript(from: file, track: "t1")
        await finishImport(model)
        let banners = ChromeState.reportBanners(model, studio).map(\.text)
        #expect(banners == [L10n.transcriptImportResult(skipped: 1, untimed: 0, repeated: 0, dropped: [])])
        for (language, expected) in [("en", "Words with no clip: 1."), ("es", "Palabras sin clip: 1.")] {
            let table = try stringsTable(language)
            let text = L10n.transcriptImportResult(
                skipped: 1, untimed: 0, repeated: 0, dropped: [], text: { table[$0.rawValue] ?? "" })
            #expect(text == expected, "\(language)")
        }
        let all = L10n.transcriptImportResult(
            skipped: 1, untimed: 2, repeated: 3, dropped: ["a", "b"],
            text: { (try? stringsTable("en"))?[$0.rawValue] ?? "" })
        #expect(
            all
                == "Words with no clip: 1. Words with no time: 2. Words over repeated audio: 3. Transcripts dropped: a, b."
        )
        #expect(L10n.transcriptImportResult(skipped: 0, untimed: 0, repeated: 0, dropped: []) == nil)
        await model.close()
    }

    /// P6: the item is on with a track and no job, off with no track and during an import job.
    @Test func importItemStateInEachState() async throws {
        let (model, _, _, _) = try await open(try await package(spoken: false))
        #expect(model.isOn(.importTranscript), "idle, with a track")
        model.importJob = ImportJob()
        #expect(!model.isOn(.importTranscript), "an import job")
        model.importJob = nil

        let empty = folder.url.appending(path: "empty.dirigible")
        try Session.create(at: empty, sampleRate: 48_000)
        let bare = await app.open(empty)
        try #require(await bare.opened())
        #expect(!bare.isOn(.importTranscript), "no track")
        await bare.close()
        await model.close()
    }

    // MARK: P2

    /// P2: with no transcript, the tab shows no text view; the import brings the text view in.
    /// The title and the button show on screen (a SwiftUI button is no view in the test process).
    @Test func emptyState() async throws {
        let (model, studio, window, _) = try await open(try await package(spoken: false))
        model.showTranscript()
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(pane(window) == nil, "no text view with no transcript")
        model.importTranscript(from: try transcriptFile([(1, 1.5, "Hello")]), track: "t1")
        await finishImport(model)
        let text = try await waitForPane(window, focused: false)
        #expect(text.string.contains("Hello"), "the imported words show")
        model.undo()
        await until("the empty state comes back") { studio.session.transcriptNames.isEmpty && pane(window) == nil }
        await model.close()
    }
}
