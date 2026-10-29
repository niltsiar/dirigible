import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// P14: the keys with the Transcript pane focused (run transcript-1, landing 2).
extension TranscriptPaneTests {
    /// What a key can change in a session window, with no random ID (the markers and the transcript
    /// file get one in each package). The playhead counts only when stopped, because the two windows
    /// poll at different moments while they play.
    struct KeyState: Equatable {
        let tracks: String
        let markers: [String]
        let words: [String]
        let playback: Playback
        let playhead: Frames?
        let selection: String
        let scale: String

        /// The fields that differ, each with the two values, cut to 120 characters.
        func differences(from other: KeyState) -> [String] {
            func cut(_ value: some Any) -> String { String(String(describing: value).prefix(120)) }
            var found: [String] = []
            if tracks != other.tracks { found.append("tracks \(cut(tracks)) | \(cut(other.tracks))") }
            if markers != other.markers { found.append("markers \(markers) | \(other.markers)") }
            if words != other.words { found.append("words \(words.count) | \(other.words.count)") }
            if playback != other.playback { found.append("playback \(playback) | \(other.playback)") }
            if playhead != other.playhead {
                found.append("playhead \(String(describing: playhead)) | \(String(describing: other.playhead))")
            }
            if selection != other.selection { found.append("selection \(selection) | \(other.selection)") }
            if scale != other.scale { found.append("scale \(scale) | \(other.scale)") }
            return found
        }
    }

    func keyState(_ model: SessionWindow, _ studio: Studio) -> KeyState {
        KeyState(
            tracks: String(describing: studio.session.tracks),
            markers: studio.session.markers.values.map { "\($0.position) \($0.kind) \($0.name)" }.sorted(),
            words: studio.session.words().map { "\($0.text) \($0.range)" }, playback: studio.playback,
            playhead: studio.playback == .stopped ? studio.playhead : nil,
            selection: String(describing: model.timeline.selection),
            scale: String(describing: model.timeline.scale))
    }

    /// A window with the Transcript tab shown, a range selected, and the playhead at 100 000.
    func keyWindow(
        _ name: String, focus: Bool
    ) async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView, TranscriptTextView) {
        let (model, studio, window, view) = try await open(try await package(name: name))
        // The same size and zoom, so the zoom keys give the same scale in both windows.
        window.setFrame(NSRect(x: 100, y: 100, width: 1400, height: 800), display: true)
        model.showTranscript()
        let pane = try await waitForPane(window)
        window.contentView?.layoutSubtreeIfNeeded()
        model.timeline.scale = TimelineScale(framesPerPoint: 1_000)
        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        await seek(studio, to: 100_000)
        #expect(window.makeFirstResponder(focus ? pane : view.lanes))
        return (model, studio, window, view, pane)
    }

    /// The commands that open a panel, an alert, or another tab, or that move the focus. They
    /// would leave the pane, so the table cannot compare them.
    static let notComparable: Set<TimelineCommand> = [
        .importAudio, .export, .exportSelection, .exportChapters, .exportTranscript, .episodeInfo, .markerInfo,
        .renameTrack, .removeTrack, .showInFinder,
    ]

    /// Delete runs Delete and Close Gap in the pane (P10).
    static let paneExceptions: Set<TimelineCommand> = [.delete]

    /// The keys of the table, each with its name and the call of its menu action.
    var keyTable: [(name: String, send: (NSEvent, NSWindow) -> Void)] {
        let commands = TimelineCommand.menuItems.keys.filter { $0.forwardsKey || $0.selector != nil }
            .filter { !Self.notComparable.contains($0) && !Self.paneExceptions.contains($0) }
            .sorted { "\($0)" < "\($1)" }
        let timeline = commands.map { command in
            (
                name: "\(command)",
                send: { (event: NSEvent, window: NSWindow) in
                    app.timeline(command, event: event, in: window)
                }
            )
        }
        let transport = TransportMenu.groups.joined().map { item in
            (
                name: "\(item.command)",
                send: { (event: NSEvent, window: NSWindow) in
                    app.transport(item.command, event: event, in: window)
                }
            )
        }
        let speed = SpeedMenu.items.map { item in
            (
                name: "\(item.change)",
                send: { (event: NSEvent, window: NSWindow) in
                    app.speed(item.change, event: event, in: window)
                }
            )
        }
        return timeline + transport + speed
    }

    /// Sends each key of the table to a new window with the focus in the pane or in the lanes, and
    /// gives the state after each key. The windows run one after the other, because a paste from
    /// the package of another window is async. The focus goes back after each key.
    func keyStates(focusPane: Bool, name: String) async throws -> (states: [String: KeyState], changes: Int) {
        app.clipboard = nil
        let (model, studio, window, view, pane) = try await keyWindow(name, focus: focusPane)
        app.key = model
        var (states, changes) = ([String: KeyState](), 0)
        var previous = keyState(model, studio)
        for (name, send) in keyTable {
            send(key(.keyDown, "x", code: 7, in: window), window)
            // A seek is async: the studio takes the new playhead a moment later.
            try await Task.sleep(for: .milliseconds(60))
            states[name] = keyState(model, studio)
            if states[name] != previous { changes += 1 }
            previous = keyState(model, studio)
            #expect(model.inspectorTab == .transcript, "\(name) keeps the tab")
            #expect(window.makeFirstResponder(focusPane ? pane : view.lanes), "\(name) leaves the focus movable")
        }
        await model.close()
        return (states, changes)
    }

    /// P14: for each item whose route reads the focus (each `forwardsKey` item and each `selector`
    /// item of the timeline menu tables, the plain transport keys, and the speed keys; not
    /// `MenuKeys.system`), the window state after the key with the pane focused equals the state
    /// with the lanes focused. Both windows get the same keys in the same order.
    @Test func paneKeysMatchTheLanes() async throws {
        let lanes = try await keyStates(focusPane: false, name: "lanes")
        let pane = try await keyStates(focusPane: true, name: "pane")
        #expect(lanes.states.count >= 30, "\(lanes.states.count) keys")
        let failures = keyTable.compactMap { entry in
            lanes.states[entry.name].flatMap { a in pane.states[entry.name].map { (entry.name, a, $0) } }
                .flatMap { $0.1 == $0.2 ? nil : "\($0.0): \($0.1.differences(from: $0.2))" }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(lanes.changes >= 10, "only \(lanes.changes) keys changed the lanes window: the table must act")
    }

    /// P14: an editable field keeps its keys. Space types in the Episode Title field, and
    /// Command-Z there undoes the text, not the session.
    @Test func editableFieldKeepsItsKeys() async throws {
        let (model, studio, window, _) = try await open(try await package())
        model.showTranscript()
        _ = try await waitForPane(window)
        model.showEpisodeInfo()
        try await type("Ab", intoTitleOf: window, model)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let before = editor.string
        let session = studio.session

        app.key = model
        app.transport(.playStop, event: key(.keyDown, " ", code: 49, in: window), in: window)

        #expect(editor.string == before + " ", "Space types in the field: \(editor.string.debugDescription)")
        #expect(studio.playback == .stopped, "Space does not play")
        #expect(undoTarget(firstResponder: editor) == .text, "Command-Z goes to the field")
        #expect(studio.session == session, "the key made no session edit")
        await model.close()
    }
}
