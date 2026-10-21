import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// C11: Edit > Add Gain Point and Transport > Previous and Next Gain Point work on the clips of the
/// selected tracks at the playhead. Tracks t1 and t2 have a clip c1 and c2 of 2 s of file f1.
@Suite(.serialized) @MainActor struct GainPointKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    func model() async throws -> (SessionWindow, Studio) {
        try await timelineModel(try await timelinePackage(in: folder.url, tracks: 2, seconds: 2), app: app)
    }

    func points(_ studio: Studio, _ clip: ClipID = "c1") -> [Frames] {
        studio.session.clip(clip)?.clip.envelope.points.map(\.frame) ?? []
    }

    func beeps(_ model: SessionWindow) -> () -> Int {
        var count = 0
        model.beep = { count += 1 }
        return { count }
    }

    @Test func addsAPointOnEachSelectedTrackAtThePlayhead() async throws {
        let (model, studio) = try await model()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setEnvelope([0: Gain(dB: 0)!, 80_000: Gain(dB: -16)!], clip: "c1")
        }
        await studio.perform(.seek(.frame(40_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1", "t2"]))
        let revision = studio.sessionRevision

        model.run(.addGainPoint)

        #expect(points(studio) == [0, 40_000, 80_000], "c1 has the new point")
        #expect(studio.session.clip("c1")?.clip.envelope.gain(at: 40_000) == -8, "the point has the value there")
        #expect(points(studio, "c2") == [40_000], "c2 had none, and its point is 0 dB")
        #expect(studio.sessionRevision == revision + 1, "one edit")
        try studio.undo()
        #expect(points(studio) == [0, 80_000] && points(studio, "c2").isEmpty, "one undo entry")
        await model.close()
    }

    @Test func noSelectedTrackBeeps() async throws {
        let (model, studio) = try await model()
        let beeps = beeps(model)
        let before = studio.session
        model.timeline.selection = .none
        model.run(.addGainPoint)
        #expect(studio.session == before && beeps() == 1, "C11: a beep and no change")
        await model.close()
    }

    @Test func aPlayheadOutsideEveryClipBeeps() async throws {
        let (model, studio) = try await model()
        let beeps = beeps(model)
        let before = studio.session
        await studio.perform(.seek(.frame(96_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        model.run(.addGainPoint)
        #expect(studio.session == before && beeps() == 1, "C11: the clip ends at 96,000")
        await model.close()
    }

    @Test func aPlayheadOnAPointAddsNoSecondPoint() async throws {
        let (model, studio) = try await model()
        let beeps = beeps(model)
        await studio.perform(.seek(.frame(48_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        model.run(.addGainPoint)
        let revision = studio.sessionRevision
        model.run(.addGainPoint)
        #expect(points(studio) == [48_000] && studio.sessionRevision == revision && beeps() == 1)
        await model.close()
    }

    /// C11 (changed at the L2 code gate): with the focus in a text field, the field gets the key and
    /// its character, and the playhead and the envelope stay.
    @Test func aFocusedFieldGetsTheCharacterOfAGainPointKey() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 2))
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setEnvelope([60_000: Gain(dB: -3)!], clip: "c1")
        }
        await studio.perform(.seek(.frame(40_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        let editor = try await focusName(in: window)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let (text, session) = (editor.string, studio.session)

        for (command, typed, code, characters) in [
            (TimelineCommand.addGainPoint, "k", UInt16(40), "\u{2DA}"),
            (.previousGainPoint, ";", 41, "\u{2026}"), (.nextGainPoint, "'", 39, "\u{E6}"),
        ] {
            let event = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: typed, isARepeat: false, keyCode: code))
            app.timeline(command, event: event, in: window)
        }

        #expect(editor.string == text + "\u{2DA}\u{2026}\u{E6}", "the field got each character")
        #expect(studio.session == session && studio.playhead == 40_000, "the item did not act")
        await model.close()
    }

    /// C11: with no text field focused, the key goes to the item.
    @Test func withNoFieldFocusedTheKeyReachesTheItem() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 2))
        await studio.perform(.seek(.frame(40_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{2DA}",
                charactersIgnoringModifiers: "k",
                isARepeat: false, keyCode: 40))

        app.timeline(.addGainPoint, event: event, in: window)

        #expect(points(studio) == [40_000])
        await model.close()
    }

    @Test func previousAndNextMoveThePlayheadToAPoint() async throws {
        let (model, studio) = try await model()
        let beeps = beeps(model)
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setEnvelope([24_000: Gain(dB: -3)!, 72_000: Gain(dB: -6)!], clip: "c1")
        }
        await studio.perform(.seek(.frame(48_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))

        model.run(.nextGainPoint)
        await until("the playhead is at the next point") { studio.playhead == 72_000 }
        model.run(.nextGainPoint)
        #expect(beeps() == 1, "C11: no point after the playhead")
        model.run(.previousGainPoint)
        await until("the playhead is at the point before") { studio.playhead == 24_000 }
        model.run(.previousGainPoint)
        #expect(beeps() == 2, "C11: no point before the playhead")
        await model.close()
    }

    /// Each add and each typed value and each move to a point is announced, with its value.
    @Test func eachChangeIsAnnounced() async throws {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 2))
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setEnvelope([0: Gain(dB: 0)!, 80_000: Gain(dB: -16)!], clip: "c1")
        }
        await studio.perform(.seek(.frame(40_000)))
        model.timeline.selection = .range(Marks(tracks: ["t1"]))

        model.run(.addGainPoint)
        model.run(.previousGainPoint)
        await until("the playhead is at the point before") { studio.playhead == 0 }

        let value = ReadoutLayer.decibels(-8, locale: .current) + " " + L10n.inspectorDecibels.text
        let zero = ReadoutLayer.decibels(0, locale: .current) + " " + L10n.inspectorDecibels.text
        #expect(heard == [L10n.gainPointAdded.format(value), L10n.gainPointAt.format(zero)], "\(heard)")
        await model.close()
    }
}
