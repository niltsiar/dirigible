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

/// Moves `url` to the Trash with `trash`, off the main actor.
@concurrent nonisolated func moveToTrash(_ url: URL, using trash: @Sendable (URL) throws -> Void) async throws {
    try trash(url)
}

/// The Replace question of Save as Template (T-Q4): it names the template, Cancel is the default, and Replace
/// moves the old template to the Trash before the save.
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
enum TemplateMenu {
    case saveAs, showInFinder

    static let group: [TemplateMenu] = [.saveAs, .showInFinder]

    var title: L10n {
        switch self {
        case .saveAs: .menuFileSaveTemplate
        case .showInFinder: .menuFileShowTemplates
        }
    }
}
