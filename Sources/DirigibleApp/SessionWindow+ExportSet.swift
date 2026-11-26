import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// The question before a split export replaces files: the set that waits, the items at its targets
/// that the user must confirm, and the older files of the prefix that stay (decision 0067).
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
/// prefix that stay. Cancel is the first button and the default, so Return cancels. Replace is
/// destructive and has no key.
@MainActor func replaceQuestion(_ set: ReplaceParts) -> NSAlert {
    replaceQuestion(names: set.names, folder: set.split.folder, old: set.old)
}

/// The replace sheet of a set in `folder`: the question, the first five of the sorted `names`, and the older
/// files of the prefix that stay.
@MainActor func replaceQuestion(names: [String], folder url: URL, old: [URL]) -> NSAlert {
    let folder = url.path(percentEncoded: false)
    let alert = NSAlert()
    alert.messageText =
        names.count == 1
        ? L10n.alertExportReplaceOne.format(folder) : L10n.alertExportReplaceMany.format(names.count, folder)
    let kept = old.isEmpty ? "" : "\n\n" + L10n.oldFilesText(old.map(\.lastPathComponent))
    alert.informativeText = L10n.firstNames(names) + kept
    addReplaceButtons(to: alert, confirm: L10n.alertExportReplaceConfirm)
    return alert
}

/// The buttons of a question that replaces an item: Cancel is the first button and the default, so
/// Return cancels, and the destructive `confirm` has no key.
@MainActor func addReplaceButtons(to alert: NSAlert, confirm: L10n) {
    let cancel = alert.addButton(withTitle: L10n.alertCancel.text)
    cancel.keyEquivalent = "\r"
    alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
    alert.addButton(withTitle: confirm.text).hasDestructiveAction = true
    // A button has one key and Return is the key of Cancel, so a transparent button presses Cancel at Esc
    // in each language.
    let escape = NSButton(frame: .zero)
    escape.keyEquivalent = "\u{1b}"
    escape.isTransparent = true
    // The parent lists the cell of a button in its accessibility children, so the cell needs the flag too.
    escape.setAccessibilityElement(false)
    escape.cell?.setAccessibilityElement(false)
    escape.target = cancel
    escape.action = #selector(NSButton.performClick(_:))
    alert.window.contentView?.addSubview(escape)
}

/// The text of the progress sheet: the place of the file in hand for a split export, else "Exporting...".
func exportSheetTitle(_ file: ExportPartsProgress?) -> String {
    file.map { L10n.sheetExportFile.format($0.number, $0.count, $0.name) } ?? L10n.sheetExportTitle.text
}

extension SessionWindow {
    /// The split export of the save panel. It lists the targets and the older files off the main
    /// actor. An item at a target gives the replace sheet; else the set starts. `exportStep` is `.starting`
    /// until the set ends or the user cancels, so no second export starts.
    func runSet(_ source: ExportSource, _ options: ExportOptions, _ split: SplitTarget, _ studio: Studio) async {
        defer { if exportStep == .starting { exportStep = nil } }
        let targets = exportPartTargets(
            studio.session, range: source.range, by: split.kind, options: options, folder: split.folder,
            prefix: split.prefix
        ).targets
        guard !targets.isEmpty else {
            alert = .error(.exportParts(.noPoint(split.kind, source.range)))
            return
        }
        guard let set = await replacements(source, options, split, targets: targets) else {
            await startSet(source, options, split, replacing: [:], studio)
            return
        }
        guard let window, await replaceQuestion(set).beginSheetModal(for: window) == .alertSecondButtonReturn,
            let studio = idleStudio
        else { return }
        await startSet(source, options, split, replacing: set.existing, studio)
    }

    /// The question before the set, read off the main actor: the items at the targets and the older
    /// files of the prefix. Nil when no item is at a target.
    func replacements(
        _ source: ExportSource, _ options: ExportOptions, _ split: SplitTarget, targets: [ExportPartTarget]
    ) async -> ReplaceParts? {
        let existing = await confirmations(of: targets.map(\.url))
        guard !existing.isEmpty else { return nil }
        let old = await olderFiles(
            split, format: options.format, besides: Set(targets.map(\.url.lastPathComponent)))
        return ReplaceParts(source: source, options: options, split: split, existing: existing, old: old)
    }

    func showInFinder(_ files: [URL]) { app?.reveal(files) }

    /// Keeps the result of a set for its banners, and tells VoiceOver that a finished set ended.
    private func showSet(_ set: ExportSetShown) {
        exportSet = set
        if let text = set.doneText { chrome?.announce(text, .medium) }
    }

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
                source, by: split.kind, options: options, folder: split.folder, prefix: split.prefix,
                replacing: replacing)
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
        let warnings = files.compactMap {
            ChapterWarningsShown(
                result.droppedChapters(of: $0),
                imagesOmitted: $0.result.chapterImagesOmitted,
                titleMissing: ExportText.lacksTitleTag(session.forPart($0.part), format: format),
                file: $0.url.lastPathComponent, revision: revision)
        }
        let faulty = files.filter { !$0.result.faults.isEmpty }
        showSet(
            ExportSetShown(
                files: files.map(\.url), count: files.count, loudness: files.compactMap(\.result.loudness), old: old,
                faulty: !faulty.isEmpty, warnings: warnings, dropped: result.dropped, revision: revision))
        guard !faulty.isEmpty else { return }
        let faults = faulty.reduce(into: [FileID: MediaFault]()) { $0.merge($1.result.faults) { first, _ in first } }
        alert = .exportedSet(
            media: faults.keys.map { session.files[$0]?.path ?? $0.rawValue }.sorted(),
            parts: faulty.map(\.url.lastPathComponent))
    }
}

extension SessionWindow {
    /// The preset set of the preset sheet (decision 0080): the check of its targets, the replace sheet when an
    /// item is at a target, then `Studio.export(presets:)`. `exportStep` is `.starting` until the set starts or
    /// the user cancels. A stop shows the count banner, a fault its alert, and a finish the done banner.
    func runPresetSet(
        _ source: ExportSource, _ presets: [(ref: PresetRef, options: PresetOptions)], _ target: PresetFolder,
        _ studio: Studio
    ) async {
        defer { if exportStep == .starting { exportStep = nil } }
        let urls: [URL]
        do throws(ExportPresetsError) {
            urls = try presetTargets(
                presets, folder: target.folder, prefix: target.prefix, sessionRate: studio.session.sampleRate
            ).map(\.url)
        } catch {
            alert = .error(.exportPresets(error))
            return
        }
        let existing = await confirmations(of: urls)
        if !existing.isEmpty {
            let names = existing.keys.map(\.lastPathComponent).sorted()
            guard let window,
                await replaceQuestion(names: names, folder: target.folder, old: []).beginSheetModal(for: window)
                    == .alertSecondButtonReturn, idleStudio === studio
            else { return }
        }
        // `Studio.export` sets its job before its first suspension: the progress takes the place of the step.
        exportStep = nil
        recordRefusal = nil
        clearExportBanners()
        defer { recordRefusal = nil }
        let (revision, session) = (studio.sessionRevision, studio.session)
        do throws(StudioError) {
            let files = try await studio.export(
                presets: presets, source: source, folder: target.folder, prefix: target.prefix, replacing: existing,
                introTitle: L10n.exportChapterIntro.text)
            // A finished set has one file for each preset, in preset order.
            let warnings = zip(files, presets).compactMap { file, preset in
                ChapterWarningsShown(
                    file.result.droppedChapters, imagesOmitted: file.result.chapterImagesOmitted,
                    titleMissing: ExportText.lacksTitleTag(session, format: preset.options.format),
                    file: file.url.lastPathComponent, revision: revision)
            }
            let faulty = files.filter { !$0.result.faults.isEmpty }
            showSet(
                ExportSetShown(
                    files: files.map(\.url), count: files.count, loudness: files.compactMap(\.result.loudness),
                    old: [], faulty: !faulty.isEmpty, warnings: warnings, revision: revision))
            guard !faulty.isEmpty else { return }
            let faults = faulty.reduce(into: [FileID: MediaFault]()) {
                $0.merge($1.result.faults) { first, _ in first }
            }
            alert = .exportedSet(media: paths(of: faults, in: session), parts: faulty.map(\.url.lastPathComponent))
        } catch .exportPresets(.stopped(let stop)) where stop.error == .cancelled {
            exportSet = ExportSetShown(
                files: stop.written.map(\.url), count: stop.written.count + stop.remaining.count, loudness: [],
                old: [], revision: revision)
        } catch {
            alert = .error(error)
        }
    }
}

/// The items at `urls`, each as the panel or the sheet confirms it. It reads the disk.
@concurrent private func confirmations(of urls: [URL]) async -> [URL: ConfirmedFile] {
    urls.reduce(into: [:]) { confirmed, url in confirmed[url] = ConfirmedFile(at: url) }
}

/// The older files of the prefix that are not in `names`. It reads the folder.
@concurrent private func olderFiles(_ split: SplitTarget, format: ExportFormat, besides names: Set<String>) async
    -> [URL]
{
    oldPartFiles(in: split.folder, prefix: split.prefix, format: format, besides: names)
}
