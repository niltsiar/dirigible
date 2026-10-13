import AppKit
import DirigibleCore
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Vari-speed criteria V8 and V10 (run 2026-10-13-preroll-varispeed): Transport > Playback Speed,
/// its plain keys in each start state, and the last-speed preference. A play at a speed is
/// `StudioSpeedTests` (the same `Studio.perform` path).
@Suite(.serialized) @MainActor struct SpeedKeyTests {
    let folder: TemporaryFolder
    let defaults: UserDefaults
    let app: AppDelegate

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: "speed-\(UUID().uuidString)"))
        app = AppDelegate(recordings: nil, defaults: defaults)
    }

    /// A Period, ">", or "<" key-down: the characters and the key code of the layout.
    func event(_ characters: String, code: UInt16, shift: Bool = false, in window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// The studio after `perform` of the task of the menu action ran.
    func settle(_ studio: Studio, _ expected: Speed) async {
        await until("the speed is \(expected)") { studio.speed == expected }
    }

    @Test func theSpeedItemsHaveTheirKeys() {
        #expect(MenuKeys.variSpeed == KeyboardShortcut(".", modifiers: []))
        #expect(MenuKeys.faster == KeyboardShortcut(">", modifiers: []))
        #expect(MenuKeys.slower == KeyboardShortcut("<", modifiers: []))
        #expect(SpeedMenu.items.map(\.command) == [.speed(.toggle), .speed(.faster), .speed(.slower)])
        #expect(SpeedMenu.items.map(\.key) == [MenuKeys.variSpeed, MenuKeys.faster, MenuKeys.slower])
    }

    /// V8 and V10: with no text focus Period turns on the last speed (the preference), Faster
    /// steps from it, and the window writes the new last speed to the preference.
    @Test func periodTurnsOnTheLastSpeed() async throws {
        defaults.set(1.75, forKey: AppDelegate.speedKey)
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 2))
        window.makeFirstResponder(nil)

        app.transport(.speed(.toggle), event: event(".", code: 47, in: window), in: window)
        await settle(studio, .x175)
        app.transport(.speed(.slower), event: event("<", code: 43, shift: true, in: window), in: window)
        await settle(studio, .x150)
        #expect(app.lastSpeed == .x150 && defaults.double(forKey: AppDelegate.speedKey) == 1.5)
        #expect(studio.playback == .stopped, "a speed key while stopped starts no play")
        await model.close()
    }

    /// V8: a focused text field gets the character, and the speed does not change.
    @Test func aFocusedTextFieldKeepsTheSpeedKeys() async throws {
        let (model, studio, window, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 2))
        let editor = try await focusName(in: window)

        app.transport(.speed(.toggle), event: event(".", code: 47, in: window), in: window)
        app.transport(.speed(.faster), event: event(">", code: 47, shift: true, in: window), in: window)

        // The field selects its whole text at focus, so the first key replaces it.
        #expect(editor.string == ".>", "the field got \(editor.string)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(studio.speed == .one)
        await model.close()
    }

    /// V8: during a take the speed keys do nothing.
    @Test func aTakeIgnoresTheSpeedKeys() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 2), app: app)
        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }

        model.transport(.speed(.toggle))
        model.transport(.speed(.faster))
        try await Task.sleep(for: .milliseconds(200))

        #expect(studio.speed == .one)
        await model.close()
    }

    /// V8 and agent check M4: the Spanish ISO layout types "<" and ">" with key code 50 (the key
    /// left of Z), Shift for ">". The US layout types them with Shift-Comma and Shift-Period. The
    /// menu matches the characters, so each event reaches its item.
    @Test func spanishISOKeysStepTheSpeed() {
        final class Target: NSObject {
            var fired: [String] = []
            @objc func fire(_ item: NSMenuItem) { fired.append(item.title) }
        }
        let target = Target()
        let menu = NSMenu()
        for item in SpeedMenu.items {
            let key = String(item.key.key.character)
            let menuItem = NSMenuItem(title: "\(item.command)", action: #selector(Target.fire(_:)), keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = []
            menuItem.target = target
            menu.addItem(menuItem)
        }

        #expect(menu.performKeyEquivalent(with: event("<", code: 50)), "es: the key left of Z")
        #expect(menu.performKeyEquivalent(with: event(">", code: 50, shift: true)), "es: Shift and the key left of Z")
        #expect(menu.performKeyEquivalent(with: event("<", code: 43, shift: true)), "us: Shift-Comma")
        #expect(menu.performKeyEquivalent(with: event(">", code: 47, shift: true)), "us: Shift-Period")
        #expect(menu.performKeyEquivalent(with: event(".", code: 47)), "Period")
        #expect(!menu.performKeyEquivalent(with: event(":", code: 47, shift: true)), "es: Shift-Period types a colon")
        #expect(
            target.fired == [
                "speed(DirigibleAudio.SpeedChange.slower)", "speed(DirigibleAudio.SpeedChange.faster)",
                "speed(DirigibleAudio.SpeedChange.slower)", "speed(DirigibleAudio.SpeedChange.faster)",
                "speed(DirigibleAudio.SpeedChange.toggle)",
            ], "each key reaches its item: \(target.fired)")
    }

    /// V10: a stored speed other than 1 that is a step reads as itself; any other value as 1.5.
    @Test func speedPreferenceReadsSteps() {
        #expect(AppDelegate.lastSpeed(stored: 1.25) == .x125)
        #expect(AppDelegate.lastSpeed(stored: 0.75) == .x075)
        #expect(AppDelegate.lastSpeed(stored: 2.0) == .x200)
        for bad: Any? in [3.0, 1.3, 1.0, 0.5, "1.25", nil] {
            #expect(AppDelegate.lastSpeed(stored: bad) == .x150, "\(String(describing: bad))")
        }
    }

    /// V9: the readout in the number format of the locale, and its spoken value.
    @Test func theReadoutFollowsTheLocale() {
        let english = Locale(identifier: "en_US")
        let spanish = Locale(identifier: "es_ES")
        #expect(speedText(.one, locale: english) == "1×")
        #expect(speedText(.x150, locale: english) == "1.5×" && speedText(.x150, locale: spanish) == "1,5×")
        #expect(speedText(.x175, locale: spanish) == "1,75×")
        #expect(speedSpokenText(.x150, locale: english, format: "%@ times") == "1.5 times")
        #expect(speedSpokenText(.x150, locale: spanish, format: "%@ veces") == "1,5 veces")
    }
}
