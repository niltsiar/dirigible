import AppKit
import DirigibleAudio
import SwiftUI

/// The control of the start window that has the keyboard focus.
enum StartField: Hashable {
    case name
}

/// One scan of the folder of new sessions: the first free name and the text of the folder.
struct FolderScan: Sendable {
    let folder: URL
    let name: String
    let text: String
}

/// The state of the start window (decision 0027). `StartView` reads it and calls it.
@Observable @MainActor final class StartModel {
    /// The name of the new session.
    private(set) var name = ""
    /// The folder of new sessions, for example "Music › Dirigible".
    private(set) var folderText = ""
    var focus: StartField? = .name
    /// True from a Create until its error: a second Create does nothing (plan gate, item 3).
    private(set) var creating = false
    let folder: URL
    /// The task of the folder scan and of the last Create, for the tests.
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?
    @ObservationIgnored private(set) var createTask: Task<Void, Never>?
    /// True after a user edit of the name: a scan result keeps the typed name.
    @ObservationIgnored private var edited = false
    @ObservationIgnored private weak var app: AppDelegate?

    init(app: AppDelegate, folder: URL) {
        self.app = app
        self.folder = folder
        let (format, exists) = (app.nameFormat, app.exists)
        scanTask = Task { apply(scan: await scanFolder(folder, format: format, exists: exists)) }
    }

    /// A user edit of the name field. SwiftUI also sets the text with no change when the field
    /// takes the focus, and that is not an edit.
    func edit(_ text: String) {
        guard text != name else { return }
        name = text
        edited = true
    }

    func apply(scan: FolderScan) {
        folderText = scan.text
        if !edited { name = scan.name }
    }

    /// Makes the package and opens it. The open closes the start window. An error shows its
    /// alert and keeps the window and the name. The app makes only its default folder.
    func create() {
        guard !creating, let app else { return }
        creating = true
        let (folder, exists) = (folder, app.exists)
        let makesFolder = folder.path == app.defaultFolder?.path
        let url = folder.appending(path: "\(name).dirigible")
        createTask = Task {
            if makesFolder { await makeFolder(folder, exists: exists) }
            guard let error = await app.createSession(at: url) else { return }
            creating = false
            app.showError(error)
        }
    }

    func openOther() {
        guard !creating else { return }
        app?.showOpenPanel()
    }
}

/// The first free name ("Episode N" with no package of that name) and the Finder names of the
/// folder and its parent. It reads the file system, so it runs off the main actor.
@concurrent nonisolated func scanFolder(
    _ folder: URL, format: @Sendable (Int) -> String, exists: @Sendable (URL) -> Bool
) async -> FolderScan {
    var number = 1
    while exists(folder.appending(path: "\(format(number)).dirigible")) { number += 1 }
    let names = [folder.deletingLastPathComponent(), folder].map { FileManager.default.displayName(atPath: $0.path) }
    return FolderScan(folder: folder, name: format(number), text: names.joined(separator: " › "))
}

/// Makes the folder, one level only, when it is missing. A failure shows later as the error of
/// the Create.
@concurrent nonisolated func makeFolder(_ folder: URL, exists: @Sendable (URL) -> Bool) async {
    guard !exists(folder) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
}

/// The start window (decision 0027) and its `NSWindowDelegate`. `AppDelegate` owns it while it
/// shows. It is a plain `NSWindow`, not an `UndoRoutingWindow`, so a plain key goes to its text
/// and never to a transport. It is not restorable, and a close drops it.
@MainActor final class StartWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    let model: StartModel
    private weak var app: AppDelegate?

    init(app: AppDelegate, folder: URL) {
        self.app = app
        model = StartModel(app: app, folder: folder)
        super.init()
        let window = NSWindow(contentViewController: NSHostingController(rootView: StartView(model: model)))
        // The Xcode look: the view draws the title, and the window moves by its background.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = L10n.startTitle.text
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
    }

    func show() { window?.makeKeyAndOrderFront(nil) }

    /// Through `NSWindow.close()`, so `windowWillClose(_:)` runs.
    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        app?.startDidClose()
    }
}
