import DirigibleAudio
import SwiftUI

/// Only a Settings scene (the language, decision 0010): the app delegate makes one AppKit window
/// per package (decision 0014, probe P5d). The commands act on the key session window.
@main
struct DirigibleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var app

    var body: some Scene {
        // The system adds Dirigible > Settings… with Command-comma.
        Settings { SettingsView(defaults: app.defaults, domain: Bundle.main.bundleIdentifier, app: app) }
            .commands {
                // View > Show/Hide Toolbar (Option-Command-T) and Customize Toolbar… (decision 0023).
                ToolbarCommands()
                CommandGroup(replacing: .newItem) {
                    Button(L10n.menuFileNew.key) { app.newSession() }.keyboardShortcut(MenuKeys.newSession)
                    Button(L10n.menuFileOpen.key) { app.showOpenPanel() }.keyboardShortcut(MenuKeys.open)
                    Menu(L10n.menuFileOpenRecent.key) {
                        ForEach(app.recent, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { Task { await app.open(url) } }
                        }
                        Divider()
                        Button(L10n.menuFileClearRecent.key) { app.clearRecent() }
                    }
                    Divider()
                    // Export has Command in its keys, so it can be off (probe K1 is about plain keys).
                    ForEach(TimelineCommand.fileItems, id: \.command) { item in
                        menuButton(item)
                        // No key: a rare command, after the other exports.
                        if item.command == .exportChapters {
                            Button(L10n.menuFileExportTranscript.key) { app.timeline(.exportTranscript) }
                                .disabled(app.key?.isOn(.exportTranscript) != true)
                        }
                    }
                    Divider()
                    // The submenu stays on; each item is off while the window is busy (decision 0043).
                    Menu(L10n.menuFileRevertTo.key) {
                        let menu = RevertMenu(app.key)
                        if menu.backups.isEmpty { Button(L10n.menuFileRevertToNone.key) {}.disabled(true) }
                        ForEach(Array(zip(menu.backups, menu.titles)), id: \.0) { backup, title in
                            Button(title) { app.key?.revert(to: backup) }.disabled(!menu.enabled)
                        }
                    }
                    // No key: a rare command that moves files to the Trash (decision 0047).
                    Button(L10n.menuFileRemoveUnused.key) { app.key?.removeUnusedFiles() }
                        .disabled(!app.canRemoveUnusedFiles)
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
                                menuButton(item)
                            }
                        }
                        if TimelineCommand.viewGroups[group].contains(where: { $0.command == .tallerTracks }) {
                            Button(L10n.menuViewTracksFit.key) { app.timeline(.fitTracks) }
                        }
                    }
                    // Snap joins the group of Automatic Scroll. A plain key: never disabled (probe K1).
                    Toggle(L10n.menuViewSnap.key, isOn: Binding(get: { app.snaps }, set: { _ in app.toggleSnap() }))
                        .keyboardShortcut(MenuKeys.snap)
                    Divider()
                    // It has Command in its keys, so it can be off (probe K1 is about plain keys).
                    Button(app.loudnessItem.title.key) { app.key?.toggleLoudness() }
                        .keyboardShortcut(MenuKeys.loudnessMeter).disabled(!app.loudnessItem.enabled)
                    Button(app.inspectorItem.title.key) { app.key?.run(.toggleInspector) }
                        .keyboardShortcut(MenuKeys.inspector).disabled(!app.inspectorItem.enabled)
                }
                // The Edit group replaces the system items, so Delete has Backspace (probe E6).
                CommandGroup(replacing: .pasteboard) {
                    ForEach(TimelineCommand.pasteboardItems, id: \.command) { item in menuButton(item) }
                    Divider()
                    ForEach(TimelineCommand.rippleItems, id: \.command) { item in menuButton(item) }
                    Divider()
                    ForEach(TimelineCommand.editItems, id: \.command) { item in menuButton(item) }
                    Button(L10n.menuEditHeal.key) { app.timeline(.heal) }.disabled(app.key?.isOn(.heal) != true)
                }
                // Every marker key is one that a text field uses: never disabled (probe K1).
                CommandMenu(L10n.menuMarkers.key) {
                    ForEach(TimelineCommand.markerItems, id: \.command) { item in menuButton(item) }
                }
                // No CommandGroup for Undo and Redo: the default items send undo: and redo: along
                // the responder chain, so a focused text field keeps its typing undo (P12).
                CommandMenu(L10n.menuTrack.key) {
                    windowButton(.addTrack).disabled(app.key?.canEdit != true)
                    // `.disabled` on a Menu has no effect in the menu bar: a disabled state is a
                    // disabled item, not an empty submenu.
                    if let key = app.key, key.canEdit {
                        Menu(L10n.menuTrackAddCall.key) { CallTracksItems(model: key) }
                    } else {
                        Button(L10n.menuTrackAddCall.key) {}.disabled(true)
                    }
                    // Its key is one that a text field uses: never disabled (probe K1).
                    ForEach(TimelineCommand.trackItems, id: \.command) { item in menuButton(item) }
                    if let key = app.key, key.canEdit, !key.roleMenuTracks.isEmpty {
                        Menu(L10n.menuTrackRole.key) { RoleItems(model: key, headerRow: nil) }
                    } else {
                        Button(L10n.menuTrackRole.key) {}.disabled(true)
                    }
                    Toggle(
                        L10n.menuTrackMonitor.key,
                        isOn: Binding(get: { app.key?.listensSelection == true }, set: { _ in app.key?.toggleListen() })
                    )
                    .keyboardShortcut(MenuKeys.monitorTrack).disabled(app.key?.canListen != true)
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
                // One Group: a commands builder takes at most 10 items.
                Group {
                    CommandMenu(L10n.menuTools.key) {
                        ForEach(TimelineCommand.toolItems, id: \.command) { item in menuButton(item) }
                        Divider()
                        Button(L10n.menuToolsDuck.key) { app.timeline(.duck) }.disabled(app.key?.isOn(.duck) != true)
                        Divider()
                        let split = TimelineCommand.splitStereoItem
                        Button(split.title.key) { app.timeline(split.command) }
                            .keyboardShortcut(split.key, modifiers: split.modifiers)
                            .disabled(app.key?.isOn(split.command) != true)
                    }
                    CommandGroup(before: .windowList) {
                        Button(L10n.menuWindowStart.key) { app.showStart() }.keyboardShortcut(MenuKeys.startWindow)
                    }
                    // The standard panel shows "Version <short version> (<source commit>)". A build with
                    // no bundle (`swift run`) has no DirigibleCommit and shows the standard text.
                    CommandGroup(replacing: .appInfo) {
                        Button(L10n.menuAppAbout.key) {
                            let commit = Bundle.main.object(forInfoDictionaryKey: "DirigibleCommit") as? String
                            NSApp.orderFrontStandardAboutPanel(options: commit.map { [.version: $0] } ?? [:])
                        }
                    }
                    // No key: Command-? stays with the Help search field of macOS. Report a Problem...
                    // is a group of its own under the guide.
                    CommandGroup(replacing: .help) {
                        Button(L10n.menuHelpGuide.key) { app.openGuide() }
                        Divider()
                        Button(L10n.menuHelpReport.key) { app.reportProblem() }
                    }
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
                        // It has Command, so it can be off with no take audio or during a take.
                        if group == 2 {
                            Button(L10n.menuTransportTakeTime.key) { app.key?.startTakeTime() }
                                .keyboardShortcut(MenuKeys.takeTime).disabled(app.key?.canGoToTakeTime != true)
                        }
                    }
                    Divider()
                    ForEach(TimelineCommand.gainPointSeekItems, id: \.command) { item in menuButton(item) }
                    Divider()
                    speedMenu
                }
            }
    }

    /// Transport > Playback Speed (decision 0052): the plain-key items, never disabled, then one
    /// radio item per speed. The radio items are off when the speed unit does not load.
    private var speedMenu: some View {
        Menu(L10n.menuTransportSpeed.key) {
            // The keys stay the typed characters: with the automatic localization, AppKit moved ">"
            // and "<" to ":" and ";" of the Spanish layout (A3 on-screen check).
            ForEach(SpeedMenu.items, id: \.change) { item in
                Button(item.title.key) { app.speed(item.change) }
                    .keyboardShortcut(item.key.key, modifiers: item.key.modifiers, localization: .custom)
            }
            Divider()
            ForEach(Speed.allCases, id: \.self) { speed in
                Toggle(
                    speedText(speed),
                    isOn: Binding(
                        get: { app.key?.shown.speed == speed }, set: { _ in app.key?.speed(.set(speed)) })
                )
                .disabled(app.key?.shown.canChangeSpeed != true)
            }
        }
    }

    /// A window action: the toolbar item of the command calls the same `run(_:)` (decision 0023).
    private func windowButton(_ command: WindowCommand) -> some View {
        let item = command.menuItem
        return Button(item.title.key) { app.key?.run(command) }.keyboardShortcut(item.key)
    }

    /// Each timeline item reads `isOn`, so one rule turns the items off (probe K1 keeps the items whose key a
    /// field uses on).
    private func menuButton(_ item: TimelineCommand.MenuItem) -> some View {
        Button((app.levelTitle(item.command, for: app.key) ?? item.title).key) { app.timeline(item.command) }
            .keyboardShortcut(item.key, modifiers: item.modifiers, localization: item.command.keyLocalization)
            .disabled(app.key?.isOn(item.command) == false)
    }
}
