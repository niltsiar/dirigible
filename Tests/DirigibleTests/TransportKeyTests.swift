import AppKit
import DirigibleAudio
import DirigibleCore
import Testing

@testable import DirigibleApp

/// A plain key event: Space (49), J (38), K (40), or L (37).
@MainActor func key(
    _ type: NSEvent.EventType, _ characters: String, code: UInt16, at time: TimeInterval = 0, repeat: Bool = false,
    in window: NSWindow? = nil
) -> NSEvent {
    NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: window?.windowNumber ?? 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: `repeat`,
        keyCode: code)!
}

/// A plain transport key yields to text (timeline-playback criterion 19, plan gate 1 item 4).
/// The windows are real, and the key goes to their field editor (probe K3).
@MainActor struct TypingKeyTests {
    let app = AppDelegate(recordings: nil)

    /// A window with one text field. `focus` makes the field the first responder.
    func window(_ window: NSWindow, focus: Bool) throws -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(focus ? field : nil))
        return field
    }

    /// The same path as the menu action. Control: with no text focus, the field is unchanged,
    /// and the helper gives the key to the transport.
    @Test(arguments: [true, false])
    func aPlainKeyGoesToTheFocusedTextField(focus: Bool) throws {
        let window = UndoRoutingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        let field = try self.window(window, focus: focus)

        app.transport(.playStop, event: key(.keyDown, " ", code: 49, in: window), in: window)
        app.transport(.reverse, event: key(.keyDown, "j", code: 38, in: window), in: window)

        #expect(field.stringValue == (focus ? " j" : ""))
        #expect(forwardTypingKey(key(.keyDown, "l", code: 37, in: window), in: window) == focus)
        #expect(takesTransportKeys(window) == !focus)
    }

    /// A panel is not a session window: it gets the key (the New Session and Open panels).
    @Test func aPlainKeyGoesToAPanelField() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        let field = try window(panel, focus: true)

        #expect(forwardTypingKey(key(.keyDown, "k", code: 40, in: panel), in: panel))

        #expect(field.stringValue == "k")
        #expect(!takesTransportKeys(panel))
    }
}

/// J and L: a tap latches, a hold of 0.3 s or more plays while held (criterion 23, probe H1).
@MainActor struct TransportKeyTests {
    /// The Studio of the key window: any object will do.
    let studio = NSObject()

    @Test func aHoldReleasesAndATapLatches() {
        var hold = ShuttleHold<NSObject>()
        let l = { (type: NSEvent.EventType, time: TimeInterval, again: Bool) in
            key(type, "l", code: 37, at: time, repeat: again)
        }

        #expect(hold.handle(l(.keyDown, 10, false), target: studio) == .pass)
        #expect(hold.handle(l(.keyDown, 10.2, true), target: studio) == .drop, "an auto-repeat")
        #expect(hold.handle(l(.keyUp, 10.3, false), target: studio) == .release(studio), "a hold of 0.3 s")

        #expect(hold.handle(l(.keyDown, 20, false), target: studio) == .pass)
        #expect(hold.handle(l(.keyUp, 20.1, false), target: studio) == .pass, "a tap latches")

        // Text focus: every key-down passes, and its key-up does nothing.
        #expect(hold.handle(l(.keyDown, 30, false), target: nil) == .pass)
        #expect(hold.handle(l(.keyDown, 30.2, true), target: nil) == .pass)
        #expect(hold.handle(l(.keyUp, 30.5, false), target: nil) == .pass)

        // The key-up reads only the stored key-down (plan gate 2 item 6).
        #expect(hold.handle(l(.keyDown, 40, false), target: studio) == .pass)
        #expect(hold.handle(l(.keyUp, 40.5, false), target: nil) == .release(studio))

        // K is not a hold key.
        #expect(hold.handle(key(.keyDown, "k", code: 40, at: 50), target: studio) == .pass)
        #expect(hold.handle(key(.keyUp, "k", code: 40, at: 51), target: studio) == .pass)
    }

    /// Key focus moves to another session window during a hold: the release pauses the Studio of
    /// the key-down, not the new key window. Found by the code gate.
    @Test func aHoldReleasesIntoTheStudioOfTheKeyDown() {
        var hold = ShuttleHold<NSObject>()
        let other = NSObject()

        #expect(hold.handle(key(.keyDown, "j", code: 38, at: 10), target: studio) == .pass)
        #expect(hold.handle(key(.keyUp, "j", code: 38, at: 10.5), target: other) == .release(studio))
    }

    /// The hold follows the character, as the menu key equivalents do, not the ANSI key code. On
    /// Dvorak, key code 35 gives "l" and key code 37 gives "n". Found by the code gate.
    @Test func aHoldFollowsTheCharacter() {
        var hold = ShuttleHold<NSObject>()

        #expect(hold.handle(key(.keyDown, "l", code: 35, at: 10), target: studio) == .pass)
        #expect(hold.handle(key(.keyDown, "l", code: 35, at: 10.2, repeat: true), target: studio) == .drop)
        #expect(hold.handle(key(.keyUp, "l", code: 35, at: 10.4), target: studio) == .release(studio))

        #expect(hold.handle(key(.keyDown, "n", code: 37, at: 20), target: studio) == .pass)
        #expect(hold.handle(key(.keyDown, "n", code: 37, at: 20.2, repeat: true), target: studio) == .pass)
        #expect(hold.handle(key(.keyUp, "n", code: 37, at: 20.4), target: studio) == .pass)
    }

    /// A held Space does not toggle play and stop at the key-repeat rate. Control: the first
    /// key-down passes, and a text field gets the repeats. Found by the code gate.
    @Test func aHeldSpaceActsOnce() {
        var hold = ShuttleHold<NSObject>()

        #expect(hold.handle(key(.keyDown, " ", code: 49, at: 10), target: studio) == .pass)
        #expect(hold.handle(key(.keyDown, " ", code: 49, at: 10.5, repeat: true), target: studio) == .drop)
        #expect(hold.handle(key(.keyUp, " ", code: 49, at: 11), target: studio) == .pass)
        #expect(hold.handle(key(.keyDown, " ", code: 49, at: 20.5, repeat: true), target: nil) == .pass)
    }
}

/// The text of the transport bar (criterion 20).
struct TransportTextTests {
    @Test func timeTextShowsHoursMinutesSecondsAndMilliseconds() {
        #expect(timeText(96_000, rate: 48_000) == "0:00:02.000")
        #expect(timeText(Frames(48_000 * 3600 + 24), rate: 48_000) == "1:00:00.000")
        #expect(timeText(Frames(48_000 * 61 + 12_345), rate: 48_000) == "0:01:01.257")
        #expect(timeText(0, rate: 48_000) == "0:00:00.000")
    }

    /// 7 bytes for each sample and channel after 1 GB and the WAV bytes of the take. Control:
    /// free space below the margin gives 0.
    @Test func remainingRecordTimeLeavesTheMargin() {
        #expect(
            remainingRecordTime(free: 1_000_000_000 + 2_016_000 + 500, wav: 500, channels: 2, rate: 48_000)
                == .seconds(3))
        #expect(remainingRecordTime(free: 900_000_000, wav: 0, channels: 1, rate: 48_000) == .zero)
        #expect(remainingRecordTime(free: 2_000_000_000, wav: 0, channels: 0, rate: 48_000) == .zero)
    }
}
