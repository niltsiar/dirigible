import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Track fader C12 (F94): Track > Raise, Lower, and Reset Track Volume act on the tracks of the
/// range selection, each track from its own value, in one edit.
@Suite(.serialized) @MainActor struct TrackVolumeKeyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    func model(tracks: Int = 3) async throws -> (SessionWindow, Studio) {
        try await timelineModel(try await timelinePackage(in: folder.url, tracks: tracks, seconds: 1), app: app)
    }

    func gains(_ studio: Studio) -> [Double] { studio.session.tracks.map(\.gain.dB) }

    func setGains(_ studio: Studio, _ values: [Double]) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            for (track, dB) in zip(session.tracks.map(\.id), values) {
                try session.setGain(Gain(dB: dB)!, track: track)
            }
        }
    }

    @Test func theItemsStepEachTrackOfTheRangeInOneEdit() async throws {
        let (model, studio) = try await model()
        try setGains(studio, [-6, 2, 0])
        model.timeline.selection = .range(Marks(tracks: ["t1", "t2"]))
        let start = studio.sessionRevision

        model.run(.raiseVolume)
        #expect(gains(studio) == [-5, 3, 0], "C12: Raise adds 1 dB to each selected track")
        #expect(studio.sessionRevision == start + 1, "C12: one edit")
        model.run(.lowerVolume)
        model.run(.lowerVolume)
        #expect(gains(studio) == [-7, 1, 0], "C12: Lower removes 1 dB from each")
        model.run(.resetVolume)
        #expect(gains(studio) == [0, 0, 0], "C12: Reset sets 0 dB")
        try studio.undo()
        #expect(gains(studio) == [-7, 1, 0], "C12: one undo entry for the reset")
        await model.close()
    }

    /// C12: a step stops at the end of the travel, and a stored value outside it does not move
    /// further out.
    @Test func aStepStopsAtTheEndOfTheTravel() async throws {
        let (model, studio) = try await model()
        try setGains(studio, [19.5, -59.5, 30])
        model.timeline.selection = .range(Marks(tracks: ["t1", "t3"]))
        model.run(.raiseVolume)
        #expect(gains(studio)[0] == 20 && gains(studio)[2] == 30, "C12: Raise stops at +20 dB: \(gains(studio))")
        model.timeline.selection = .range(Marks(tracks: ["t2", "t3"]))
        model.run(.lowerVolume)
        #expect(gains(studio)[1] == -60 && gains(studio)[2] == 29, "C12: Lower stops at -60 dB: \(gains(studio))")
        await model.close()
    }

    /// C12: with no range, or with a clip set, the items beep and change nothing (decision 0038).
    @Test func noRangeBeeps() async throws {
        let (model, studio) = try await model()
        var beeps = 0
        model.beep = { beeps += 1 }
        let before = studio.session

        model.timeline.selection = .none
        model.run(.raiseVolume)
        model.timeline.selection = .clips(try #require(ClipSet(["c1"])))
        model.run(.resetVolume)

        #expect(studio.session == before && beeps == 2, "C12: two beeps and no change: \(beeps)")
        await model.close()
    }

    @Test func aTakeTurnsTheItemsOff() async throws {
        let (model, studio) = try await model()
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }

        #expect(
            [TimelineCommand.raiseVolume, .lowerVolume, .resetVolume].allSatisfy { !model.isOn($0) },
            "C12: the items are off during a take")
        model.run(.raiseVolume)
        #expect(gains(studio) == [0, 0, 0], "C12: no change during a take")
        await model.close()
    }

    /// C12: a focused name field does not use Control-=, so the item acts on the selected track.
    @Test func controlEqualsActsWithTheNameFieldFocused() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        _ = try await focusName(in: window)
        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "=", charactersIgnoringModifiers: "=",
                isARepeat: false, keyCode: 24))

        app.timeline(.raiseVolume, event: event, in: window)

        #expect(studio.session.track("t1")?.gain.dB == 1, "C12: Control-= raises the selected track")
        await model.close()
    }

    /// C12 (the K1 method of decision 0025): an AppKit menu with the keys of the items takes the US
    /// Control-= and the Spanish Control-Shift-0, which types "=".
    @Test func theUSAndTheSpanishChordsReachRaise() {
        let menu = NSMenu()
        var fired: [String] = []
        final class Target: NSObject {
            var action: (String) -> Void = { _ in }
            @objc func fire(_ item: NSMenuItem) { action(item.title) }
        }
        let target = Target()
        target.action = { fired.append($0) }
        for item in TimelineCommand.trackItems where item.key.character != "\u{8}" && item.key != .return {
            let menuItem = NSMenuItem(
                title: "\(item.command)", action: #selector(Target.fire(_:)), keyEquivalent: String(item.key.character))
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(item.modifiers)
            menuItem.target = target
            menu.addItem(menuItem)
        }
        func chord(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }

        #expect(menu.performKeyEquivalent(with: chord("=", .control, code: 24)), "C12: the US Control-=")
        #expect(
            menu.performKeyEquivalent(with: chord("=", [.control, .shift], code: 29)), "C12: Control-Shift-0 (es)")
        #expect(menu.performKeyEquivalent(with: chord("-", .control, code: 27)), "C12: the US Control-minus")
        #expect(menu.performKeyEquivalent(with: chord("-", .control, code: 44)), "C12: the Spanish Control-minus")
        #expect(menu.performKeyEquivalent(with: chord("0", .control, code: 29)), "C12: Control-0")
        // On screen, the automatic key localization moved "=" to the "*" key of the Spanish layout.
        #expect(
            [TimelineCommand.raiseVolume, .lowerVolume, .resetVolume].allSatisfy {
                "\($0.keyLocalization)" == "\(KeyboardShortcut.Localization.custom)"
            }, "C12: the menu keeps the typed characters")
        #expect(
            fired == ["raiseVolume", "raiseVolume", "lowerVolume", "lowerVolume", "resetVolume"],
            "C12: each chord reaches its item: \(fired)")
    }
}

extension NSEvent.ModifierFlags {
    /// The AppKit flags of SwiftUI event modifiers.
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.control) { insert(.control) }
    }
}
