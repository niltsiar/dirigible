import AppKit

/// J and L (decision 0016, probe H1): a tap latches, and a hold of `threshold` or more plays
/// while held. The local key monitor of the app calls `handle` for each key-down and key-up. The
/// menu items keep the keys; the monitor only drops the auto-repeat and reads the key-up. It
/// also drops the auto-repeat of Space, so a held Space does not toggle play and stop.
/// `Target` is the Studio of the key window at the key-down. The release goes to it, also when
/// the key focus moved before the key-up.
struct ShuttleHold<Target: AnyObject> {
    enum Action {
        /// The event goes on.
        case pass
        /// An auto-repeat of J, L, or Space: the menu action must not run again.
        case drop
        /// The key-up of a hold: pause this target.
        case release(Target)
    }

    /// A J or L key-down that went to the transport. Weak, so a window that closes during a
    /// hold does not keep its Studio (and its package lock).
    private struct Down {
        let key: String
        let time: TimeInterval
        weak var target: Target?
    }

    /// A shorter press latches (a calibration knob).
    static var threshold: TimeInterval { 0.3 }
    /// The characters of J and L, as the menu key equivalents match them: by character, not by
    /// key code, so a layout that moves the keys (Dvorak) still works. Shift gives "J" and "L".
    private static var keys: Set<String> { ["j", "l"] }

    /// The last J or L key-down that went to the transport.
    private var down: Down?

    /// `target`: the Studio of the key window when it takes transport keys now, else nil. Only a
    /// key-down reads it; a key-up reads only the stored key-down (plan gate 2 item 6).
    mutating func handle(_ event: NSEvent, target: Target?) -> Action {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return .pass }
        if key == " " {
            return event.type == .keyDown && event.isARepeat && target != nil ? .drop : .pass
        }
        guard Self.keys.contains(key) else { return .pass }
        switch event.type {
        case .keyDown:
            guard let target else { return .pass }
            if event.isARepeat { return .drop }
            down = Down(key: key, time: event.timestamp, target: target)
            return .pass
        case .keyUp:
            guard let down, down.key == key else { return .pass }
            self.down = nil
            guard let target = down.target, event.timestamp - down.time >= Self.threshold else { return .pass }
            return .release(target)
        default:
            return .pass
        }
    }
}

extension ShuttleHold.Action: Equatable where Target: Equatable {}
