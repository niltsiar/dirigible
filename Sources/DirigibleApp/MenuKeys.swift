import SwiftUI

/// The key of each menu item outside the timeline tables (F16). The menus use these values, and
/// `EditKeyTests` checks that no two items of the app share a key and modifiers.
enum MenuKeys {
    static let newSession = KeyboardShortcut("n")
    static let open = KeyboardShortcut("o")
    static let addTrack = KeyboardShortcut("n", modifiers: [.command, .option])
    static let record = KeyboardShortcut("r")
    static let stop = KeyboardShortcut(".")
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

    /// The keys of the items that macOS and SwiftUI add: Undo, Redo, Close, Quit, Hide, Hide
    /// Others, Minimize, and Enter Full Screen.
    static let system = [
        KeyboardShortcut("z"), KeyboardShortcut("z", modifiers: [.command, .shift]), KeyboardShortcut("w"),
        KeyboardShortcut("q"), KeyboardShortcut("h"), KeyboardShortcut("h", modifiers: [.command, .option]),
        KeyboardShortcut("m"), KeyboardShortcut("f", modifiers: [.command, .control]),
    ]

    static let all =
        [
            newSession, open, addTrack, record, stop, retry, play, stopAndReturn, reverse, pause, forward,
            slowReverse, slowForward, start, end, previousClip, nextClip,
        ] + system
}
