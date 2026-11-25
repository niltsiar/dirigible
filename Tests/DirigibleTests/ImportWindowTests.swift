import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Import Audio… on a real session window (run 13a, C3 a to c, C6, C9, C10, and C13). The
/// open panel is manual check M1: the tests give the app a panel that answers at once.
@Suite(.serialized) @MainActor struct ImportWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let source: URL

    init() throws {
        folder = try TemporaryFolder()
        source = folder.url.appending(path: "Voice.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = 192_000
        for n in 0..<192_000 { buffer.floatChannelData![0][n] = Float(0.25 * sin(Double(n) / 7.6)) }
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        let source = source
        app.chooseImport = { _, done in done(source) }
    }

    /// A key window with the lanes of tracks t1 and t2, each with a 2 s clip from 0.
    func open() async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await timelinePackage(in: folder.url, tracks: 2, seconds: 2, audio: true)
        let (model, studio, window, _) = try await openLanes(app, package)
        return (model, studio, window)
    }

    func waitForTheImport(_ model: SessionWindow) async {
        await until("the import ends") { model.importJob == nil }
    }

    @Test func importAudioPutsTheClipAtThePlayheadOnTheSelectedTrack() async throws {
        let (model, studio, _) = try await open()
        await studio.perform(.seek(.frame(96_000)))
        model.timeline.selection = .range(Marks(tracks: ["t2"]))

        model.run(TimelineCommand.importAudio)
        await waitForTheImport(model)

        let placed = studio.session.clip("Voice")
        #expect(placed?.track == "t2" && placed?.clip.start == 96_000, "the clip is at the playhead on t2")
        #expect(model.timeline.selection == ClipSet(["Voice"]).map { .clips($0) }, "the new clip is selected")
        #expect(model.alert == nil)
        await model.close()
    }

    /// C3 a to c: the one selected track, else a new track; a clip set selects no track.
    @Test func theTargetIsTheOneSelectedTrackElseANewTrack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "A", layout: .mono)
        try session.addTrack("t2", name: "B", layout: .mono)
        let cases: [(Selection, TrackID?)] = [
            (.none, nil), (.range(Marks(tracks: ["t1"])), "t1"), (.range(Marks(tracks: ["t1", "t2"])), nil),
            (.range(Marks(inPoint: 0, outPoint: 480, tracks: ["t2"])), "t2"),
            (ClipSet(["c1"]).map { .clips($0) } ?? .none, nil),
        ]
        for (selection, track) in cases {
            #expect(
                importTarget(selection, in: session, playhead: 480) == ImportTarget(track: track, start: 480),
                "\(selection)")
        }
        #expect(importTarget(.none, in: Session(sampleRate: 48_000), playhead: 0).track == nil, "an empty session")
    }

    /// C9: Command-T runs the item with the timeline focused and with a track name field focused.
    @Test func commandTRunsTheItemAlsoFromANameField() async throws {
        let (_, _, window) = try await open()
        var calls = 0
        app.chooseImport = { _, done in
            calls += 1
            done(nil)
        }

        app.timeline(.importAudio, event: try cgKey(17, .maskCommand), in: window)
        #expect(calls == 1, "the timeline focused")
        _ = try await focusName(in: window)
        app.timeline(.importAudio, event: try cgKey(17, .maskCommand), in: window)
        #expect(calls == 2, "a track name field focused")
        await app.key?.close()
    }

    /// C9: no window tab item (New Tab) can take Command-T.
    @Test func noSystemItemTakesCommandT() async throws {
        let (model, _, window) = try await open()
        #expect(window.tabbingMode == .disallowed, "the window has no tabs")
        let items = NSApp.mainMenu.map(allItems) ?? []
        let commandT = items.filter { $0.keyEquivalent == "t" && $0.keyEquivalentModifierMask == .command }
        #expect(commandT.allSatisfy { $0.title == L10n.menuFileImport.text }, "\(commandT.map(\.title))")
        await model.close()
    }

    func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items + menu.items.compactMap(\.submenu).flatMap(allItems)
    }

    /// C9: off during a take; during play it runs and play stops.
    @Test func theItemIsOffDuringATakeAndRunsDuringPlay() async throws {
        let (model, studio, _) = try await open()
        #expect(model.isOn(.importAudio))
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.importAudio), "off during a take")
        studio.transport = .idle
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        #expect(studio.playback != .stopped)

        model.run(TimelineCommand.importAudio)
        await waitForTheImport(model)

        #expect(studio.playback == .stopped && studio.session.clip("Voice") != nil, "play stops; the import runs")
        await model.close()
    }

    /// C6 and C10: during an import, Record, the edit items, and the item itself do nothing and
    /// show no alert; the banner has the name; Cancel ends the import within 1 s.
    @Test func duringAnImportTheItemsAreOffAndCancelEndsIt() async throws {
        let (model, studio, _) = try await open()
        let hold = DispatchSemaphore(value: 0)
        let (entered, steps) = (LockedFlag(), LockedCount())
        studio.environment.importStep = {
            steps.add()
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        await studio.perform(.seek(.frame(48_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        #expect(model.canRecord, "Record is on before the import")
        let before = studio.session

        model.run(TimelineCommand.importAudio)
        await until("the import holds") { entered.value }

        #expect(model.importJob != nil && studio.importRun?.name == "Voice.wav", "the banner name")
        #expect(!model.canRecord && !model.isOn(.importAudio), "Record and Import Audio are off")
        // Phase 7: the edit items with no text-field key are off. The items whose key a field
        // uses stay on and do nothing (0018 K1), as below.
        let edits: [TimelineCommand] = [.insert, .cutSelectedTracks, .fade, .autoLevel, .autoLevelPerTrack]
        #expect(edits.filter { model.isOn($0) }.isEmpty, "the edit items are off during the import")
        let fieldKeys: [TimelineCommand] = [
            .cut, .copy, .paste, .delete, .selectAll, .split, .nudgeLeft, .deleteCloseGap,
        ]
        #expect(fieldKeys.allSatisfy { model.isOn($0) }, "the items whose key a field uses stay on (K1)")
        model.run(TimelineCommand.split)
        model.run(TimelineCommand.removeTrack)
        #expect(studio.session == before && model.alert == nil, "the edit items do nothing and show no alert")
        model.cancelImport()
        hold.signal()
        await waitForTheImport(model)

        // The 4 s file has 3 blocks. On screen, the banner ends 0.73 s after Cancel (decisions.tsv).
        #expect(steps.value <= 3, "Cancel ends the import within one block: \(steps.value) steps")
        #expect(model.alert == nil && studio.session == before, "a cancel shows nothing and changes nothing")
        model.run(TimelineCommand.split)
        #expect(studio.session != before, "after the import, Split acts")
        #expect(edits.allSatisfy { model.isOn($0) }, "after the import, the edit items are on")
        await model.close()
    }

    /// Run app-bug-batch C4a to C4c: during an import, Undo and Redo are off for the responder that
    /// the menu items reach. After the import, Undo is on and Redo is off. A pin: the
    /// run 13a reads of Undo on during an import do not reproduce on main (logs/s1-onscreen-menu.log).
    /// History 0: empty, 1: an Undo entry, 2: a Redo entry. Focus 1: the lanes, 2: a track name field.
    @Test(arguments: [0, 1, 2], [1, 2])
    func undoAndRedoAreOffDuringAnImport(history: Int, focus: Int) async throws {
        let (model, studio, window) = try await open()
        if history > 0 { model.addTrack() }
        if history == 2 { model.undo() }
        if focus == 1 { #expect(window.makeFirstResponder(model.timelineView?.documentView)) }
        if focus == 2 { _ = try await focusName(in: window) }
        #expect(studio.canUndo == (history == 1) && studio.canRedo == (history == 2))
        let hold = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        model.run(TimelineCommand.importAudio)
        await until("the import holds") { entered.value }

        let undo = try #require(menuTarget(#selector(UndoRoutingWindow.undo(_:)), in: window))
        let redo = try #require(menuTarget(#selector(UndoRoutingWindow.redo(_:)), in: window))
        #expect(!isOn(#selector(UndoRoutingWindow.undo(_:)), undo), "Undo is off during the import")
        #expect(!isOn(#selector(UndoRoutingWindow.redo(_:)), redo), "Redo is off during the import")
        hold.signal()
        await waitForTheImport(model)

        #expect(studio.session.clip("Voice") != nil, "the import ends with its clip")
        #expect(isOn(#selector(UndoRoutingWindow.undo(_:)), undo), "Undo is on after the import")
        #expect(!isOn(#selector(UndoRoutingWindow.redo(_:)), redo), "Redo is off after the import")
        await model.close()
    }

    /// The first responder of the chain of `window` that answers `action`, as a menu item with
    /// no target finds it. Nil when no responder of the window answers.
    func menuTarget(_ action: Selector, in window: NSWindow) -> NSResponder? {
        var next = window.firstResponder
        while let responder = next, !responder.responds(to: action) { next = responder.nextResponder }
        return next
    }

    /// The enabled state that AppKit gives a menu item with `action` on `target`.
    func isOn(_ action: Selector, _ target: NSResponder) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        if let target = target as? NSMenuItemValidation { return target.validateMenuItem(item) }
        if let target = target as? NSUserInterfaceValidations { return target.validateUserInterfaceItem(item) }
        return true
    }

    /// Code gate 1 item 6: progress hops can arrive out of order; the bar never goes back.
    @Test func theProgressNeverGoesDown() async throws {
        let (model, _, _) = try await open()
        model.importJob = ImportJob()

        model.importProgressed(0.6)
        model.importProgressed(0.4)

        #expect(model.importJob?.progress == 0.6, "progress never goes down")
        model.importJob = nil
        await model.close()
    }

    /// Code gate 1 (run 13c) item 2: a late hop of file 1 of a chain does not fill the bar of file 2.
    @Test func aLateHopOfAnEarlierFileChangesNothing() async throws {
        let (model, _, _) = try await open()
        model.importJob = ImportJob(file: 1)

        model.importProgressed(1, file: 0)
        #expect(model.importJob?.progress == 0, "a hop of file 1 during file 2")
        model.importProgressed(0.3, file: 1)
        #expect(model.importJob?.progress == 0.3, "a hop of file 2")

        model.importJob = nil
        await model.close()
    }

    @Test func aFailedImportShowsItsAlert() async throws {
        let (model, studio, _) = try await open()
        let text = folder.url.appending(path: "notes.mp3")
        try Data("hello".utf8).write(to: text)
        app.chooseImport = { _, done in done(text) }

        model.run(TimelineCommand.importAudio)
        await waitForTheImport(model)

        #expect(model.alert == .error(.audioImport(.notAudio(file: "notes.mp3"))))
        #expect(studio.transport == .idle)
        await model.close()
    }

    /// C13: each text quotes the file and says what to do, in English and Spanish. The test
    /// process has no string table in `Bundle.main`, so `L10n.message` gives the key.
    @Test func theErrorTextsNameTheFileAndTheFix() throws {
        let cases: [(StudioError, L10n, [any CVarArg], String, String)] = [
            (
                .audioImport(.notAudio(file: "Talk.m4p")), .errorImportNotAudio, ["Talk.m4p"],
                "“Talk.m4p” can't be imported. The audio in this file can't be read. Use a WAV, AIFF, FLAC, MP3, or M4A file.",
                "«Talk.m4p» no se puede importar. No se puede leer el audio de este archivo. Usa un archivo WAV, AIFF, FLAC, MP3 o M4A."
            ),
            (
                .audioImport(.notDownloaded(file: "Talk.mp3")), .errorImportNotDownloaded, ["Talk.mp3"],
                "“Talk.mp3” can't be imported. The file isn't on this Mac. Download the file first.",
                "«Talk.mp3» no se puede importar. El archivo no está en este Mac. Descarga primero el archivo."
            ),
            (
                .audioImport(.tooManyChannels(file: "Talk.wav", channels: 6)), .errorImportChannels, ["Talk.wav", 6],
                "“Talk.wav” can't be imported. The file has 6 channels. Dirigible imports only mono and stereo files. Split the file into mono or stereo files.",
                "«Talk.wav» no se puede importar. El archivo tiene 6 canales. Dirigible solo importa archivos mono y estéreo. Divide el archivo en archivos mono o estéreo."
            ),
            (
                .audioImport(.space(file: "Talk.mp3", needed: 2, free: 1)), .errorImportSpace,
                ["Talk.mp3", "2 GB", "1 GB"],
                "“Talk.mp3” can't be imported. The import needs 2 GB of free disk space, and the disk has 1 GB. Free some disk space and try again.",
                "«Talk.mp3» no se puede importar. La importación necesita 2 GB de espacio libre, y el disco tiene 1 GB. Libera espacio en el disco y vuelve a intentarlo."
            ),
            (
                .audioImport(.unreadable(file: "Talk.mp3", errno: EIO)), .errorImportUnreadable, ["Talk.mp3", 5],
                "“Talk.mp3” can't be imported. The file couldn't be read (error 5). Copy the file to this Mac and try again.",
                "«Talk.mp3» no se puede importar. El archivo no se pudo leer (error 5). Copia el archivo a este Mac y vuelve a intentarlo."
            ),
            (
                .audioImport(.write(file: "Talk.mp3", .writeFailed(file: "Clips/Talk.wav", status: 28))),
                .errorImportWrite, ["Talk.mp3", 28],
                "“Talk.mp3” can't be imported. The Clips folder of the session can't be written to (error 28). Check the disk and try again.",
                "«Talk.mp3» no se puede importar. No se puede escribir en la carpeta Clips de la sesión (error 28). Comprueba el disco y vuelve a intentarlo."
            ),
            (
                .importYielded(file: "Talk.mp3"), .errorImportYielded, ["Talk.mp3"],
                "The import of “Talk.mp3” stopped for a take in another window. Import again after the take.",
                "La importación de «Talk.mp3» se detuvo por una toma en otra ventana. Vuelve a importar después de la toma."
            ),
        ]
        for (error, key, arguments, en, es) in cases {
            #expect(L10n.message(for: error) == key.rawValue, "\(error)")
            for (language, text) in [("en", en), ("es", es)] {
                let format = try #require(try stringsTable(language)[key.rawValue], "\(language) \(key.rawValue)")
                #expect(String(format: format, arguments: arguments) == text, "\(language) \(key.rawValue)")
            }
        }
        #expect(L10n.message(for: .audioImport(.cancelled)) == "", "a cancel has no text")
    }
}

/// A count that the import thread adds to and the test reads.
final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }
    func add() { lock.withLock { stored += 1 } }
}

/// A flag that the import thread sets and the test reads.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
