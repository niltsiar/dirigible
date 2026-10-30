import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// Select and cut by words in the Transcript pane (run transcript-1, landing 2, criteria P7 to
/// P10, P16). Track t1 "Host" has "Hello there" at 1 s, "Second part" at 6 s, and "Third" at 11 s.
/// Track t2 "Guest" has a clip and no transcript, so a range on all tracks differs from a range on
/// the track of the words. Both clips are 20 s long.
@Suite(.serialized) @MainActor struct TranscriptSelectionTests {
    let base: TranscriptPaneTests
    var app: AppDelegate { base.app }

    init() throws { base = try TranscriptPaneTests() }

    static let tracks: Set<TrackID> = ["t1", "t2"]

    /// A range on all tracks.
    static func range(_ start: Frames, _ end: Frames) -> Selection {
        .range(Marks(inPoint: start, outPoint: end, tracks: tracks))
    }

    static let hostWords: [(Double, Double, String)] = [
        (1, 1.5, "Hello"), (1.5, 2, "there"), (6, 6.5, "Second"), (6.5, 7, "part"), (11, 11.5, "Third"),
    ]

    /// The package, with `host` on t1, and `guest` on t2 when it has words.
    func package(host: [(Double, Double, String)] = hostWords, guest: [(Double, Double, String)] = [])
        async throws -> URL
    {
        let url = base.folder.url.appending(path: "s.dirigible")
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            for (track, name, file) in [("t1", "Host", "f1"), ("t2", "Guest", "f2")] {
                try session.addFile(AudioFile(id: FileID(file), path: file + ".wav", layout: .mono, length: 960_000))
                try session.addTrack(TrackID(track), name: name, layout: .mono)
                try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: TrackID(track))
                try session.place(
                    Clip(id: ClipID(file), file: FileID(file), start: 0, offset: 0, length: 960_000), on: TrackID(track)
                )
            }
            for (words, name, track) in [(host, "Host", TrackID("t1")), (guest, "Guest", TrackID("t2"))]
            where !words.isEmpty {
                try session.importTranscript(try Self.transcript(words), name: name, track: track, at: 0)
            }
            try session.write(to: url)
        }.value
        return url
    }

    /// A Whisper JSON transcript of `words`: the start, the end, and the text of each word.
    nonisolated static func transcript(_ words: [(Double, Double, String)]) throws -> TranscriptFile {
        let json =
            #"{"words":["#
            + words.map { #"{"word":" \#($0.2)","start":\#($0.0),"end":\#($0.1)}"# }.joined(separator: ",") + "]}"
        return try TranscriptFile(data: Data(json.utf8))
    }

    /// The window with the Transcript tab shown and the focus in the pane.
    func shown(guest: [(Double, Double, String)] = []) async throws -> (
        SessionWindow, Studio, NSWindow, TimelineScrollView, TranscriptTextView
    ) {
        let (model, studio, window, view) = try await base.open(try await package(guest: guest))
        model.showTranscript()
        return (model, studio, window, view, try await base.waitForPane(window))
    }

    /// The storage range from the start of the unit `first` to the end of the unit `last`.
    func range(_ first: String, _ last: String? = nil, in pane: TranscriptTextView) throws -> NSRange {
        let text = try #require(pane.shown?.text)
        func unit(_ word: String) throws -> TranscriptText.Unit {
            try #require(text.units.first { (text.string as NSString).substring(with: NSRange($0.text)) == word })
        }
        let (start, end) = (try unit(first).text.lowerBound, try unit(last ?? first).text.upperBound)
        return NSRange(location: pane.noticeLength + start, length: end - start)
    }

    /// An arrow key with Shift: 123 Left, 124 Right, 125 Down, 126 Up.
    func shiftArrow(_ code: UInt16, in window: NSWindow) -> NSEvent {
        let character = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey][
            Int(code), default: NSUpArrowFunctionKey]
        let text = String(Character(UnicodeScalar(UInt16(character))!))
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .numericPad, .function], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)!
    }

    /// The end of the last clip of each track.
    func ends(_ session: Session) -> [Frames] { session.tracks.map { $0.clips.map(\.end).max() ?? .zero } }

    /// The storage ranges that have a background rendering attribute (the tint).
    func tinted(_ pane: TranscriptTextView) -> [NSRange] {
        guard let manager = pane.textLayoutManager, let content = manager.textContentManager else { return [] }
        let start = manager.documentRange.location
        var found: [NSRange] = []
        manager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
            if attributes[.backgroundColor] != nil {
                let location = content.offset(from: start, to: range.location)
                found.append(
                    NSRange(location: location, length: content.offset(from: range.location, to: range.endLocation)))
            }
            return true
        }
        return found
    }

    func settle(_ window: NSWindow) { window.contentView?.layoutSubtreeIfNeeded() }

    // MARK: P8

    /// P8, P7: with the focus in the pane, Shift-Right and Shift-Left move the end of the selection
    /// by one unit, and Shift-Down and Shift-Up by one sentence; each key move says the word count.
    /// In the lanes they stay Next Clip and Previous Clip, and an inspector field gets the key.
    @Test func shiftArrowsByFocus() async throws {
        let (model, studio, window, view, pane) = try await shown()
        await base.seek(studio, to: 100_000)
        let hello = try range("Hello", in: pane)
        let helloThere = try range("Hello", "there", in: pane)
        pane.setSelectedRange(NSRange(location: hello.location, length: 0))
        func send(_ command: TransportCommand, _ code: UInt16) async {
            app.transport(command, event: shiftArrow(code, in: window), in: window)
            await model.settleTransport()
        }

        await send(.seek(.nextClip), 124)
        #expect(pane.selectedRange() == hello)
        #expect(model.timeline.selection == Self.range(48_000, 72_000))
        #expect(pane.announced == 1, "VoiceOver says one word")
        await send(.seek(.nextClip), 124)
        #expect(pane.selectedRange() == helloThere)
        #expect(model.timeline.selection == Self.range(48_000, 96_000))
        #expect(pane.announced == 2)
        await send(.seek(.previousClip), 123)
        #expect(pane.selectedRange() == hello)
        await send(.seek(.previousClip), 123)
        #expect(pane.selectedRange().length == 0, "Shift-Left from one unit leaves no unit")
        #expect(model.timeline.selection == .none, "and clears the range")
        #expect(studio.playhead == 100_000, "no Previous Clip or Next Clip in the pane")

        pane.keyDown(with: shiftArrow(125, in: window))
        #expect(pane.selectedRange() == helloThere, "Shift-Down: to the paragraph end")
        #expect(model.timeline.selection == Self.range(48_000, 96_000))
        pane.keyDown(with: shiftArrow(126, in: window))
        #expect(pane.selectedRange().length == 0, "Shift-Up: back to the start")

        // The lanes: Next Clip, and the pane selection and the range stay.
        pane.setSelectedRange(hello)
        #expect(window.makeFirstResponder(view.lanes))
        await send(.seek(.nextClip), 124)
        #expect(studio.playhead == 960_000, "Next Clip goes to the clip end")
        #expect(pane.selectedRange() == hello)
        #expect(model.timeline.selection == Self.range(48_000, 72_000))

        // An inspector field: the field editor gets the key.
        model.showEpisodeInfo()
        try await base.type("Ab", intoTitleOf: window, model)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        await send(.seek(.previousClip), 123)
        #expect(editor.selectedRange() == NSRange(location: 1, length: 1), "Shift-Left selects in the field")
        #expect(studio.playhead == 960_000)
        #expect(model.timeline.selection == Self.range(48_000, 72_000))
        await model.close()
    }

    // MARK: P9

    /// P9: a pane selection snaps to whole units in one range and writes the timeline range on all
    /// tracks. A click caret writes nothing; header text only clears the range; a range from the
    /// lanes clears the pane selection.
    @Test func paneSetsTheRange() async throws {
        let (model, _, window, _, pane) = try await shown()
        let hello = try range("Hello", in: pane)
        let there = try range("there", in: pane)
        let second = try range("Second", in: pane)

        pane.setSelectedRange(NSRange(location: hello.location + 2, length: there.location + 2 - hello.location - 2))
        #expect(pane.selectedRange() == (try range("Hello", "there", in: pane)), "whole units")
        #expect(model.timeline.selection == Self.range(48_000, 96_000), "all tracks")

        pane.setSelectedRange(NSRange(location: second.location + 1, length: 0))
        #expect(model.timeline.selection == Self.range(48_000, 96_000), "a click caret writes nothing")

        let header = try #require(pane.shown?.text.headers.dropFirst().first).range
        pane.setSelectedRange(NSRange(location: pane.noticeLength + header.lowerBound, length: header.count))
        #expect(pane.selectedRange().length == 0, "header text selects no unit")
        #expect(model.timeline.selection == .none, "and clears the range")

        pane.setSelectedRange(NSRange(location: there.location + 1, length: second.location + 1 - there.location - 1))
        #expect(pane.selectedRange() == (try range("there", "Second", in: pane)), "one range over a header")
        #expect(model.timeline.selection == Self.range(72_000, 312_000))

        model.timeline.selection = .range(Marks(inPoint: 528_000, outPoint: 552_000, tracks: ["t1"]))
        await until("a lanes range clears the pane selection") {
            settle(window)
            return pane.selectedRange().length == 0
        }
        #expect(model.timeline.selection == .range(Marks(inPoint: 528_000, outPoint: 552_000, tracks: ["t1"])))
        await model.close()
    }

    /// P9: a timeline range tints each unit of a range track whose midpoint is inside it, as a
    /// rendering attribute. The tint does not change the pane selection.
    @Test func rangeTintsTheWords() async throws {
        let (model, _, window, _, pane) = try await shown()
        let secondPart = try range("Second", "part", in: pane)
        let second = try range("Second", in: pane)
        let caret = NSRange(location: second.location, length: 0)
        pane.setSelectedRange(caret)

        // "part" is 312 000 to 336 000: its midpoint is 324 000.
        model.timeline.selection = .range(Marks(inPoint: 280_000, outPoint: 324_001, tracks: ["t1"]))
        await until("the tint shows Second part") {
            settle(window)
            return tinted(pane) == [secondPart]
        }
        #expect(pane.selectedRange() == caret, "the tint does not select")

        model.timeline.selection = .range(Marks(inPoint: 280_000, outPoint: 324_000, tracks: ["t1"]))
        await until("a midpoint at the range end is out") {
            settle(window)
            return tinted(pane) == [second]
        }
        model.timeline.selection = .range(Marks(inPoint: 280_000, outPoint: 324_001, tracks: ["t2"]))
        await until("a range of the other track tints nothing") {
            settle(window)
            return tinted(pane).isEmpty
        }
        await model.close()
    }

    // MARK: P10, P16

    /// P10: Delete with the focus in the pane ripples the pane range out of all tracks, in one
    /// undo step.
    @Test func deleteRipplesInThePane() async throws {
        let (model, studio, window, _, pane) = try await shown()
        let before = studio.session
        pane.setSelectedRange(try range("Second", "part", in: pane))

        app.timeline(.delete, event: key(.keyDown, "\u{8}", code: 51, in: window), in: window)

        #expect(ends(studio.session) == [912_000, 912_000], "48 000 frames out of each track")
        #expect(studio.session.words().map(\.text) == ["Hello", "there", "Third"])
        try studio.undo()
        #expect(studio.session == before, "one undo step")
        await model.close()
    }

    /// P10, P16: Cut with the focus in the pane puts the range on the app clipboard, as a lanes Cut
    /// of the same range, writes the words to the pasteboard, and ripples. A refused Cut writes
    /// nothing.
    @Test func cutCopiesAndRipples() async throws {
        let (model, studio, window, _, pane) = try await shown()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        pane.pasteboard = board
        let before = studio.session
        let scope = try #require(
            Marks(inPoint: 288_000, outPoint: 336_000, tracks: Self.tracks).rippleScope(selectedOnly: false, in: before)
        )
        let lanesCut = try before.excerpt(of: scope.range, on: scope.selected)
        pane.setSelectedRange(try range("Second", "part", in: pane))

        app.timeline(.cut, event: key(.keyDown, "x", code: 7, in: window), in: window)

        #expect(app.clipboard?.excerpt == lanesCut)
        #expect(board.string(forType: .string) == "Second part")
        #expect(ends(studio.session) == [912_000, 912_000])

        let (count, clipboard, session) = (board.changeCount, app.clipboard, studio.session)
        app.timeline(.cut, event: key(.keyDown, "x", code: 7, in: window), in: window)
        #expect(board.changeCount == count, "no range: no text")
        #expect(app.clipboard == clipboard)
        #expect(studio.session == session)
        await model.close()
    }
}
