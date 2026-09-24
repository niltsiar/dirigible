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
            }
    }
}
