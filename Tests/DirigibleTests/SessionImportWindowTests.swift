import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Import Session in the window (decision 0075; C12, C14, C15, C16). The target is a
/// `timelinePackage` with tracks T1 to Tn; the source is one with 3 tracks of 2 s of audio in its
/// own folder, so its session name is "timeline".
@MainActor struct SessionImportWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A source package with `tracks` tracks, each with one clip of 2 s from frame 0.
    func source(tracks: Int = 3) async throws -> URL {
        let parent = folder.url.appending(path: "source")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await timelinePackage(in: parent, tracks: tracks, seconds: 2, audio: true)
        FileManager.default.createFile(atPath: url.appending(path: ".lock").path, contents: nil)
        return url
    }

    func open(tracks: Int) async throws -> (SessionWindow, Studio) {
        let model = await app.open(try await timelinePackage(in: folder.url, tracks: tracks, seconds: 2, audio: true))
        let studio = try #require(await model.opened() ? model.studio : nil)
        await until("the window shows the lanes") { model.timelineView?.window != nil && model.timeline.visible != nil }
        return (model, studio)
    }

    func imported(_ model: SessionWindow, from source: URL) async {
        model.startSessionImport(source, markers: false)
        await until(limit: .seconds(30), "the import job ends") { model.importJob == nil }
    }

    /// C12: Import Session is the next File item after Import Transcript, which follows Import Audio.
    @Test func theMenuItemFollowsImportTranscript() throws {
        let commands = TimelineCommand.fileMenu.map(\.command)
        let audio = try #require(commands.firstIndex(of: .importAudio))
        let group = Array(commands[audio...].prefix(3))
        #expect(group == [.importAudio, .importTranscript, .importSession], "\(commands)")
        #expect(TimelineCommand.fileMenu.first { $0.command == .importSession }?.title == .menuFileImportSession)
    }

    /// C12: the panel takes session packages and says that the tracks are added; an import of the open
    /// session itself shows the plain refusal and changes nothing.
    @Test func thePanelMessageAndTheSameSessionRefusal() async throws {
        let panel = SessionImportPanel.make(defaults: nil).panel
        #expect(panel.message == L10n.importSessionPanelMessage.text)
        #expect(panel.allowedContentTypes == [AppDelegate.sessionType] && !panel.allowsMultipleSelection)

        let (model, studio) = try await open(tracks: 2)
        let before = studio.session
        await imported(model, from: studio.url)

        guard case .error(let error) = model.alert else {
            Issue.record("no alert: \(String(describing: model.alert))")
            return
        }
        #expect(error == .sessionImport(.sameSession, source: "timeline"), "\(error)")
        #expect(L10n.message(for: error) == L10n.errorImportSessionSame.text)
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }

    /// C14: the markers box is off at the first use and keeps the choice of the last import.
    @Test func theMarkersBoxStartsOffAndRemembersItsChoice() throws {
        let name = "SessionImportWindowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let first = SessionImportPanel.make(defaults: defaults).choice
        #expect(!first.markers, "the box is on at the first use")
        first.markers = true
        SessionImportPanel.remember(first, in: defaults)
        #expect(SessionImportPanel.make(defaults: defaults).choice.markers, "the box is off after an import with it on")
        let second = SessionImportPanel.make(defaults: defaults).choice
        second.markers = false
        SessionImportPanel.remember(second, in: defaults)
        #expect(!SessionImportPanel.make(defaults: defaults).choice.markers)
    }

    /// C15: with 2 old tracks and 3 new ones, the new tracks are the last ones and the selected
    /// ones, and the selection holds the new clips, so the move and nudge keys act on them.
    @Test func theNewTracksAreLastAndSelected() async throws {
        let (model, studio) = try await open(tracks: 2)
        model.timeline.selection = .range(Marks(tracks: ["t1"]))

        await imported(model, from: try await source())

        let ids = studio.session.tracks.map(\.id)
        #expect(ids.count == 5 && studio.session.tracks.map(\.name).prefix(2) == ["T1", "T2"])
        let new = Array(ids.suffix(3))
        #expect(model.timeline.selection.headerTracks(in: studio.session) == new, "\(model.timeline.selection)")
        let clips = Set(new.flatMap { studio.session.track($0)?.clips.map(\.id) ?? [] })
        let selected = Set(model.timeline.selection.selectedClips(in: studio.session).map(\.clip.id))
        #expect(clips.count == 3 && selected == clips, "\(selected)")
        await model.close()
    }

    /// C15: the lane of the first new track is in view after the import, also when it was below the
    /// visible rect.
    @Test func theFirstNewTrackScrollsIntoView() async throws {
        let (model, studio) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit)
        let view = try #require(model.timelineView)
        let height = try #require(view.lanes.inputs).laneHeight
        let lane = TimelineViewTests.tracksThatDoNotFit
        #expect(Double(lane + 1) * height > view.shown.maxY, "the first new lane is in view before the import")

        await imported(model, from: try await source())

        #expect(studio.session.tracks.count == lane + 3)
        await until("the first new lane is in view") {
            Double(lane) * height >= view.shown.minY - 0.5 && Double(lane + 1) * height <= view.shown.maxY + 0.5
        }
        await model.close()
    }

    /// C16: the result line shows in the banner place at the revision of the import and is posted
    /// to VoiceOver; the next edit hides it.
    @Test func theResultLineIsShownAndAnnounced() async throws {
        final class Dock { var announced: [String] = [] }
        let (model, studio) = try await open(tracks: 2)
        let dock = Dock()
        model.chrome?.announce = { text, _ in dock.announced.append(text) }

        await imported(model, from: try await source())

        let line = L10n.sessionImportLine(tracks: 3, muted: 0, leftOut: 0)
        let banners = ChromeState.reportBanners(model, studio)
        #expect(banners.contains { $0 == .sessionImported(line, press: 1) }, "\(banners)")
        #expect(dock.announced.contains(line), "\(dock.announced)")
        try studio.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t1", to: "Host") }
        #expect(!ChromeState.reportBanners(model, studio).contains { $0.key.hasPrefix("sessionImported") })
        await model.close()
    }

    /// C16: the one and the many forms of each sentence, no muted sentence with no muted call track,
    /// and no left-out sentence with no marker left out.
    @Test func theResultLineHasOneAndManyForms() throws {
        let english = try stringsTable("en")
        let table = { (key: L10n) in english[key.rawValue] ?? key.rawValue }
        #expect(
            L10n.sessionImportLine(tracks: 4, muted: 2, leftOut: 0, table: table)
                == "Added 4 tracks at their recorded positions. 2 call tracks are muted: they repeat the other voice.")
        #expect(
            L10n.sessionImportLine(tracks: 1, muted: 0, leftOut: 0, table: table)
                == "Added 1 track at its recorded position.")
        #expect(
            L10n.sessionImportLine(tracks: 2, muted: 1, leftOut: 0, table: table)
                == "Added 2 tracks at their recorded positions. 1 call track is muted: it repeats the other voice.")
        #expect(
            L10n.sessionImportLine(tracks: 2, muted: 0, leftOut: 1, table: table)
                == "Added 2 tracks at their recorded positions. 1 marker is left out: its position is after the end "
                + "of the timeline.")
        #expect(
            L10n.sessionImportLine(tracks: 1, muted: 1, leftOut: 3, table: table)
                == "Added 1 track at its recorded position. 1 call track is muted: it repeats the other voice. "
                + "3 markers are left out: their positions are after the end of the timeline.")
    }

    /// C12: a refused source names the source session, then gives the open refusal text unchanged.
    @Test func aRefusedSourceNamesTheSourceSession() async throws {
        try await HeaderStateLineTests().withStrings("en") {
            #expect(
                L10n.message(for: .source(.unsafeItem("Clips/a.wav")), source: "Guest")
                    == "Dirigible did not import the session \u{201C}Guest\u{201D}. \u{201C}Clips/a.wav\u{201D} in this "
                    + "package is a link, a special file, or an item of the wrong kind, so Dirigible does not open the "
                    + "package. Replace that item with a plain file or folder, or remove it.")
            #expect(
                L10n.message(for: .source(.unsupportedVersion(99)), source: "Guest")
                    == "Dirigible did not import the session \u{201C}Guest\u{201D}. "
                    + L10n.message(for: SessionFileError.unsupportedVersion(99)))
        }
    }

    /// A copy fault of the import names the import, never a paste or a copy to do again, and a
    /// session refusal gives the session text, not the generic one.
    @Test func aCopyFaultNamesTheImportNotThePaste() async throws {
        try await HeaderStateLineTests().withStrings("en") {
            let faults: [PasteError] = [
                .sourceMissing(file: "a.wav"), .sourceChanged(file: "a.wav"), .space(needed: 2, free: 1),
                .write(file: "a.wav", errno: ENOSPC), .write(file: "a.wav", errno: EIO),
                .convert(file: "a.wav", errno: EIO),
            ]
            for fault in faults {
                let text = L10n.message(for: SessionImportError.paste(fault), source: "Guest")
                #expect(text.hasPrefix("Dirigible did not import the session \u{201C}Guest\u{201D}: "), "\(text)")
                #expect(!text.localizedCaseInsensitiveContains("paste"), "\(text)")
                #expect(!text.localizedCaseInsensitiveContains("copy again"), "\(text)")
            }
            #expect(
                L10n.message(for: SessionImportError.paste(.write(file: "a.wav", errno: EIO)), source: "Guest")
                    == "Dirigible did not import the session \u{201C}Guest\u{201D}: the audio did not copy (error 5). "
                    + "Check the disk and try again.")
            #expect(
                L10n.message(for: SessionImportError.paste(.session(.trackCount(300))), source: "Guest")
                    == L10n.message(for: StudioError.session(.trackCount(300))))
        }
    }
}
