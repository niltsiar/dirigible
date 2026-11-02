import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// The question before a split export replaces files: the set that waits, the items at its targets
/// that the user must confirm, and the older files of the stem that stay (decision 0067).
struct ReplaceParts: Hashable {
    let source: ExportSource
    let options: ExportOptions
    let split: SplitTarget
    let existing: [URL: ConfirmedFile]
    let old: [URL]

    /// The names of the items at the targets, sorted.
    var names: [String] { existing.keys.map(\.lastPathComponent).sorted() }
}

/// The replace sheet (decision 0067): the question, the first five names, and the older files of the
/// stem that stay. Cancel is the first button and the default, so Return cancels. Replace is
/// destructive and has no key.
@MainActor func replaceQuestion(_ set: ReplaceParts) -> NSAlert {
    let names = set.names
    let folder = set.split.folder.path(percentEncoded: false)
    let alert = NSAlert()
    alert.messageText =
        names.count == 1
        ? L10n.alertExportReplaceOne.format(folder) : L10n.alertExportReplaceMany.format(names.count, folder)
    let kept = set.old.isEmpty ? "" : "\n\n" + L10n.oldFilesText(set.old.map(\.lastPathComponent))
    alert.informativeText = L10n.firstNames(names) + kept
    let cancel = alert.addButton(withTitle: L10n.alertCancel.text)
    cancel.keyEquivalent = "\r"
    alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
    alert.addButton(withTitle: L10n.alertExportReplaceConfirm.text).hasDestructiveAction = true
    // A button has one key and Return is the key of Cancel, so a transparent button presses Cancel at Esc
    // in each language.
    let escape = NSButton(frame: .zero)
    escape.keyEquivalent = "\u{1b}"
    escape.isTransparent = true
    escape.target = cancel
    escape.action = #selector(NSButton.performClick(_:))
    alert.window.contentView?.addSubview(escape)
    return alert
}

/// The text of the progress sheet: the place of the file in hand for a split export, else "Exporting...".
func exportSheetTitle(_ file: ExportPartsProgress?) -> String {
    file.map { L10n.sheetExportFile.format($0.number, $0.count, $0.name) } ?? L10n.sheetExportTitle.text
}

extension SessionWindow {
    /// The split export of the save panel. It lists the targets and the older files off the main
    /// actor. An item at a target gives the replace sheet; else the set starts. `exportStep` is `.starting`
    /// until the set ends or the user cancels, so no second export starts.
    func runSet(_ source: ExportSource, _ target: ExportTarget, _ studio: Studio) async {
        guard let split = target.split else { return }
        defer { if exportStep == .starting { exportStep = nil } }
        let targets = exportPartTargets(
            studio.session, range: source.range, by: split.kind, options: target.options, folder: split.folder,
            stem: split.stem
        ).targets
        guard !targets.isEmpty else {
            alert = .error(.exportParts(.noPoint(split.kind, source.range)))
            return
        }
        guard let set = await replacements(source, target, split, targets: targets) else {
            await startSet(source, target.options, split, replacing: [:], studio)
            return
        }
        guard let window, await replaceQuestion(set).beginSheetModal(for: window) == .alertSecondButtonReturn,
            let studio = idleStudio
        else { return }
        await startSet(source, target.options, split, replacing: set.existing, studio)
    }

    /// The question before the set, read off the main actor: the items at the targets and the older
    /// files of the stem. Nil when no item is at a target.
    func replacements(
        _ source: ExportSource, _ target: ExportTarget, _ split: SplitTarget, targets: [ExportPartTarget]
    ) async -> ReplaceParts? {
        let existing = await confirmations(of: targets.map(\.url))
        guard !existing.isEmpty else { return nil }
        let old = await olderFiles(
            split, format: target.options.format, besides: Set(targets.map(\.url.lastPathComponent)))
        return ReplaceParts(source: source, options: target.options, split: split, existing: existing, old: old)
    }

    func showInFinder(_ files: [URL]) { app?.reveal(files) }

    /// Runs the set. A stop with no error of a part shows the count banner, a fault shows its alert
    /// with the count, and a clean finish shows the done banner.
    private func startSet(
        _ source: ExportSource, _ options: ExportOptions, _ split: SplitTarget, replacing: [URL: ConfirmedFile],
        _ studio: Studio
    ) async {
        // `Studio.export` sets its job before its first suspension: the progress takes the place of the step.
        exportStep = nil
        recordRefusal = nil
        clearExportBanners()
        defer { recordRefusal = nil }
        let (revision, session) = (studio.sessionRevision, studio.session)
        do throws(StudioError) {
            let result = try await studio.export(
                source, by: split.kind, options: options, folder: split.folder, stem: split.stem, replacing: replacing)
            let written = Set(result.files.map(\.url.lastPathComponent))
            let old = await olderFiles(split, format: options.format, besides: written).map(\.lastPathComponent)
            show(result, old: old, session: session, format: options.format, revision: revision)
        } catch .exportParts(.stopped(let stop)) where stop.error == .cancelled {
            let count = stop.written.count + stop.remaining.count
            exportSet = ExportSetShown(
                files: stop.written.map(\.url), count: count, loudness: [], old: [], revision: revision)
        } catch {
            alert = .error(error)
        }
    }

    /// The banners of a finished set, or the alert of the files that rendered as silence.
    private func show(
        _ result: ExportPartsResult, old: [String], session: Session, format: ExportFormat, revision: Int
    ) {
        let files = result.files
        let missing = files.first { ExportText.lacksTitleTag(session.forPart($0.part), format: format) }
        chapterWarnings = ChapterWarningsShown(
            files.flatMap(\.result.droppedChapters), imagesOmitted: files.contains { $0.result.chapterImagesOmitted },
            titleMissing: missing != nil, file: (missing ?? files[0]).url.lastPathComponent, revision: revision)
        exportSet = ExportSetShown(
            files: files.map(\.url), count: files.count, loudness: files.compactMap(\.result.loudness), old: old,
            revision: revision)
        let faulty = files.filter { !$0.result.faults.isEmpty }
        guard !faulty.isEmpty else { return }
        let faults = faulty.reduce(into: [FileID: MediaFault]()) { $0.merge($1.result.faults) { first, _ in first } }
        alert = .exportedSet(
            media: faults.keys.map { session.files[$0]?.path ?? $0.rawValue }.sorted(),
            parts: faulty.map(\.url.lastPathComponent))
    }
}

/// The items at `urls`, each as the panel or the sheet confirms it. It reads the disk.
@concurrent private func confirmations(of urls: [URL]) async -> [URL: ConfirmedFile] {
    urls.reduce(into: [:]) { confirmed, url in confirmed[url] = ConfirmedFile(at: url) }
}

/// The older files of the stem that are not in `names`. It reads the folder.
@concurrent private func olderFiles(_ split: SplitTarget, format: ExportFormat, besides names: Set<String>) async
    -> [URL]
{
    oldPartFiles(in: split.folder, stem: split.stem, format: format, besides: names)
}
