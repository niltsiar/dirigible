import AppKit

/// J and L (decision 0016, probe H1): a tap latches, and a hold of `threshold` or more plays
/// while held. The local key monitor of the app calls `handle` for each key-down and key-up. The
/// menu items keep the keys; the monitor only drops the auto-repeat and reads the key-up.
struct ShuttleHold {
    enum Action: Equatable {
        /// The event goes on.
        case pass
        /// An auto-repeat of J or L: the menu action must not run again.
        case drop
        /// The key-up of a hold: pause.
        case release
    }

    /// A shorter press latches (a calibration knob).
    static let threshold: TimeInterval = 0.3
    /// The key codes of J and L; Shift-J and Shift-L have the same codes.
    private static let codes: Set<UInt16> = [38, 37]

    /// The key code and the time of the last J or L key-down that went to the transport.
    private var down: (code: UInt16, time: TimeInterval)?

    /// `forTransport`: the key window takes transport keys now. Only a key-down reads it; a
    /// key-up reads only the stored key-down (plan gate 2 item 6).
    mutating func handle(_ event: NSEvent, forTransport: Bool) -> Action {
        guard Self.codes.contains(event.keyCode),
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return .pass }
        switch event.type {
        case .keyDown:
            guard forTransport else { return .pass }
            if event.isARepeat { return .drop }
            down = (event.keyCode, event.timestamp)
            return .pass
        case .keyUp:
            guard let down, down.code == event.keyCode else { return .pass }
            self.down = nil
            return event.timestamp - down.time >= Self.threshold ? .release : .pass
        default:
            return .pass
        }
    }
}
