import AppKit
import DirigibleAudio
import SwiftUI

/// The control of the start window that has the keyboard focus.
enum StartField: Hashable {
    case name, list
}

/// One recent session: the package name, the name of its folder, and whether the check found it.
/// `exists` is a hint only: a denied path also gives false.
struct RecentRow: Identifiable, Sendable {
    let url: URL
    let exists: Bool
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
}

/// One scan of the folder of new sessions: the first free name and the text of the folder.
struct FolderScan: Sendable {
    let folder: URL
    let name: String
    let text: String
}

/// The name of a new session: the file name of its package with no ".dirigible" (decision 0027).
struct SessionName {
    /// Why a name cannot be a session.
    enum Refusal: Error, Equatable {
        case empty, character, dot, long
    }

    /// 255 bytes of a file name less the 10 bytes of ".dirigible".
    static let byteLimit = 245
    let text: String

    init(_ text: String) throws(Refusal) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .empty }
        // Finder shows ":" as "/", and "/" separates the path.
        if text.contains("/") || text.contains(":") { throw .character }
        // Finder hides a name that starts with a period.
        if text.hasPrefix(".") { throw .dot }
        if text.utf8.count > Self.byteLimit { throw .long }
        self.text = text
    }
}

extension SessionName.Refusal {
    /// The line under the name field. An empty name needs no reason.
    var message: L10n? {
        switch self {
        case .empty: nil
        case .character: .startNameErrorCharacter
        case .dot: .startNameErrorDot
        case .long: .startNameErrorLong
        }
    }
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
    /// The folder of new sessions. Change… sets it.
    private(set) var folder: URL
    /// Why the name cannot be a session, or nil. Create is off while it is set.
    var refusal: SessionName.Refusal? {
        do throws(SessionName.Refusal) {
            _ = try SessionName(name)
            return nil
        } catch {
            return error
        }
    }
    /// The recent sessions, from `AppDelegate.recent`, in their order.
    private(set) var rows: [RecentRow] = []
    /// True when the rows came: the view says "No recent sessions." only then.
    private(set) var rowsLoaded = false
    private(set) var selection: URL?
    /// The one scan of the recent list (plan gate, item 1).
    @ObservationIgnored private(set) var rowsTask: Task<Void, Never>?
    /// The task of the folder scan and of the last Create, for the tests.
    @ObservationIgnored private(set) var scanTask: Task<Void, Never>?
    @ObservationIgnored private(set) var createTask: Task<Void, Never>?
    /// True after a user edit of the name: a scan result keeps the typed name.
    @ObservationIgnored private var edited = false
    /// True after a user act (an edit, a selection, a focus change, New Session): a rows result
    /// keeps the focus (plan gate, item 1).
    @ObservationIgnored private var focusPinned = false
    @ObservationIgnored private weak var app: AppDelegate?

    init(app: AppDelegate, folder: URL) {
        self.app = app
        self.folder = folder
        scan()
    }

    /// Starts the scan of the folder: the first free name and the folder text.
    private func scan() {
        guard let app else { return }
        let (folder, format, exists) = (folder, app.nameFormat, app.exists)
        scanTask = Task { apply(scan: await scanFolder(folder, format: format, exists: exists)) }
    }

    /// A user edit of the name field. SwiftUI also sets the text with no change when the field
    /// takes the focus, and that is not an edit.
    func edit(_ text: String) {
        guard text != name else { return }
        name = text
        edited = true
        pin(.name)
    }

    /// A scan of a folder that is not the folder of the form any more changes nothing (plan gate,
    /// item 1).
    func apply(scan: FolderScan) {
        guard scan.folder == folder else { return }
        folderText = scan.text
        if !edited { name = scan.name }
    }

    /// Makes the package and opens it. The open closes the start window. An error shows its
    /// alert and keeps the window and the name. A refused name does nothing. The app makes only
    /// its default folder.
    func create() {
        guard !creating, let app, let session = try? SessionName(name) else { return }
        creating = true
        let (folder, exists) = (folder, app.exists)
        let makesFolder = folder.path == app.defaultFolder?.path
        let url = folder.appending(path: "\(session.text).dirigible")
        createTask = Task {
            if makesFolder { await makeFolder(folder, exists: exists) }
            guard let error = await app.createSession(at: url) else { return }
            creating = false
            app.showError(error)
        }
    }

    /// Starts the scan of the recent list, unless one runs. Until the rows come, the focus is in
    /// the list when the recent list has a URL.
    func loadRows() {
        guard rowsTask == nil, let app else { return }
        let (urls, exists) = (app.recent, app.exists)
        if !focusPinned { focus = urls.isEmpty ? .name : .list }
        rowsTask = Task {
            let rows = await scanRecent(urls, exists: exists)
            rowsTask = nil
            // A close cancels the task. The scan has no cancellation point, so the check is here.
            guard !Task.isCancelled else { return }
            self.rows = rows
            rowsLoaded = true
            selection = rows.first(where: \.exists)?.url
            if !focusPinned { focus = selection == nil ? .name : .list }
        }
    }

    /// The `windowWillClose(_:)` of the start window.
    func close() { rowsTask?.cancel() }

    /// A user change of the selection in the list.
    func select(_ url: URL?) {
        guard url != selection else { return }
        selection = url
        pin(.list)
    }

    /// A focus change in the view. Only a click or a key of the user pins it: the echo of a
    /// focus that the model set, and the first focus that AppKit gives a window, do not.
    func focusChanged(to field: StartField, by event: NSEvent?) {
        guard field != focus, let event, [.leftMouseDown, .keyDown].contains(event.type) else { return }
        pin(field)
    }

    /// Moves the focus, and no later result moves it.
    func pin(_ field: StartField) {
        focus = field
        focusPinned = true
    }

    /// Opens a recent session, also a row that shows "Not found": the check cannot tell a denied
    /// path from a missing one, so the session window shows the error of the open (code gate 1,
    /// item 1). The open closes the start window. While a Create runs, it does nothing: the
    /// double-click and Return in the list come here (code gate 1, item 4).
    func open(_ url: URL) async {
        guard !creating else { return }
        await app?.open(url)
    }

    /// Return in the list.
    func openSelection() {
        guard let selection else { return }
        Task { await open(selection) }
    }

    /// Change…: the chosen folder is the folder of new sessions from now on. A cancel changes
    /// nothing.
    func changeFolder() {
        guard !creating, let app, let window = app.start?.window else { return }
        app.chooseFolder(window) { [weak self] url in
            guard let self, let url else { return }
            app.defaults?.set(url.path, forKey: AppDelegate.folderKey)
            folder = url
            scan()
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

/// Checks that each recent package exists. It reads the file system, so it runs off the main
/// actor.
@concurrent nonisolated func scanRecent(_ urls: [URL], exists: @Sendable (URL) -> Bool) async -> [RecentRow] {
    urls.map { RecentRow(url: $0, exists: exists($0)) }
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

    /// The close button and Command-W do nothing while a Create runs (code gate 1, item 4). The
    /// open of the new session closes the window with `close()`, which does not ask.
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.creating }

    func windowWillClose(_ notification: Notification) {
        model.close()
        app?.startDidClose()
    }
}
