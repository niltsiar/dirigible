import AVFoundation
import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Split Stereo to Mono in the session window (decision 0053).
@Suite(.serialized) @MainActor struct SplitStereoWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The mono tracks t1 and t2 (clips c1 and c2 of 2 s of `f1`, from 0) and the stereo track t3
    /// "Voice" with clip s1 of 2 s of the WAV `st`. The writes run off the main actor.
    @concurrent nonisolated static func stereoPackage(in folder: URL) async throws -> URL {
        let url = try await timelinePackage(in: folder, tracks: 2, seconds: 2, audio: true)
        var session = try Session(contentsOf: url)
        try session.addFile(AudioFile(id: "st", path: "st.wav", layout: .stereo, length: 96_000))
        try session.addTrack("t3", name: "Voice", layout: .stereo)
        try session.place(Clip(id: "s1", file: "st", start: 0, offset: 0, length: 96_000), on: "t3")
        try session.write(to: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(
            forWriting: url.appending(path: "\(clipsFolderName)/st.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for frame in 0..<96_000 {
            buffer.floatChannelData![0][frame] = Float(0.1 * sin(Double(frame) / 8))
            buffer.floatChannelData![1][frame] = Float(0.1 * sin(Double(frame) / 5))
        }
        try file.write(from: buffer)
        return url
    }

    func open() async throws -> (SessionWindow, Studio, NSWindow) {
        let (model, studio, window, _) = try await openLanes(app, try await Self.stereoPackage(in: folder.url))
        return (model, studio, window)
    }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    /// C16: the item is on with a stereo clip in the selection and an idle studio. Control: only mono
    /// clips, a range that cuts the stereo clip, a take, a pending take, and an import run turn it off. A name field
    /// in focus does not stop the key.
    @Test func menuStateForEachStartState() async throws {
        let (model, studio, window) = try await open()
        let whole = Marks(inPoint: 0, outPoint: 96_000, tracks: ["t3"])
        let cases: [(String, Selection, Bool)] = [
            ("no selection", .none, false), ("a click on a stereo clip", set("s1"), true),
            ("a mono clip", set("c1"), false), ("a mono and a stereo clip", set("c1", "s1"), true),
            ("a range that holds the stereo clip whole", .range(whole), true),
            ("a range that cuts it", .range(Marks(inPoint: 100, outPoint: 96_000, tracks: ["t3"])), false),
            ("a range on mono tracks", .range(Marks(inPoint: 0, outPoint: 96_000, tracks: ["t1", "t2"])), false),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(.splitStereo) == on, "\(name)")
        }

        model.timeline.selection = set("s1")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.splitStereo), "a take")
        studio.transport = .importing(ImportRun(name: "x", kind: .file, flags: ImportFlags()))
        #expect(!model.isOn(.splitStereo), "an import run")
        studio.transport = .idle
        #expect(model.isOn(.splitStereo), "after the run")

        let field = try await focusName(in: window)
        field.string = "Typed"
        app.timeline(.splitStereo, event: try cgKey(2, [.maskCommand, .maskShift]), in: window)
        // All windows of the test process share one SwiftUI field editor, and a field of a parallel
        // suite can take it during a wait. So read the text with no await after the key.
        let text = field.string
        await until("the split ends") { model.importJob == nil }
        #expect(studio.session.tracks.count == 5, "the key splits with a name field in focus")
        #expect(text == "Typed", "the field text stays")
        await model.close()

        // A take that waits for its finalize makes the split refuse with `.busy`: the item is off,
        // and the lane menu shows it dimmed.
        let pending = folder.url.appending(path: "pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        let url = try await Self.stereoPackage(in: pending)
        var session = try Session(contentsOf: url)
        try session.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t1"]))
        try session.write(to: url)
        FileManager.default.createFile(atPath: url.appending(path: "recovery-attempt").path, contents: nil)
        let (held, heldStudio) = try await timelineModel(url, app: app)
        let (heldWindow, view) = standaloneLanes(held, heldStudio)
        try #require(heldStudio.pendingTake != nil)
        held.timeline.selection = set("s1")
        #expect(!held.isOn(.splitStereo), "a pending take")
        let menu = try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: 120, y: 210), in: view)))
        let item = menu.items.first { $0.title == L10n.menuToolsSplitStereo.text }
        #expect(item?.isEnabled == false, "the lane menu item dims under a pending take")
        heldWindow.close()
        await held.close()
    }
    /// C17: after a split, the selection is the new clips, on tracks "Voice <left>" and "Voice
    /// <right>" with the suffixes of the UI language. Under `swift test` a suffix is its key, which
    /// a fixed "L" and "R" in the handler does not match. The split is one undo step.
    @Test func selectionAfterSplit() async throws {
        let (model, studio, _) = try await open()
        let before = studio.session
        model.timeline.selection = set("s1")

        model.run(.splitStereo)
        await until("the split ends") { model.importJob == nil }

        let names = ["Voice \(L10n.splitSuffixLeft.text)", "Voice \(L10n.splitSuffixRight.text)"]
        #expect(studio.session.tracks.map(\.name) == before.tracks.map(\.name) + names)
        #expect(model.timeline.selection == set("s1 L", "s1 R"), "\(model.timeline.selection)")
        #expect(model.alert == nil)
        try studio.undo()
        #expect(studio.session == before, "one undo step")
        await model.close()
    }

    /// Decision 0053: a split that ends before the banner wait shows no banner and is not
    /// announced. A split that runs past the wait shows the banner, and VoiceOver reads its start
    /// and its end.
    @Test func theBannerShowsOnlyAfterTheWait() async throws {
        let (model, studio, _) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        // The banner wait ends only when the test says so, so a loaded suite cannot pass 0.5 s on
        // the wall clock before the asserts.
        let release = LockedFlag()
        defer { release.value = true }
        model.bannerWait = { while !release.value { try? await Task.sleep(for: .milliseconds(10)) } }
        model.timeline.selection = set("s1")

        model.run(.splitStereo)
        await until("the short split ends") { model.importJob == nil }
        #expect(heard.isEmpty, "a short split shows no banner and is not announced")
        try studio.undo()

        let hold = BlockHold()
        defer { hold.release() }
        studio.environment.importStep = { hold.step() }
        model.timeline.selection = set("s1")
        model.run(.splitStereo)
        await until("the split holds") { hold.held }
        #expect(model.importJob?.visible == false && heard.isEmpty, "no banner before the wait ends")
        release.value = true
        await until("the banner shows after the wait") { model.importJob?.visible == true }
        #expect(studio.importRun?.kind == .split && heard == [L10n.splitBanner.text])
        hold.release()
        await until("the split ends") { model.importJob == nil }
        #expect(heard == [L10n.splitBanner.text, L10n.splitDone.text] && model.alert == nil, "\(heard)")
        await model.close()
    }

    /// C20 and U22: the suffix pair of each UI language.
    @Test func eachLanguageHasItsSuffixPair() throws {
        let pairs = [
            "en": ["L", "R"], "es": ["I", "D"], "pt": ["E", "D"], "pt-PT": ["E", "D"], "de": ["L", "R"],
            "fr": ["G", "D"], "it": ["S", "D"], "nl": ["L", "R"],
        ]
        for language in AppLanguage.allCases.map(\.rawValue) {
            let pair = try #require(pairs[language], "\(language) has no suffix pair in this test")
            let table = try stringsTable(language)
            #expect(
                [table[L10n.splitSuffixLeft.rawValue], table[L10n.splitSuffixRight.rawValue]] == pair, "\(language)")
        }
    }

    /// C18: a right-click on a stereo clip outside the selection selects it and shows the item, on.
    /// Control: a right-click on a mono clip shows no item.
    @Test func rightClickOnAStereoClipShowsTheItem() async throws {
        let (model, studio) = try await timelineModel(try await Self.stereoPackage(in: folder.url), app: app)
        let (window, view) = standaloneLanes(model, studio)
        func shown(y: Double) throws -> NSMenuItem? {
            let menu = try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: 120, y: y), in: view)))
            return menu.items.first { $0.title == L10n.menuToolsSplitStereo.text }
        }

        #expect(try shown(y: 10) == nil, "a mono clip")
        let item = try #require(try shown(y: 210), "a stereo clip")
        #expect(item.isEnabled && model.timeline.selection == set("s1"), "the right-click selected the clip")
        window.close()
        await model.close()
    }

    /// C7 and C20: each split error shows its key, a full disk the space text, a transcript that
    /// did not load the text that names it, and another session refusal the session text. A
    /// transcript cut refusal shows the same transcript text.
    @Test func eachSplitErrorShowsItsKey() {
        let cases: [(SplitError, String)] = [
            (.space(needed: 2, free: 1), L10n.errorSplitSpace.text),
            (.write(file: "Clips/f1 L.wav", errno: ENOSPC), L10n.errorSplitSpace.text),
            (.write(file: "Clips/f1 L.wav", errno: EIO), L10n.errorSplitWrite.format(Int(EIO))),
            (.sourceUnreadable(file: "f1.wav", errno: EIO), L10n.errorSplitUnreadable.format("f1.wav", Int(EIO))),
            (.sourceMissing(file: "f1.wav"), L10n.errorSplitMissing.format("f1.wav")),
            (.session(.transcriptNotLoaded([TranscriptID(1)])), L10n.errorTranscriptUnloaded.text),
            (.session(.notStereo("c1")), L10n.errorSessionOther.text),
        ]
        for (error, text) in cases {
            #expect(L10n.message(for: .split(error)) == text, "\(error)")
        }
        #expect(L10n.message(for: .splitYielded) == L10n.errorSplitYielded.text)
        #expect(
            L10n.message(for: .session(.transcriptNotLoaded([TranscriptID(1)]))) == L10n.errorTranscriptUnloaded.text,
            "a transcript cut refusal")
    }
}
