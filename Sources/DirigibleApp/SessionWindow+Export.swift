import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// File > Export (the whole mix) and File > Export Selection (the Marks) (decision 0019).
enum ExportKind {
    case session, selection
}

/// A step of Export before the export runs. The running export is `Studio.exportProgress`.
enum ExportStep: Hashable {
    /// The media check of the files that the source reads, off the main actor.
    case checking
    /// The media question: the source and the faults of the files that it reads (decision 0003).
    case asking(ExportSource, [FileID: MediaFault])
    /// The save panel shows.
    case choosing
}

extension SessionWindow {
    /// The studio when an export can start: idle, no pending take, no export step, no export.
    private var exportStudio: Studio? {
        guard exportStep == nil, let studio = idleStudio, studio.pendingTake == nil, studio.exportProgress == nil
        else { return nil }
        return studio
    }

    var canExport: Bool { exportStudio.flatMap { source(of: .session, in: $0) } != nil }
    var canExportSelection: Bool { exportStudio.flatMap { source(of: .selection, in: $0) } != nil }

    /// Import Audio, Export, and Export Selection are off when they cannot run. Their keys have Command, so the
    /// plain-key rule (probe K1) does not apply. During an import, the edit items whose key no text field uses
    /// are off (run 13a, C6). The other items are never off: a field uses their keys (0018 K1).
    func isOn(_ command: TimelineCommand) -> Bool {
        switch command {
        case .export: canExport
        case .exportSelection: canExportSelection
        case .importAudio: canImport
        case .insert, .cutSelectedTracks, .fade, .autoLevel, .autoLevelPerTrack: importJob == nil
        case .zoomBack: timeline.canGoBack
        case .zoomForward: timeline.canGoForward
        default: true
        }
    }

    /// The whole mix from frame 0 to the session end on all tracks, or the Marks on the selected
    /// tracks. Nil when it has no frame.
    func source(of kind: ExportKind, in studio: Studio) -> ExportSource? {
        switch kind {
        case .session:
            return ExportSource(range: .zero..<studio.session.end)
        case .selection:
            guard let selection = timeline.selection.marks?.selection(in: studio.session) else { return nil }
            return ExportSource(range: selection.range, tracks: Set(selection.tracks))
        }
    }

    /// Cmd-E and Shift-Cmd-E: the media check, then the question when a file has a fault, then
    /// the save panel. A take or a close during the check drops its result.
    func export(_ kind: ExportKind) async {
        guard let studio = exportStudio, let source = source(of: kind, in: studio) else { return }
        exportStep = .checking
        let faults = await studio.exportFaults(source) ?? [:]
        guard exportStep == .checking, idleStudio === studio else {
            if exportStep == .checking { exportStep = nil }
            return
        }
        if faults.isEmpty {
            choose(source, studio)
        } else {
            exportStep = .asking(source, faults)
        }
    }

    var isAskingExportQuestion: Bool {
        if case .asking = exportStep { return true }
        return false
    }

    /// The paths of the files of the media question.
    var exportQuestionPaths: [String] {
        guard case .asking(_, let faults) = exportStep, let studio else { return [] }
        return paths(of: faults, in: studio.session)
    }

    /// The media question: Export opens the save panel; Cancel ends the flow.
    func answerExportQuestion(export: Bool) {
        guard case .asking(let source, _) = exportStep else { return }
        exportStep = nil
        guard export, let studio = idleStudio else { return }
        choose(source, studio)
    }

    /// The save panel as a sheet of the window. OK runs the export.
    func choose(_ source: ExportSource, _ studio: Studio) {
        guard let window, let app else { return }
        exportStep = .choosing
        app.chooseExport(
            window, url.deletingPathExtension().lastPathComponent, studio.session.sampleRate,
            ExportSettings(defaults: app.defaults), exportNote(studio.session, source)?.text
        ) { [weak self] target in
            guard let self, exportStep == .choosing else { return }
            exportStep = nil
            guard let target, let studio = idleStudio else { return }
            Task { await self.run(source, target, studio) }
        }
    }

    /// Runs the export. A fault shows its alert, and a cancel shows nothing. A finish with a file
    /// that rendered as silence shows one alert with the files and the loudness report. A clean
    /// finish with a target shows the report in a banner, so no modal alert takes the Record key.
    /// A refused Record shows in the sheet until the end.
    func run(_ source: ExportSource, _ target: ExportTarget, _ studio: Studio) async {
        recordRefusal = nil
        exportReport = nil
        defer { recordRefusal = nil }
        // The file has the session of the export start: an edit during the export does not match it.
        let revision = studio.sessionRevision
        do throws(StudioError) {
            let result = try await studio.export(source, target.options, to: target.url, replacing: target.confirmed)
            if result.faults.isEmpty {
                exportReport = result.loudness.map {
                    ExportReportShown(report: $0, file: target.url.lastPathComponent, revision: revision)
                }
            } else {
                alert = .exported(paths(of: result.faults, in: studio.session), result.loudness)
            }
        } catch .export(.cancelled) {
        } catch {
            alert = .error(error)
        }
    }

    /// The Cancel button of the progress sheet.
    func cancelExport() { studio?.cancelExport() }

    /// The pool path of each file, sorted.
    private func paths(of faults: [FileID: MediaFault], in session: Session) -> [String] {
        faults.keys.map { session.files[$0]?.path ?? $0.rawValue }.sorted()
    }
}
