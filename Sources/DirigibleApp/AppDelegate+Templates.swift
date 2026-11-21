import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation

/// The sheets and the Trash call of Save as Template (decision 0079). Tests give their own.
struct TemplatePanels {
    /// The name sheet with the line of what the template keeps, and the answer: the name, or nil for Cancel.
    var chooseName: @MainActor (NSWindow, String, @escaping @MainActor (String?) -> Void) -> Void = {
        TemplateNameSheet(keeps: $1).begin(on: $0, done: $2)
    }
    /// The Replace question for the name of an old template, and the answer: true for Replace.
    var confirmReplace: @MainActor (NSWindow, String, @escaping @MainActor (Bool) -> Void) -> Void = {
        window, name, done in
        templateReplaceAlert(name: name).beginSheetModal(for: window) { done($0 == .alertSecondButtonReturn) }
    }
    /// Moves an item to the Trash. It runs off the main actor.
    var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    var renames = TemplateRenames()
}

/// The renames of a Replace: `RENAME_SWAP`, then the two renames of `renameFolder`. Each gives 0 or the errno.
/// They run off the main actor.
struct TemplateRenames: Sendable {
    var swap: @Sendable (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_SWAP)) == 0 ? 0 : errno }
    var exclusive: @Sendable (String, String) -> Int32 = exclusiveRename
    var plain: @Sendable (String, String) -> Int32 = plainRename
}

extension AppDelegate {
    /// The chosen template of the start window, a `String` absolute path. The key never changes its meaning or
    /// its type (decision 0024 P11).
    static let templateKey = "session.template"

    /// The folder of the templates: `Templates` in the default folder, never in a folder that the user chose.
    var templatesFolder: URL? { defaultFolder?.appending(path: "Templates") }

    /// File > Show Templates in Finder: the Templates folder, or the default folder before the first template.
    func showTemplatesInFinder() async {
        guard let folder = templatesFolder, let parent = defaultFolder else { return }
        let exists = exists
        let target = await firstExisting([folder, parent], exists: exists)
        if let target { openURL(target) }
    }
}

/// The template packages of `Templates/`, by name. It reads the file system, so it runs off the main actor.
@concurrent nonisolated func listTemplates(in folder: URL) async -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".dirigible") && !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        .map { folder.appending(path: $0) }
}

/// The first of `urls` that exists. It reads the file system, so it runs off the main actor.
@concurrent nonisolated func firstExisting(_ urls: [URL], exists: @Sendable (URL) -> Bool) async -> URL? {
    urls.first(where: exists)
}

/// The Templates folder, made with its parent when they are missing, and whether `target` exists. It reads
/// and writes the file system, so it runs off the main actor.
@concurrent nonisolated func prepareTemplates(folder: URL, target: URL, exists: @Sendable (URL) -> Bool) async -> Bool {
    if !exists(folder) { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    return exists(target)
}

/// The window key of the old template of a Replace and its lock, off the main actor. The lock keeps each window
/// off the package until it is in the Trash. It throws `.locked` when a window or another process holds it.
@concurrent nonisolated func lockOldTemplate(_ target: URL) async throws(SessionFileError) -> (
    key: URL, lock: PackageLock
) {
    (packageIdentity(target), try PackageLock(target))
}

/// A new folder on the volume of `target` that the system empties, for the new template of a Replace: the swap
/// needs one volume.
@concurrent nonisolated func replacementFolder(for target: URL) async throws(TemplateError) -> URL {
    do {
        return try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    } catch {
        let code = ((error as? CocoaError)?.underlying as? POSIXError)?.code.rawValue ?? EIO
        throw .write(file: target.deletingLastPathComponent().lastPathComponent, errno: code)
    }
}

/// The end of `swapTemplate`.
enum TemplateSwap: Equatable, Sendable {
    case replaced
    /// The old template is at its name again, and the new one is gone.
    case trashFailed
    /// The old template is in the Trash, and the new one stays at this path: its rename to the name failed.
    case newKept(String)
    /// The old template was not at the name, and the rename of the new one failed. The new one is gone.
    case failed(SessionFileError)
}

/// Puts the template `saved` at `target` and moves the old one to the Trash with `trash`, off the main actor,
/// while `lock` holds the old one. `RENAME_SWAP` exchanges the two in one step, and a failed move to the Trash
/// swaps them back. A volume with no swap moves the old template to the Trash, then publishes with
/// `renameFolder`, the claim rename of a volume with no exclusive rename. At the end the folder of `saved` goes,
/// unless it holds a template that is not at the name.
@concurrent nonisolated func swapTemplate(
    _ target: URL, with saved: URL, holding lock: PackageLock, trash: @Sendable (URL) throws -> Void,
    renames: TemplateRenames
) async -> TemplateSwap {
    defer { withExtendedLifetime(lock) {} }
    let folder = saved.deletingLastPathComponent()
    let result: TemplateSwap
    let code = renames.swap(saved.path, target.path)
    if code == 0 {
        if (try? trash(saved)) != nil {
            result = .replaced
        } else {
            let back = renames.swap(saved.path, target.path)
            guard back == 0 else { return .failed(.writeFailed(step: "rename", errno: back)) }
            result = .trashFailed
        }
    } else if code != ENOENT, (try? trash(target)) == nil {
        result = .trashFailed
    } else {
        do throws(SessionFileError) {
            try renameFolder(saved.path, to: target.path, exclusive: renames.exclusive, plain: renames.plain)
            result = .replaced
        } catch {
            if code != ENOENT { return .newKept(saved.path) }
            result = .failed(error)
        }
    }
    try? FileManager.default.removeItem(at: folder)
    return result
}

/// Removes `url`, off the main actor.
@concurrent nonisolated func removeItem(_ url: URL) async {
    try? FileManager.default.removeItem(at: url)
}

/// The Replace question of Save as Template (T-Q4): it names the template, Cancel is the default, and Replace
/// moves the old template to the Trash after the save.
@MainActor func templateReplaceAlert(name: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = L10n.templateReplaceTitle.format(name)
    alert.informativeText = L10n.templateReplaceInfo.text
    addReplaceButtons(to: alert, confirm: .templateReplaceReplace)
    return alert
}

/// What a template keeps: the clips of the session, and the bytes of the files that the new package copies.
struct TemplateKeeps: Equatable, Sendable {
    let clips: Int
    let bytes: Int64

    /// The line under the name field. `table` gives the format of a key: the tests read the tables.
    func text(table: (L10n) -> String = { $0.text }) -> String {
        switch clips {
        case 0: table(.templateSaveKeepsNone)
        case 1: String(format: table(.templateSaveKeepsOne), locale: .current, L10n.bytes(bytes))
        default: String(format: table(.templateSaveKeeps), locale: .current, clips, L10n.bytes(bytes))
        }
    }
}

/// The count and the size of what `episode` keeps. The size is the sum of the files of `episode.filePaths`,
/// so an unused file of the pool adds nothing. It reads the file system, so it runs off the main actor.
@concurrent nonisolated func templateKeeps(of episode: NewEpisode, in package: URL) async -> TemplateKeeps {
    let clips = episode.session.tracks.reduce(0) { $0 + $1.clips.count }
    var bytes: Int64 = 0
    for path in episode.filePaths {
        let size = try? FileManager.default.attributesOfItem(atPath: package.appending(path: path).path)[.size]
        bytes += (size as? NSNumber)?.int64Value ?? 0
    }
    return TemplateKeeps(clips: clips, bytes: bytes)
}

/// The name sheet of Save as Template: a name field and the line of what the template keeps. Save is off while
/// the name is refused. There is no check box (T-Q2).
@MainActor final class TemplateNameSheet: NSObject, NSTextFieldDelegate {
    let alert = NSAlert()
    let field = NSTextField()
    let saveButton: NSButton

    init(keeps: String) {
        alert.messageText = L10n.templateSaveTitle.text
        saveButton = alert.addButton(withTitle: L10n.templateSaveButton.text)
        let cancel = alert.addButton(withTitle: L10n.alertCancel.text)
        cancel.keyEquivalent = "\u{1b}"
        let label = NSTextField(labelWithString: L10n.startName.text)
        let line = NSTextField(wrappingLabelWithString: keeps)
        line.textColor = .secondaryLabelColor
        line.font = .preferredFont(forTextStyle: .callout)
        let row = NSStackView(views: [label, field])
        row.spacing = 8
        let stack = NSStackView(views: [row, line])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        line.widthAnchor.constraint(equalToConstant: 320).isActive = true
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        super.init()
        field.delegate = self
        nameChanged()
    }

    /// Save is on when the name can be a template: 0027, and the bytes of the URL component.
    func nameChanged() {
        saveButton.isEnabled = (try? SessionName(field.stringValue, limit: .template)) != nil
    }

    func controlTextDidChange(_ notification: Notification) { nameChanged() }

    /// Shows the sheet on `window`. `done` gets the name for Save, nil for Cancel.
    func begin(on window: NSWindow, done: @escaping @MainActor (String?) -> Void) {
        alert.beginSheetModal(for: window) { response in
            done(response == .alertFirstButtonReturn ? self.field.stringValue : nil)
        }
        alert.window.makeFirstResponder(field)
    }
}

/// The template group of the File menu, after the Export items (T18).
enum TemplateMenu: CaseIterable {
    case saveAs, showInFinder

    var title: L10n {
        switch self {
        case .saveAs: .menuFileSaveTemplate
        case .showInFinder: .menuFileShowTemplates
        }
    }

    @MainActor func isOn(in app: AppDelegate) -> Bool {
        switch self {
        case .saveAs: app.key?.canSaveTemplate == true
        case .showInFinder: app.templatesFolder != nil
        }
    }

    @MainActor func run(in app: AppDelegate) async {
        switch self {
        case .saveAs: await app.key?.saveAsTemplate()
        case .showInFinder: await app.showTemplatesInFinder()
        }
    }
}
