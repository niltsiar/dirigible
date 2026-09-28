import DirigibleAudio
import SwiftUI

/// The key of each menu item outside the timeline tables (F16). The menus use these values, and
/// `EditKeyTests` checks that no two items of the app share a key and modifiers.
enum MenuKeys {
    static let newSession = KeyboardShortcut("n")
    static let open = KeyboardShortcut("o")
    static let addTrack = KeyboardShortcut("n", modifiers: [.command, .option])
    static let record = KeyboardShortcut("r")
    static let stop = KeyboardShortcut(".")
    static let monitor = KeyboardShortcut("m", modifiers: [.command, .shift])
    static let retry = KeyboardShortcut("r", modifiers: [.command, .option])
    static let play = KeyboardShortcut(.space, modifiers: [])
    static let stopAndReturn = KeyboardShortcut(.space, modifiers: .shift)
    static let reverse = KeyboardShortcut("j", modifiers: [])
    static let pause = KeyboardShortcut("k", modifiers: [])
    static let forward = KeyboardShortcut("l", modifiers: [])
    static let slowReverse = KeyboardShortcut("j", modifiers: .shift)
    static let slowForward = KeyboardShortcut("l", modifiers: .shift)
    static let start = KeyboardShortcut(.home, modifiers: [])
    static let end = KeyboardShortcut(.end, modifiers: [])
    static let previousClip = KeyboardShortcut(.leftArrow, modifiers: .shift)
    static let nextClip = KeyboardShortcut(.rightArrow, modifiers: .shift)
    /// Command-= runs Zoom In (U1). The window takes it, not a menu item (`UndoRoutingWindow`).
    static let zoomInEquals = KeyboardShortcut("=")

    /// The keys of the items that macOS and SwiftUI add: Undo, Redo, Close, Quit, Hide, Hide
    /// Others, Minimize, Enter Full Screen, and Show/Hide Toolbar (`ToolbarCommands`). Then the
    /// keys that macOS takes before the app (U6): Accessibility Zoom (Option-Command-=, -minus,
    /// -8), the emoji viewer, Lock Screen, Look Up, the Control-Command copy and paste of the
    /// screenshot tools, and Mission Control and the Spaces (Control with the arrows).
    static let system =
        [
            KeyboardShortcut("z"), KeyboardShortcut("z", modifiers: [.command, .shift]), KeyboardShortcut("w"),
            KeyboardShortcut("q"), KeyboardShortcut("h"), KeyboardShortcut("h", modifiers: [.command, .option]),
            KeyboardShortcut("m"), KeyboardShortcut("f", modifiers: [.command, .control]),
            KeyboardShortcut("t", modifiers: [.command, .option]),
            KeyboardShortcut("=", modifiers: [.command, .option]),
            KeyboardShortcut("-", modifiers: [.command, .option]),
            KeyboardShortcut("8", modifiers: [.command, .option]),
            KeyboardShortcut(.space, modifiers: [.command, .control]),
            KeyboardShortcut("q", modifiers: [.command, .control]),
            KeyboardShortcut("d", modifiers: [.command, .control]),
            KeyboardShortcut("c", modifiers: [.command, .control]),
            KeyboardShortcut("v", modifiers: [.command, .control]),
        ]
        + [KeyEquivalent.leftArrow, .rightArrow, .upArrow, .downArrow].map { KeyboardShortcut($0, modifiers: .control) }

    static let all =
        [
            newSession, open, addTrack, record, stop, monitor, retry, play, stopAndReturn, reverse, pause, forward,
            slowReverse, slowForward, start, end, previousClip, nextClip, zoomInEquals,
        ] + system
}

/// The plain-key items of the Transport menu (decision 0016), in groups. The menu is built from
/// this table, and a toolbar item of a transport command takes its title and key from it.
enum TransportMenu {
    struct Item {
        let title: L10n
        let command: TransportCommand
        let key: KeyboardShortcut
    }

    static let groups: [[Item]] = [
        [
            Item(title: .menuTransportPlay, command: .playStop, key: MenuKeys.play),
            Item(title: .menuTransportReturn, command: .stopAndReturn, key: MenuKeys.stopAndReturn),
        ],
        [
            Item(title: .menuTransportReverse, command: .reverse, key: MenuKeys.reverse),
            Item(title: .menuTransportPause, command: .pause, key: MenuKeys.pause),
            Item(title: .menuTransportForward, command: .forward, key: MenuKeys.forward),
            Item(title: .menuTransportSlowReverse, command: .slowReverse, key: MenuKeys.slowReverse),
            Item(title: .menuTransportSlowForward, command: .slowForward, key: MenuKeys.slowForward),
        ],
        [
            Item(title: .menuTransportStart, command: .seek(.start), key: MenuKeys.start),
            Item(title: .menuTransportEnd, command: .seek(.end), key: MenuKeys.end),
            Item(title: .menuTransportPrevious, command: .seek(.previousClip), key: MenuKeys.previousClip),
            Item(title: .menuTransportNext, command: .seek(.nextClip), key: MenuKeys.nextClip),
        ],
    ]
}
