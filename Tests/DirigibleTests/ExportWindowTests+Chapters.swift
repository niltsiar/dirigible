import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Export Chapters (run 2026-10-09-chapters-export, criteria C14 to C18) on a real session
/// window of 10 s. The save panel is a stub that gives a URL in the test folder.
extension ExportWindowTests {
    /// The start times of a chapters file.
    func startTimes(_ url: URL) throws -> [Double] {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(file["chapters"] as? [[String: Any]]).compactMap { $0["startTime"] as? Double }
    }

    func addChapter(at position: Frames, _ studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID(), name: "Chapter", position: position, kind: .chapter))
        }
    }

    /// The panel stub: it keeps the name and the message, and answers `url` with the item there now
    /// as the confirmed item, as the panel does.
    func chaptersPanel(_ url: URL?) -> OSAllocatedUnfairLock<[(String, String?)]> {
        let calls = OSAllocatedUnfairLock<[(String, String?)]>(initialState: [])
        app.chooseChaptersExport = { _, name, message, done in
            calls.withLock { $0.append((name, message)) }
            done(url.map { ChaptersTarget(url: $0, confirmed: ConfirmedFile(at: $0)) })
        }
        return calls
    }

    /// C14. Each start state of the item.
    @Test func theItemFollowsTheChapters() async throws {
        let (model, studio, _) = try await window()
        #expect(!model.isOn(.exportChapters), "no chapter")
        try addChapter(at: 240_000, studio)
        #expect(model.isOn(.exportChapters), "a chapter, no Marks")
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        #expect(!model.isOn(.exportChapters), "the Marks on a range with no chapter, a chapter outside")
        model.timeline.marks = nil
        model.exportStep = .checking
        #expect(!model.isOn(.exportChapters), "an export step")
        model.exportStep = nil
        await model.close()
    }

    /// Code gate item 1. A chapter at or after the session end is past the audio: the item is off,
    /// also when the session has no clip.
    @Test func aChapterPastTheAudioLeavesTheItemOff() async throws {
        let (model, studio, _) = try await window()
        try addChapter(at: 480_000, studio)
        #expect(!model.isOn(.exportChapters), "a chapter at the session end")
        try studio.edit(ripple: false) { session throws(SessionError) in try session.removeClips(["c1"]) }
        #expect(studio.session.end == .zero)
        #expect(!model.isOn(.exportChapters), "no clip")
        await model.close()
    }

    /// C15, the release-line test. Control: the range 0..<end gives 4, not 2.
    @Test func exportSelectionRangeGivesTheOffset() async throws {
        let file = folder.url.appending(path: "chosen.json")
        let calls = chaptersPanel(file)
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 384_000, tracks: ["t1"])
        model.run(.exportChapters)
        await until("the file is written") { FileManager.default.fileExists(atPath: file.path) }
        #expect(try startTimes(file) == [2])
        let call = try #require(calls.withLock { $0 }.first)
        #expect(call.0 == "timeline.chapters.json" && call.1 == L10n.panelChaptersMarks.text)
        #expect(model.exportStep == nil && model.alert == nil)
        await model.close()
    }

    /// C16. No Marks, and the Marks with no selected track, give the whole session and no message.
    @Test func noMarksGivesTheWholeSessionAndNoMessage() async throws {
        let (first, second) = (folder.url.appending(path: "a.json"), folder.url.appending(path: "b.json"))
        let calls = chaptersPanel(first)
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        model.exportChapters()
        await until("the first file is written") { FileManager.default.fileExists(atPath: first.path) }
        _ = chaptersPanel(second)
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 384_000, tracks: [])
        model.exportChapters()
        await until("the second file is written") { FileManager.default.fileExists(atPath: second.path) }
        #expect(try startTimes(first) == [4] && startTimes(second) == [4])
        #expect(calls.withLock { $0 }.map(\.1) == [nil])
        await model.close()
    }

    /// C17.
    @Test func aCancelWritesNothing() async throws {
        let calls = chaptersPanel(nil)
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        model.exportChapters()
        #expect(calls.withLock { $0.count } == 1, "the panel showed")
        #expect(model.exportStep == nil && model.alert == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == before)
        await model.close()
    }

    /// C18. The errno under the CocoaError is the key, not the Cocoa code (probe-errno).
    @Test func writeErrorsKeepTheErrnoUnit() {
        let full = CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOSPC)])
        #expect(ExportError(writing: full) == .diskFull)
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: POSIXError(.EACCES)])
        #expect(ExportError(writing: denied) == .moveFailed(EACCES))
        #expect(ExportError(writing: CocoaError(.fileWriteUnknown)) == .moveFailed(EIO))
    }

    /// C18. A folder that does not exist gives errno ENOENT (probe-errno), so the move alert.
    @Test func aMissingFolderShowsTheMoveAlert() async throws {
        _ = chaptersPanel(folder.url.appending(path: "gone/x.json"))
        let (model, studio, _) = try await window()
        try addChapter(at: 192_000, studio)
        model.exportChapters()
        await until("the alert shows") { model.alert != nil }
        #expect(model.alert == .error(.export(.moveFailed(ENOENT))))
        await model.close()
    }

    /// Run 2026-10-11-chapters-in-file, C5f: a second chapter at one start is not in the file,
    /// and a warning banner names it.
    @Test func aChaptersFileWithADroppedChapterShowsAWarningBanner() async throws {
        let file = folder.url.appending(path: "dropped.json")
        _ = chaptersPanel(file)
        let (model, studio, _) = try await window()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "a", name: "A", position: 192_000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "C", position: 192_000, kind: .chapter))
        }
        model.exportChapters()
        await until("the file is written") { FileManager.default.fileExists(atPath: file.path) }
        #expect(try startTimes(file) == [4])
        await until("the banner shows") {
            model.shown.banners.contains(.chaptersDropped(["C"], file: "dropped.json"))
        }
        await model.close()
    }

    /// Run 2026-10-11-chapters-in-file, C3b. The save panel confirms only the JSON name: an
    /// existing file at the name of a chapter image shows the exists alert, and nothing is written.
    /// Code gate item E1: the alert names the image file and says what to do.
    @Test func anExistingChapterImageShowsTheExistsAlert() async throws {
        let file = folder.url.appending(path: "show.json")
        _ = chaptersPanel(file)
        let (model, studio, _) = try await window()
        let image = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        let source = model.url.appending(path: image.path)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpeg bytes".utf8).write(to: source)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "c", name: "C", position: 192_000, kind: .chapter, image: image))
        }
        let picture = folder.url.appending(path: "show-1.jpg")
        try Data("old".utf8).write(to: picture)
        model.exportChapters()
        await until("the alert shows") { model.alert != nil }
        let error = StudioError.export(.chapterImageExists(picture.path))
        #expect(model.alert == .error(error))
        #expect(!FileManager.default.fileExists(atPath: file.path), "a JSON")
        #expect(try Data(contentsOf: picture) == Data("old".utf8), "the old image changed")
        let key = "error.export.chapter.image.exists"
        #expect(L10n.message(for: error) == key)
        let texts = [
            "en": "The chapter image show-1.jpg exists beside this name. Move it, or choose another name.",
            "es": "La imagen de capítulo show-1.jpg ya existe junto a este nombre. Muévela o elige otro nombre.",
        ]
        for (language, text) in texts {
            let format = try #require(try stringsTable(language)[key], "\(language)")
            #expect(String(format: format, "show-1.jpg") == text, "\(language)")
        }
        await model.close()
    }

    /// Code gate item D1. A second export to a name that the save panel confirmed replaces the JSON
    /// and its chapter images.
    @Test func aConfirmedReplaceAlsoReplacesTheChapterImages() async throws {
        let file = folder.url.appending(path: "show.json")
        _ = chaptersPanel(file)
        let (model, studio, _) = try await window()
        let image = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        let source = model.url.appending(path: image.path)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: source)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "c", name: "C", position: 192_000, kind: .chapter, image: image))
        }
        let picture = folder.url.appending(path: "show-1.jpg")
        model.exportChapters()
        // The images are written before the JSON, so the wait is for the JSON.
        await until("the first file is written") { FileManager.default.fileExists(atPath: file.path) }
        #expect(try Data(contentsOf: picture) == Data("first".utf8))
        try Data("second".utf8).write(to: source)
        model.exportChapters()
        await until("the second image is written or the alert shows") {
            model.alert != nil || (try? Data(contentsOf: picture)) == Data("second".utf8)
        }
        #expect(model.alert == nil, "alert \(String(describing: model.alert))")
        #expect(try startTimes(file) == [4])
        await model.close()
    }

    /// Code gate item E3. Only the save panel confirms a replace: a JSON that appears after the panel
    /// and before the write does not let the export replace the chapter images.
    @Test func aJSONAfterThePanelDoesNotReplaceTheChapterImages() async throws {
        let file = folder.url.appending(path: "show.json")
        let picture = folder.url.appending(path: "show-1.jpg")
        app.chooseChaptersExport = { _, _, _, done in
            try? Data("old json".utf8).write(to: file)
            try? Data("old".utf8).write(to: picture)
            done(ChaptersTarget(url: file, confirmed: nil))
        }
        let (model, studio, _) = try await window()
        let image = try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")
        let source = model.url.appending(path: image.path)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "c", name: "C", position: 192_000, kind: .chapter, image: image))
        }
        model.exportChapters()
        await until("the alert shows or the image changes") {
            model.alert != nil || (try? Data(contentsOf: picture)) != Data("old".utf8)
        }
        #expect(model.alert == .error(.export(.chapterImageExists(picture.path))))
        #expect(try Data(contentsOf: picture) == Data("old".utf8), "the old image changed")
        #expect(try Data(contentsOf: file) == Data("old json".utf8), "the JSON changed")
        await model.close()
    }

    /// Code gate item D2. A chapter image file that is not in the package shows an alert that names
    /// the chapter and its time and points to Marker Info, not to Episode Info. No file is written.
    @Test func aMissingChapterImageShowsTheChapterAlert() async throws {
        let file = folder.url.appending(path: "show.json")
        _ = chaptersPanel(file)
        let (model, studio, _) = try await window()
        let chapter = Marker(
            id: "c", name: "Talk", position: 192_000, kind: .chapter,
            image: try ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg"))
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMarker(chapter) }
        model.exportChapters()
        await until("the alert shows") { model.alert != nil }
        let error = StudioError.export(.chapterImageMissing(chapter, rate: 48_000))
        #expect(model.alert == .error(error))
        #expect(!FileManager.default.fileExists(atPath: file.path), "a JSON")
        #expect(L10n.message(for: error) == L10n.errorExportChapterImage.rawValue)
        let texts = [
            "en": "The image of chapter \u{201C}Talk\u{201D} at 0:00:04.000 can't be opened. "
                + "Choose it again in Markers > Marker Info.",
            "es": "No se puede abrir la imagen del capítulo \u{AB}Talk\u{BB} en 0:00:04.000. "
                + "Elígela de nuevo en Marcadores > Información del marcador.",
        ]
        for (language, text) in texts {
            let format = try #require(try stringsTable(language)[L10n.errorExportChapterImage.rawValue], "\(language)")
            #expect(String(format: format, "Talk", "0:00:04.000") == text, "\(language)")
        }
        await model.close()
    }
}
