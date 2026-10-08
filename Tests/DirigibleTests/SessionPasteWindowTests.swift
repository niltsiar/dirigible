import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Paste between session windows (decision 0042, run 13b). Each package has tracks t1 to t3 (T1 to
/// T3) with clips of its own file f1 (10 s), so both packages use the same file ID and track IDs.
@Suite(.serialized) @MainActor struct SessionPasteWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func package(_ name: String, noise: Bool = false) async throws -> URL {
        let folder = self.folder.url.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await timelinePackage(in: folder, tracks: 3, seconds: 10, audio: true, noise: noise)
    }

    func open(_ url: URL) async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window, view) = try await openLanes(app, url)
        studio.environment.playerOutput = .offline
        #expect(window.makeFirstResponder(view.lanes))
        return (model, studio, window)
    }

    func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: clipsFolderName).path)) ?? [])
            .sorted()
    }

    func pasteAndWait(_ model: SessionWindow, _ command: TimelineCommand = .paste) async {
        model.run(command)
        await until("the paste ends") { model.importJob == nil }
    }

    /// C4: the clipboard is one per app and outlives the source window; the paste copies f1 as
    /// "f1 2" onto the selected track at the playhead and selects the pasted range.
    @Test func theClipboardOutlivesTheSourceWindow() async throws {
        let (a, b) = (try await package("a"), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        await first.close()
        let (second, studio, window) = try await open(b)
        await studio.perform(.seek(.frame(96_000)))
        second.timeline.selection = .range(Marks(tracks: ["t2"]))

        await pasteAndWait(second)

        #expect(second.clipboard != nil && second.alert == nil)
        #expect(names(b) == ["f1 2.wav", "f1.wav"], "the copy of a's f1")
        let pasted = studio.session.clip("c1@96000")
        #expect(pasted?.track == "t2" && pasted?.clip.file == "f1 2" && pasted?.clip.length == 48_000)
        #expect(second.timeline.selection == .range(Marks(inPoint: 96_000, outPoint: 144_000, tracks: ["t2"])))
        #expect(studio.playhead == 96_000 && window.firstResponder === second.timelineView?.lanes, "C20")
        await second.close()
    }

    /// Code gate 1 item 4: a Copy that copies nothing keeps the clipboard of the other package, so
    /// a Paste in B still copies the file of A.
    @Test func anEmptyCopyKeepsTheClipboardOfAnotherPackage() async throws {
        let (a, b) = (try await package("a", noise: true), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        let (second, studio, _) = try await open(b)
        second.timeline.selection = .none
        second.run(.copy)
        second.timeline.selection = .range(Marks(tracks: ["t2"]))

        await pasteAndWait(second)

        #expect(names(b) == ["f1 2.wav", "f1.wav"], "the paste copied the file of a")
        #expect(studio.session.clip("c1@480000")?.clip.file == "f1 2")
        let copied = FileManager.default.contents(atPath: b.appending(path: "Clips/f1 2.wav").path)
        #expect(copied != nil && copied == FileManager.default.contents(atPath: a.appending(path: "Clips/f1.wav").path))
        await first.close()
        await second.close()
    }

    /// Code gate 2 item 2: a range paste at another rate selects the whole scaled range, also when
    /// its clips end before the range end.
    @Test func aRangePasteAtAnotherRateSelectsTheScaledRange() async throws {
        let a = folder.url.appending(path: "slow/slow.dirigible")
        try await Task.detached {
            try FileManager.default.createDirectory(
                at: a.appending(path: clipsFolderName), withIntermediateDirectories: true)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            let writer = try ClipWriter(url: a.appending(path: "Clips/s.wav"), file: "s.wav", format: format)
            try writer.write(buffer)
            try writer.close()
            var session = Session(sampleRate: 44_100)
            try session.addFile(AudioFile(id: "s", path: "s.wav", layout: .mono, length: 44_100))
            try session.addTrack("t1", name: "Slow", layout: .mono)
            try session.place(Clip(id: "half", file: "s", start: 0, offset: 0, length: 22_050), on: "t1")
            try session.write(to: a)
        }.value
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 44_100, tracks: ["t1"])
        first.run(.copy)
        let (second, studio, _) = try await open(try await package("b"))
        await studio.perform(.seek(.frame(0)))
        second.timeline.selection = .range(Marks(tracks: ["t2"]))

        await pasteAndWait(second)

        #expect(studio.session.clip("half@0")?.clip.length == 24_000, "the clip scales to 0.5 s at 48 kHz")
        #expect(second.timeline.selection == .range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t2"])))
        await first.close()
        await second.close()
    }

    /// C3: a paste in the package of the copy copies nothing, also in a new window of it.
    @Test func aPasteInTheSamePackageCopiesNoFile() async throws {
        let a = try await package("a")
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        await first.close()
        let (again, studio, _) = try await open(a)
        await studio.perform(.seek(.frame(0)))
        again.timeline.selection = .range(Marks(tracks: ["t3"]))

        again.run(.paste)

        #expect(again.importJob == nil, "no run: the paste acted at once")
        #expect(names(a) == ["f1.wav"] && studio.session.clip("c1@0")?.track == "t3" && studio.canUndo)
        await again.close()
    }

    /// C18 a, d, f: with no selected track, another package gets new tracks named after the
    /// source tracks, also when both packages have the tracks t1 to t3; the same package uses the
    /// source tracks.
    @Test func aCrossPasteWithNoSelectedTrackMakesTracks() async throws {
        let (a, b) = (try await package("a"), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1", "t2"])
        first.run(.copy)
        let (second, studio, _) = try await open(b)
        second.timeline.selection = .none

        await pasteAndWait(second)

        #expect(studio.session.tracks.map(\.name) == ["T1", "T2", "T3", "T1", "T2"], "two new tracks")
        #expect(studio.session.tracks.suffix(2).allSatisfy { !$0.clips.isEmpty })
        try studio.undo()
        #expect(studio.session.tracks.count == 3 && !studio.canUndo, "one undo step for the tracks and clips")
        first.timeline.selection = .none
        first.run(.paste)
        #expect(try #require(first.studio).session.tracks.count == 3, "the same package: the source tracks")
        await first.close()
        await second.close()
    }

    /// C5 a, b: a renamed source with its window open pastes; a deleted one shows the alert.
    @Test func aMovedSourcePastesAndADeletedSourceRefuses() async throws {
        let (a, b) = (try await package("a"), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        let moved = a.deletingLastPathComponent().appending(path: "moved.dirigible")
        try FileManager.default.moveItem(at: a, to: moved)
        let (second, studio, _) = try await open(b)
        second.timeline.selection = .range(Marks(tracks: ["t1"]))

        await pasteAndWait(second)
        #expect(studio.session.files["f1 2"] != nil && second.alert == nil, "the open studio gives the new path")

        await first.close()
        try FileManager.default.removeItem(at: moved)
        let before = studio.session
        await pasteAndWait(second)
        #expect(second.alert == .error(.paste(.sourceMissing(file: "timeline.dirigible"), source: "timeline")))
        #expect(studio.session == before && second.clipboard != nil, "nothing changed; the clipboard stays")
        await second.close()
    }

    /// C3g: two open packages with no identity: the paste uses the path of the copy.
    @Test func aNilOriginNeverMatchesAnotherOpenPackage() async throws {
        let (x, y, z) = (try await package("x", noise: true), try await package("y"), try await package("z"))
        for url in [x, y] {
            try? FileManager.default.removeItem(at: url.appending(path: ".lock"))
            chmod(url.path, 0o555)
        }
        defer { for url in [x, y] { chmod(url.path, 0o755) } }
        let (first, xs, _) = try await open(x)
        let (other, ys, _) = try await open(y)
        #expect(xs.identity == nil && ys.identity == nil)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        #expect(app.studio(of: app.clipboard?.origin) == nil, "no studio matches a nil identity")
        let (target, _, _) = try await open(z)
        target.timeline.selection = .range(Marks(tracks: ["t1"]))

        await pasteAndWait(target)

        let copied = FileManager.default.contents(atPath: z.appending(path: "Clips/f1 2.wav").path)
        #expect(copied != nil && copied == FileManager.default.contents(atPath: x.appending(path: "Clips/f1.wav").path))
        for model in [first, other, target] { await model.close() }
    }

    /// C8: a copy that runs past 0.5 s shows the banner of the paste; Cancel ends it with no
    /// change and no alert. A clone under 0.5 s shows no banner and no announcement.
    @Test func cancelAndTheBannerOfAPaste() async throws {
        let (a, b) = (try await package("a"), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        let (second, studio, _) = try await open(b)
        var heard: [String] = []
        second.chrome?.announce = { text, _ in heard.append(text) }
        second.timeline.selection = .range(Marks(tracks: ["t1"]))
        // The banner wait ends only when the test says so, so a loaded suite cannot pass 0.5 s
        // on the wall clock before the asserts; the slow steps stand for that load.
        let release = LockedFlag()
        defer { release.value = true }
        second.bannerWait = { while !release.value { try? await Task.sleep(for: .milliseconds(10)) } }
        studio.environment.importStep = { Thread.sleep(forTimeInterval: 0.3) }

        await pasteAndWait(second)
        #expect(heard.isEmpty, "a clone shows no banner and is not announced")
        try studio.undo()

        let hold = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        let before = studio.session
        second.run(.paste)
        await until("the paste holds") { entered.value }
        #expect(second.importJob?.visible == false, "no banner before the wait ends")
        #expect(heard.isEmpty, "no announcement before the wait ends")
        release.value = true
        await until("the banner shows after the wait") { second.importJob?.visible == true }
        #expect(studio.importRun?.kind == .paste && heard == [L10n.pasteBanner.format("timeline")])
        second.cancelImport()
        hold.signal()
        await until("the paste ends") { second.importJob == nil }

        #expect(studio.session == before && second.alert == nil && second.clipboard != nil)
        #expect(names(b) == ["f1 2.wav", "f1.wav"], "the WAV of the undone paste stays; no new file")
        await first.close()
        await second.close()
    }

    /// C9: Undo keeps the WAV, and Redo needs no copy.
    @Test func undoKeepsTheCopiedFileAndRedoNeedsNoCopy() async throws {
        let (a, b) = (try await package("a"), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        await first.close()
        let (second, studio, _) = try await open(b)
        second.timeline.selection = .range(Marks(tracks: ["t1"]))
        await pasteAndWait(second)
        let pasted = studio.session

        second.undo()
        #expect(studio.session.files["f1 2"] == nil && names(b) == ["f1 2.wav", "f1.wav"])
        second.redo()
        #expect(studio.session == pasted && names(b) == ["f1 2.wav", "f1.wav"])
        await second.close()
    }

    /// C13: Insert from another package moves all tracks right and pastes, as one undo entry.
    @Test func insertAcrossPackagesIsOneUndoEntry() async throws {
        let (a, b) = (try await package("a"), try await package("b"))
        let (first, _, _) = try await open(a)
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        await first.close()
        let (second, studio, _) = try await open(b)
        await studio.perform(.seek(.frame(0)))
        second.timeline.selection = .range(Marks(tracks: ["t2"]))
        let before = studio.session

        await pasteAndWait(second, .insert)

        #expect(studio.session.clip("c3")?.clip.start == 48_000, "t3 moves right by the excerpt length")
        #expect(studio.session.clip("c1@0")?.clip.file == "f1 2")
        second.undo()
        #expect(studio.session == before && !studio.canUndo)
        await second.close()
    }

    /// C16: each paste error has its key and the name of the source session.
    @Test func eachPasteErrorShowsItsKey() {
        let cases: [(PasteError, String)] = [
            (.sourceMissing(file: "f1.wav"), L10n.errorPasteMissing.format("S")),
            (.sourceChanged(file: "f1.wav"), L10n.errorPasteChanged.format("S")),
            (.notDownloaded(file: "f1.wav"), L10n.errorImportNotDownloaded.format("f1.wav")),
            (.space(needed: 2, free: 1), L10n.errorPasteSpace.format("S")),
            (.write(file: "f1.wav", errno: ENOSPC), L10n.errorPasteSpace.format("S")),
            (.write(file: "f1.wav", errno: EIO), L10n.errorPasteCopy.format("S", Int(EIO))),
            (.convert(file: "f1.wav", errno: EIO), L10n.errorPasteConvert.format("S", Int(EIO))),
        ]
        for (error, text) in cases {
            #expect(L10n.message(for: .paste(error, source: "S")) == text, "\(error)")
        }
        #expect(L10n.message(for: .pasteYielded(source: "S")) == L10n.errorPasteYielded.format("S"))
    }

    /// C19: Paste stays on (0018 K1); with no clipboard, it does nothing and shows nothing.
    @Test func pasteKeepsK1WithNoClipboard() async throws {
        let (model, studio, _) = try await open(try await package("a"))
        app.clipboard = nil
        let before = studio.session

        model.run(.paste)

        #expect(model.isOn(.paste) && studio.session == before && model.alert == nil && model.importJob == nil)
        await model.close()
    }
}
