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
                    Button(L10n.menuFileNew.key) { app.newSession() }.keyboardShortcut("n")
                    Button(L10n.menuFileOpen.key) { app.showOpenPanel() }.keyboardShortcut("o")
                    Menu(L10n.menuFileOpenRecent.key) {
                        ForEach(app.recent, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent) { app.open(url) }
                        }
                    }
                }
                // No CommandGroup for Undo and Redo: the default items send undo: and redo: along
                // the responder chain, so a focused text field keeps its typing undo (P12).
                CommandMenu(L10n.menuTrack.key) {
                    Button(L10n.menuTrackAdd.key) { app.key?.addTrack() }
                        .keyboardShortcut("n", modifiers: [.command, .option])
                        .disabled(app.key?.canEdit != true)
                }
                CommandMenu(L10n.menuRecord.key) {
                    Button(L10n.menuRecordStart.key) { Task { await app.key?.record() } }
                        .keyboardShortcut("r").disabled(app.key?.canRecord != true)
                    Button(L10n.menuRecordStop.key) { Task { await app.key?.stop() } }
                        .keyboardShortcut(".").disabled(app.key?.canStop != true)
                    Button(L10n.menuRecordRetry.key) { Task { await app.key?.retry() } }
                        .keyboardShortcut("r", modifiers: [.command, .option]).disabled(app.key?.canRetry != true)
                }
            }
    }
}
