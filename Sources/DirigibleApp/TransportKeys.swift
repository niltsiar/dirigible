import AppKit

/// J and L (decision 0016, probe H1): a tap latches, and a hold of `threshold` or more plays
/// while held. The local key monitor of the app calls `handle` for each key-down and key-up. The
/// menu items keep the keys; the monitor only drops the auto-repeat and reads the key-up. It
/// also drops the auto-repeat of Space, so a held Space does not toggle play and stop.
struct ShuttleHold {
    enum Action: Equatable {
        /// The event goes on.
        case pass
        /// An auto-repeat of J, L, or Space: the menu action must not run again.
        case drop
        /// The key-up of a hold: pause.
        case release
    }

    /// A shorter press latches (a calibration knob).
    static let threshold: TimeInterval = 0.3
    /// The characters of J and L, as the menu key equivalents match them: by character, not by
    /// key code, so a layout that moves the keys (Dvorak) still works. Shift gives "J" and "L".
    private static let keys: Set<String> = ["j", "l"]

    /// The character and the time of the last J or L key-down that went to the transport.
    private var down: (key: String, time: TimeInterval)?

    /// `forTransport`: the key window takes transport keys now. Only a key-down reads it; a
    /// key-up reads only the stored key-down (plan gate 2 item 6).
    mutating func handle(_ event: NSEvent, forTransport: Bool) -> Action {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return .pass }
        if key == " " {
            return event.type == .keyDown && event.isARepeat && forTransport ? .drop : .pass
        }
        guard Self.keys.contains(key) else { return .pass }
        switch event.type {
        case .keyDown:
            guard forTransport else { return .pass }
            if event.isARepeat { return .drop }
            down = (key, event.timestamp)
            return .pass
        case .keyUp:
            guard let down, down.key == key else { return .pass }
            self.down = nil
            return event.timestamp - down.time >= Self.threshold ? .release : .pass
        default:
            return .pass
        }
    }
}
