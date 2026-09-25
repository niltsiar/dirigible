import DirigibleAudio
import SwiftUI

/// Only a Settings scene: the app delegate makes one AppKit window per package (decision 0014,
/// probe P5d). The commands act on the key session window.
@main
struct DirigibleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var app

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {
                    Button(L10n.menuFileNew.key) { app.newSession() }.keyboardShortcut(MenuKeys.newSession)
                    Button(L10n.menuFileOpen.key) { app.showOpenPanel() }.keyboardShortcut(MenuKeys.open)
                    Menu(L10n.menuFileOpenRecent.key) {
                        ForEach(app.recent, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { Task { await app.open(url) } }
                        }
                    }
                }
                // The timeline items (decision 0017). A plain key is never disabled (probe K1).
                CommandGroup(after: .toolbar) {
                    ForEach(TimelineCommand.viewItems, id: \.command) { item in
                        if item.command == .toggleFollow {
                            Toggle(
                                item.title.key,
                                isOn: Binding(
                                    get: { app.key?.timeline.follows == true },
                                    set: { _ in app.timeline(.toggleFollow, plain: false) })
                            ).keyboardShortcut(item.key, modifiers: item.modifiers)
                        } else {
                            menuButton(item)
                        }
                    }
                }
                // The Edit group replaces the system items, so Delete has Backspace (probe E6).
                CommandGroup(replacing: .pasteboard) {
                    ForEach(TimelineCommand.pasteboardItems + TimelineCommand.editItems, id: \.command) { item in
                        menuButton(item)
                    }
                }
                // No CommandGroup for Undo and Redo: the default items send undo: and redo: along
                // the responder chain, so a focused text field keeps its typing undo (P12).
                CommandMenu(L10n.menuTrack.key) {
                    Button(L10n.menuTrackAdd.key) { app.key?.addTrack() }
                        .keyboardShortcut(MenuKeys.addTrack)
                        .disabled(app.key?.canEdit != true)
                }
                CommandMenu(L10n.menuRecord.key) {
                    Button(L10n.menuRecordStart.key) { Task { await app.key?.record() } }
                        .keyboardShortcut(MenuKeys.record).disabled(app.key?.canRecord != true)
                    Button(L10n.menuRecordStop.key) { Task { await app.key?.stop() } }
                        .keyboardShortcut(MenuKeys.stop).disabled(app.key?.canStop != true)
                    Button(L10n.menuRecordRetry.key) { Task { await app.key?.retry() } }
                        .keyboardShortcut(MenuKeys.retry).disabled(app.key?.canRetry != true)
                    Toggle(
                        L10n.menuRecordMonitor.key,
                        isOn: Binding(get: { app.key?.monitoring == true }, set: { app.key?.monitoring = $0 })
                    ).disabled(app.key?.canMonitor != true)
                }
                // Plain keys: never disabled, because a disabled item still takes its key (probe
                // K1). Each action gives a typing key to text or to a panel first.
                CommandMenu(L10n.menuTransport.key) {
                    transportButton(.menuTransportPlay, .playStop, MenuKeys.play)
                    transportButton(.menuTransportReturn, .stopAndReturn, MenuKeys.stopAndReturn)
                    Divider()
                    transportButton(.menuTransportReverse, .reverse, MenuKeys.reverse)
                    transportButton(.menuTransportPause, .pause, MenuKeys.pause)
                    transportButton(.menuTransportForward, .forward, MenuKeys.forward)
                    transportButton(.menuTransportSlowReverse, .slowReverse, MenuKeys.slowReverse)
                    transportButton(.menuTransportSlowForward, .slowForward, MenuKeys.slowForward)
                    Divider()
                    transportButton(.menuTransportStart, .seek(.start), MenuKeys.start)
                    transportButton(.menuTransportEnd, .seek(.end), MenuKeys.end)
                    transportButton(.menuTransportPrevious, .seek(.previousClip), MenuKeys.previousClip)
                    transportButton(.menuTransportNext, .seek(.nextClip), MenuKeys.nextClip)
                }
            }
    }

    private func transportButton(_ title: L10n, _ command: TransportCommand, _ key: KeyboardShortcut) -> some View {
        Button(title.key) { app.transport(command) }.keyboardShortcut(key)
    }

    private func menuButton(_ item: TimelineCommand.MenuItem) -> some View {
        Button(item.title.key) { app.timeline(item.command, plain: item.modifiers.isEmpty) }
            .keyboardShortcut(item.key, modifiers: item.modifiers)
    }
}
