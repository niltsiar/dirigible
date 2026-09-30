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
                // View > Show/Hide Toolbar (Option-Command-T) and Customize Toolbar… (decision 0023).
                ToolbarCommands()
                CommandGroup(replacing: .newItem) {
                    Button(L10n.menuFileNew.key) { app.newSession() }.keyboardShortcut(MenuKeys.newSession)
                    Button(L10n.menuFileOpen.key) { app.showOpenPanel() }.keyboardShortcut(MenuKeys.open)
                    Menu(L10n.menuFileOpenRecent.key) {
                        ForEach(app.recent, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { Task { await app.open(url) } }
                        }
                    }
                    Divider()
                    // Export has Command in its keys, so it can be off (probe K1 is about plain keys).
                    ForEach(TimelineCommand.fileItems, id: \.command) { item in
                        menuButton(item).disabled(app.key?.isOn(item.command) == false)
                    }
                }
                // The timeline items (decision 0017). A plain key is never disabled (probe K1).
                CommandGroup(after: .toolbar) {
                    ForEach(TimelineCommand.viewGroups.indices, id: \.self) { group in
                        Divider()
                        ForEach(TimelineCommand.viewGroups[group], id: \.command) { item in
                            if item.command == .toggleFollow {
                                Toggle(
                                    item.title.key,
                                    isOn: Binding(
                                        get: { app.key?.timeline.follows == true },
                                        set: { _ in app.timeline(.toggleFollow) })
                                ).keyboardShortcut(item.key, modifiers: item.modifiers)
                            } else {
                                // Only the history items can be off; they have Command (probe K1).
                                menuButton(item).disabled(app.key?.isOn(item.command) == false)
                            }
                        }
                        if TimelineCommand.viewGroups[group].contains(where: { $0.command == .tallerTracks }) {
                            Button(L10n.menuViewTracksFit.key) { app.timeline(.fitTracks) }
                        }
                    }
                }
                // The Edit group replaces the system items, so Delete has Backspace (probe E6).
                CommandGroup(replacing: .pasteboard) {
                    ForEach(TimelineCommand.pasteboardItems + TimelineCommand.editItems, id: \.command) { item in
                        menuButton(item)
                    }
                }
                // Every marker key is one that a text field uses: never disabled (probe K1).
                CommandMenu(L10n.menuMarkers.key) {
                    ForEach(TimelineCommand.markerItems, id: \.command) { item in menuButton(item) }
                }
                // No CommandGroup for Undo and Redo: the default items send undo: and redo: along
                // the responder chain, so a focused text field keeps its typing undo (P12).
                CommandMenu(L10n.menuTrack.key) {
                    windowButton(.addTrack).disabled(app.key?.canEdit != true)
                    // Its key is one that a text field uses: never disabled (probe K1).
                    ForEach(TimelineCommand.trackItems, id: \.command) { item in menuButton(item) }
                }
                CommandMenu(L10n.menuRecord.key) {
                    windowButton(.record).disabled(app.key?.canRecord != true)
                    Button(L10n.menuRecordRetry.key) { Task { await app.key?.retry() } }
                        .keyboardShortcut(MenuKeys.retry).disabled(app.key?.canRetry != true)
                    let monitor = WindowCommand.toggleMonitor.menuItem
                    Toggle(
                        monitor.title.key,
                        isOn: Binding(
                            get: { app.key?.monitoring == true },
                            set: { if $0 != (app.key?.monitoring == true) { app.key?.run(.toggleMonitor) } })
                    ).keyboardShortcut(monitor.key).disabled(app.key?.canMonitor != true)
                }
                CommandGroup(before: .windowList) {
                    Button(L10n.menuWindowStart.key) { app.showStartWindow() }.keyboardShortcut(MenuKeys.startWindow)
                }
                // Plain keys: never disabled, because a disabled item still takes its key (probe
                // K1). Each action gives a typing key to text or to a panel first.
                CommandMenu(L10n.menuTransport.key) {
                    ForEach(TransportMenu.groups.indices, id: \.self) { group in
                        if group > 0 { Divider() }
                        ForEach(TransportMenu.groups[group], id: \.command) { item in
                            Button(item.title.key) { app.transport(item.command) }.keyboardShortcut(item.key)
                        }
                        // Stop has Command, so it can be off: then Command-period reaches a sheet.
                        if group == 0 { windowButton(.stop).disabled(app.key?.shown.isRunning != true) }
                    }
                }
            }
    }

    /// A window action: the toolbar item of the command calls the same `run(_:)` (decision 0023).
    private func windowButton(_ command: WindowCommand) -> some View {
        let item = command.menuItem
        return Button(item.title.key) { app.key?.run(command) }.keyboardShortcut(item.key)
    }

    private func menuButton(_ item: TimelineCommand.MenuItem) -> some View {
        Button(item.title.key) { app.timeline(item.command) }
            .keyboardShortcut(item.key, modifiers: item.modifiers)
    }
}
