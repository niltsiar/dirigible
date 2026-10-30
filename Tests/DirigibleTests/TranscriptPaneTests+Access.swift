import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// VoiceOver and the Headings rotor of the pane (run transcript-1, landing 2, criterion P7).
extension TranscriptPaneTests {
    /// The ranges of the lines of the pane text that are paragraph headers ("<track> · <time>").
    func headerRanges(_ pane: TranscriptTextView) -> [NSRange] {
        let text = pane.string as NSString
        var found: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) {
            line, range, _, _ in
            if line?.contains(" · ") == true { found.append(range) }
        }
        return found
    }

    /// The target ranges that the Headings rotor gives when it goes from `start` in `direction`.
    func rotorRanges(
        _ pane: TranscriptTextView, direction: NSAccessibilityCustomRotor.SearchDirection
    ) throws -> [NSRange] {
        let rotor = try #require(pane.accessibilityCustomRotors().first { $0.type == .heading })
        let delegate = try #require(rotor.itemSearchDelegate)
        var found: [NSRange] = []
        var current: NSAccessibilityCustomRotor.ItemResult?
        while found.count < 20 {
            let parameters = NSAccessibilityCustomRotor.SearchParameters()
            parameters.currentItem = current
            parameters.searchDirection = direction
            guard let item = delegate.rotor(rotor, resultFor: parameters) else { break }
            #expect(item.targetElement === pane)
            found.append(item.targetRange)
            current = item
        }
        return found
    }

    /// Track t2 says "yeah" inside the first paragraph of t1: a backchannel line, not a header.
    func addBackchannel(_ studio: Studio) throws {
        let json = #"{"words":[{"word":" yeah","start":1.2,"end":1.4}]}"#
        let file = try TranscriptFile(data: Data(json.utf8))
        try studio.edit(ripple: false) { s throws(SessionError) in
            try s.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 960_000))
            try s.addTrack("t2", name: "Guest", layout: .mono)
            try s.place(Clip(id: "B", file: "f2", start: 0, offset: 0, length: 960_000), on: "t2")
            try s.importTranscript(file, name: "Guest", track: "t2", at: 0)
        }
    }

    /// P7: the Headings rotor has one item for each paragraph header, in text order, with the range
    /// of the header, going forward and going back. A backchannel line is not an item.
    @Test func headersAreRotorHeadings() async throws {
        let (model, studio, window, _) = try await open(try await package(name: "rotor"))
        model.showTranscript()
        var pane = try await waitForPane(window)
        let headers = headerRanges(pane)
        #expect(headers.count == 3, "three paragraphs: \(headers)")
        #expect(try rotorRanges(pane, direction: .next) == headers)
        #expect(try rotorRanges(pane, direction: .previous) == headers.reversed())

        try addBackchannel(studio)
        await until("the pane shows the backchannel line") { self.pane(window)?.string.contains("Guest") == true }
        pane = try await waitForPane(window)
        #expect(pane.shown?.text.backchannels.count == 1, "the text has one backchannel line")
        #expect(headerRanges(pane).count == 3, "the line is no header")
        #expect(try rotorRanges(pane, direction: .next) == headerRanges(pane), "the line is no rotor item")
        await model.close()
    }

    /// P7: the text has the label "Transcript", and the action Go to Word puts the playhead at the
    /// first frame of the unit at the insertion point, or of the first unit under a header.
    @Test func accessibility() async throws {
        let (model, studio, window, _) = try await open(try await package(name: "access"))
        model.showTranscript()
        let pane = try await waitForPane(window)
        #expect(pane.accessibilityLabel() == L10n.inspectorTabTranscript.text)
        let action = try #require(pane.accessibilityCustomActions()?.first { $0.name == L10n.transcriptGoToWord.text })
        let text = pane.string as NSString
        let (second, hello) = (text.range(of: "Second").location, text.range(of: "Hello").location)

        pane.setSelectedRange(NSRange(location: second + 2, length: 0))
        #expect(action.handler?() == true)
        await until("the playhead goes to Second") { studio.playhead == Self.second }

        pane.setSelectedRange(NSRange(location: hello + "Hello".count, length: 0))
        #expect(action.handler?() == true, "the insertion point at the end of a word is in the word")
        await until("the playhead goes to Hello") { studio.playhead == 48_000 }

        pane.setSelectedRange(NSRange(location: headerRanges(pane)[2].location + 1, length: 0))
        #expect(action.handler?() == true, "a header goes to its first unit")
        await until("the playhead goes to Third") { studio.playhead == 528_000 }
        await model.close()
    }
}
