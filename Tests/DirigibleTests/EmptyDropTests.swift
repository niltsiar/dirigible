import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A Finder drop of audio files on a session with no tracks (run empty-drop-lane-click, D1 to D9).
/// A fake `NSDraggingInfo` gives the drag; the Finder drag itself is manual check M1.
@Suite(.serialized) @MainActor struct EmptyDropTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        folder = try TemporaryFolder()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A WAV of 1 s of silence in the test folder.
    func wav(_ name: String, channels: Int = 1, rate: Int = 48_000) throws -> URL {
        let url = folder.url.appending(path: name)
        try writeSilentWAV(url, channels: channels, rate: rate)
        return url
    }

    /// An open session at 48 kHz with no tracks, and its window.
    func openEmpty() async throws -> (SessionWindow, Studio, NSWindow) {
        let url = folder.url.appending(path: "empty.dirigible")
        try await Task.detached { try Session.create(at: url, sampleRate: 48_000) }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        return (model, studio, try #require(model.window))
    }

    /// The view of the empty window that takes a file drag: the one that registers for file URLs.
    func host(in window: NSWindow) async throws -> NSView {
        var found: NSView?
        await until(limit: .seconds(10), "the empty window has a view that takes a file drag") {
            window.contentView?.layoutSubtreeIfNeeded()
            found = dragTargets(under: window.contentView).first
            return found != nil
        }
        return try #require(found)
    }

    private func dragTargets(under view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return (view.registeredDraggedTypes.contains(.fileURL) ? [view] : [])
            + view.subviews.flatMap { dragTargets(under: $0) }
    }

    /// Enters, drops, and ends a drag of `urls` on `host`, as AppKit does after an accepted drop,
    /// then waits for the import. False when the drag or the drop is refused.
    func drop(_ urls: [URL], on host: NSView, _ model: SessionWindow) async -> Bool {
        let drag = fileDrag(urls)
        guard host.draggingEntered(drag) == .copy, host.performDragOperation(drag) else { return false }
        host.concludeDragOperation(drag)
        host.draggingEnded(drag)
        await until("the import ends") { model.importJob == nil }
        return true
    }

    /// D1: one mono file makes one mono track at frame 0, and the lanes show.
    @Test func aDropOnAnEmptySessionMakesATrack() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)

        #expect(await drop([try wav("Host.wav")], on: host, model))

        let track = try #require(studio.session.tracks.first)
        #expect(studio.session.tracks.count == 1 && track.name == "Host" && track.layout == .mono, "one mono track")
        let placed = studio.session.clip("Host")
        #expect(placed?.track == track.id && placed?.clip.start == 0 && placed?.clip.length == 48_000, "the clip")
        #expect(model.timeline.selection == ClipSet(["Host"]).map { .clips($0) }, "the new clip is selected")
        await until(limit: .seconds(10), "the window shows the lanes") { model.timelineView?.window != nil }
        await model.close()
    }

    /// D2: three files make three tracks in the drag order, each clip at frame 0. One Undo removes
    /// the last track; three Undos show the empty state again.
    @Test func aDropOfThreeFilesMakesOneTrackEachInDragOrder() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)

        #expect(await drop([try wav("b.wav"), try wav("a.wav"), try wav("c.wav")], on: host, model))

        #expect(studio.session.tracks.map(\.name) == ["b", "a", "c"], "the drag order")
        #expect(["b", "a", "c"].allSatisfy { studio.session.clip(ClipID($0))?.clip.start == 0 }, "each clip at 0")
        #expect(model.timeline.selection == ClipSet(["a", "b", "c"]).map { .clips($0) }, "the three clips")
        model.undo()
        #expect(studio.session.tracks.map(\.name) == ["b", "a"], "one Undo removes the track of c")
        model.undo()
        model.undo()
        #expect(studio.session.tracks.isEmpty, "three Undos")
        _ = try await self.host(in: window)
        await model.close()
    }

    /// D3: a mono file and a stereo file make a mono track and a stereo track.
    @Test func eachNewTrackTakesTheLayoutOfItsFile() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)

        #expect(await drop([try wav("m.wav"), try wav("s.wav", channels: 2)], on: host, model))

        #expect(studio.session.tracks.map(\.layout) == [.mono, .stereo])
        await model.close()
    }

    /// D4: a file at 44.1 kHz converts to the session rate of 48 kHz.
    @Test func aFileAtAnotherRateConvertsToTheSessionRate() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)

        #expect(await drop([try wav("low.wav", rate: 44_100), try wav("high.wav")], on: host, model))

        for name in ["low", "high"] {
            let length = try #require(studio.session.clip(ClipID(name))?.clip.length.count)
            #expect(abs(length - 48_000) <= 1, "\(name) has \(length) frames")
        }
        #expect(studio.session.sampleRate == 48_000)
        await model.close()
    }

    /// D5: a text file gets no operation, and a drop of it imports nothing.
    @Test func aTextFileGetsNoOperationOnAnEmptySession() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)
        let text = folder.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        let refused = fileDrag([text])
        #expect(host.draggingEntered(refused) == [], "the enter of a text file")
        #expect(host.draggingUpdated(refused) == [], "an update of a text file")
        #expect(!host.performDragOperation(refused), "a drop of a text file")
        #expect(studio.session.tracks.isEmpty && model.importJob == nil, "nothing imports")

        let accepted = fileDrag([try wav("Voice.wav")])
        #expect(host.draggingEntered(accepted) == .copy, "a WAV gets copy")
        host.draggingExited(accepted)
        await model.close()
    }

    /// D6: a mixed drag takes only its audio file.
    @Test func aMixedDragImportsOnlyTheAudioFile() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)
        let text = folder.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        let drag = fileDrag([text, try wav("a.wav")])
        #expect(host.draggingEntered(drag) == .copy && drag.numberOfValidItemsForDrop == 1)
        #expect(host.performDragOperation(drag))
        await until("the import ends") { model.importJob == nil }

        #expect(studio.session.tracks.map(\.name) == ["a"])
        await model.close()
    }

    /// D7: a file with 3 channels is skipped and named; no track and no file stays for it.
    @Test func aThreeChannelMiddleFileIsSkippedAndNamed() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)
        let files = [try wav("a.wav"), try wav("x.wav", channels: 3), try wav("c.wav")]

        #expect(await drop(files, on: host, model))

        #expect(studio.session.tracks.map(\.name) == ["a", "c"], "files 1 and 3 import")
        #expect(
            model.alert == .importChain([.audioImport(.tooManyChannels(file: "x.wav", channels: 3))], notImported: [])
        )
        let kept = try FileManager.default.contentsOfDirectory(atPath: studio.url.appending(path: "Clips").path)
        #expect(kept.sorted() == ["a.wav"], "the refused file leaves no file, and c shares the audio of a: \(kept)")
        await model.close()
    }

    /// D8: during an import a drag gets no operation and a drop imports nothing; idle, it gets copy.
    @Test func aDragDuringAnImportGetsNoOperation() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)
        let voice = try wav("Voice.wav")

        let idle = fileDrag([voice])
        #expect(host.draggingEntered(idle) == .copy, "an idle window gets copy")
        host.draggingExited(idle)

        model.importJob = ImportJob()
        let busy = fileDrag([voice])
        #expect(host.draggingEntered(busy) == [], "a drag during an import")
        #expect(!host.performDragOperation(busy), "a drop during an import")

        let late = fileDrag([voice])
        model.importJob = nil
        #expect(host.draggingEntered(late) == .copy)
        model.importJob = ImportJob()
        #expect(host.draggingUpdated(late) == [], "an import that starts after the enter")
        #expect(!host.performDragOperation(late), "a drop after it")
        model.importJob = nil
        #expect(studio.session.tracks.isEmpty, "nothing imports")
        await model.close()
    }

    /// D9: after an exit, the end of a drag, a refused drop, and a drop, the host holds no file: a
    /// drop with no new enter imports nothing.
    @Test func anExitClearsTheEmptyHost() async throws {
        let (model, studio, window) = try await openEmpty()
        let host = try await host(in: window)
        let drag = fileDrag([try wav("Voice.wav")])

        _ = host.draggingEntered(drag)
        host.draggingExited(drag)
        #expect(!host.performDragOperation(drag), "after an exit")

        _ = host.draggingEntered(drag)
        host.draggingEnded(drag)
        #expect(!host.performDragOperation(drag), "after the end of the drag")

        _ = host.draggingEntered(drag)
        host.concludeDragOperation(drag)
        #expect(!host.performDragOperation(drag), "after a conclude")

        _ = host.draggingEntered(drag)
        model.importJob = ImportJob()
        #expect(!host.performDragOperation(drag), "a refused drop")
        model.importJob = nil
        #expect(!host.performDragOperation(drag), "after a refused drop")
        #expect(studio.session.tracks.isEmpty, "nothing imports")
        await model.close()
    }

    /// D11: the cue shows during an accepted drag, with the 13c label for the files, 2 pt lines
    /// with Increase Contrast, and the label color of the palette of the window. A refused drag,
    /// an exit, an import, and a drop hide it.
    @Test func theEmptyCueFollowsTheDragAndThePalette() async throws {
        let (model, _, window) = try await openEmpty()
        let host = try #require(try await host(in: window) as? EmptyDropView)
        let voice = try wav("Voice.wav")
        #expect(host.cue.isHidden, "no cue before a drag")

        let one = fileDrag([voice])
        #expect(host.draggingEntered(one) == .copy)
        #expect(!host.cue.isHidden && host.cue.borderWidth == 1, "the cue of one file")
        #expect(host.cueLabel.string as? String == L10n.dropNewTrack.text, "the label of one file")
        host.draggingExited(one)
        #expect(host.cue.isHidden, "an exit hides the cue")

        let three = fileDrag([voice, try wav("b.wav"), try wav("c.wav")])
        #expect(host.draggingEntered(three) == .copy)
        #expect(host.cueLabel.string as? String == L10n.dropNewTracks.format(3), "the label of three files")
        host.draggingEnded(three)

        host.increasesContrast = true
        _ = host.draggingEntered(fileDrag([voice]))
        #expect(host.cue.borderWidth == 2, "2 pt with Increase Contrast")
        host.increasesContrast = false

        for (name, label) in [
            (NSAppearance.Name.aqua, LanePalette.light.label), (.darkAqua, LanePalette.dark(accent: 0).label),
        ] {
            host.appearance = NSAppearance(named: name)
            #expect(host.cueLabel.foregroundColor == cgColor(label), "the label color of \(name.rawValue)")
        }

        let text = folder.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        let refused = fileDrag([text])
        #expect(host.draggingEntered(refused) == [])
        #expect(host.cue.isHidden, "a refused drag shows no cue")

        let busy = fileDrag([voice])
        #expect(host.draggingEntered(busy) == .copy && !host.cue.isHidden)
        model.importJob = ImportJob()
        #expect(host.draggingUpdated(busy) == [] && host.cue.isHidden, "an import hides the cue")
        model.importJob = nil

        let drop = fileDrag([voice])
        _ = host.draggingEntered(drop)
        #expect(host.performDragOperation(drop))
        #expect(host.cue.isHidden, "a drop hides the cue")
        await until("the import ends") { model.importJob == nil }
        await model.close()
    }

    /// An app in Dark Mode makes the host dark before it enters its dark window, so the move
    /// gives no appearance change. The cue still has the dark palette at its first draw. The host
    /// has its own dark appearance and the light palette, as before any pick (`LaneAppearanceTests`),
    /// so the test does not depend on the appearance of the Mac.
    @Test func aHostThatEntersADarkWindowHasTheDarkCue() async throws {
        let (model, _, _) = try await openEmpty()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = EmptyDropView(model: model, content: Text("empty"))
        host.appearance = NSAppearance(named: .darkAqua)
        host.palette = .light
        let app = NSApp.effectiveAppearance.name.rawValue
        try #require(host.effectiveAppearance.name == .darkAqua, "the host is dark before the window")
        try #require(
            host.cueLabel.foregroundColor == cgColor(LanePalette.light.label), "the light label before the move")

        window.contentView?.addSubview(host)

        try #require(host.effectiveAppearance.name == .darkAqua, "the host is dark in the window")
        #expect(
            host.cueLabel.foregroundColor == cgColor(LanePalette.dark(accent: 0).label), "the dark label, app \(app)")
        window.close()
        await model.close()
    }
}
