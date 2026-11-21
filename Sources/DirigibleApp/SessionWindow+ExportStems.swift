import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// The result of the last stem export, for its banners at its session revision (decision 0078).
struct StemsShown: Equatable {
    let folder: URL
    /// The stem files in the folder, in plan order. Empty after a stop.
    let files: [StemFile]
    /// The peak of the mix of the stems; nil when the stems cannot sum over 1.0.
    let mixPeak: Float?
    let stopped: Bool
    let revision: Int

    /// The clip warning comes first: the stems over 0 dBFS, then the mix line, then the folder line.
    /// A stop gives only the stop banner.
    var banners: [WindowBanner] {
        guard !stopped else { return [.stemsStopped] }
        var banners: [WindowBanner] = []
        let clipped = files.filter(\.isOverFullScale).map(\.name)
        if !clipped.isEmpty { banners.append(.stemsClipped(clipped)) }
        if let mixPeak, mixPeak > 1 { banners.append(.stemsMixClipped) }
        banners.append(
            .exportSetDone(files: files.map { folder.appending(path: $0.name) }, low: nil, high: nil, old: []))
        return banners
    }
}

extension SessionWindow {
    /// The scope of File > Export Stems... (decision 0078): the selected tracks, or every track when
    /// none is selected, over the Marks range, or the whole session when the Marks have no range.
    /// Export Selection does not change it.
    private func stemScope(in studio: Studio) -> ExportSource? {
        let session = studio.session
        let selected = timeline.selection.headerTracks(in: session)
        var range = Frames.zero..<session.end
        if let marks = timeline.selection.marks, let start = marks.inPoint, let end = marks.outPoint, start < end {
            range = start..<end
        }
        return ExportSource(range: range, tracks: selected.isEmpty ? nil : Set(selected))
    }

    /// Whether `scope` has a stem now. `stemPlan` is nil for the same scopes at each grouping, title
    /// set, and name limit, so this call has the nil of the run.
    private func hasStem(_ scope: ExportSource, in session: Session) -> Bool {
        session.stemPlan(by: .track, tracks: scope.tracks, range: scope.range, titles: .english, limit: .max) != nil
    }

    /// On when an export can start and the scope has a stem.
    var canExportStems: Bool {
        guard let studio = exportStudio, let scope = stemScope(in: studio) else { return false }
        return hasStem(scope, in: studio.session)
    }

    /// File > Export Stems...: the media check, then the question when a file has a fault, then the
    /// save panel, then `Studio.exportStems`.
    func exportStems() async {
        guard let studio = exportStudio, let scope = stemScope(in: studio), hasStem(scope, in: studio.session)
        else { return }
        await checkMedia(of: scope, then: .stems, in: studio)
    }

    /// The stem save panel as a sheet of the window. An edit that left no stem gives the no-stem
    /// alert in place of the panel. OK runs the export.
    func chooseStems(_ source: ExportSource, _ studio: Studio) {
        guard let window, let app else { return }
        guard hasStem(source, in: studio.session) else {
            exportStep = nil
            alert = .error(.exportStems(.noStem))
            return
        }
        exportStep = .choosing
        app.chooseStemsExport(
            window, L10n.panelStemsDefaultName.format(url.deletingPathExtension().lastPathComponent),
            studio.session.sampleRate, StemSettings(defaults: app.defaults), stemPanelMessage(studio.session, source)
        ) { [weak self] target in
            guard let self, exportStep == .choosing else { return }
            exportStep = nil
            guard let target, let studio = idleStudio else { return }
            Task { await self.runStems(source, target, studio) }
        }
    }

    /// Runs the stem export. A fault shows its alert, a cancel shows the stop banner, and a finish
    /// shows the banners of `StemsShown`. A file with a media fault gives the alert of Export.
    func runStems(_ source: ExportSource, _ target: StemsTarget, _ studio: Studio) async {
        recordRefusal = nil
        clearExportBanners()
        defer { recordRefusal = nil }
        let (revision, session) = (studio.sessionRevision, studio.session)
        do throws(StudioError) {
            let result = try await studio.exportStems(
                by: target.grouping, source: source, titles: .app(), options: target.options, folder: target.folder)
            stemsShown = StemsShown(
                folder: target.folder, files: result.files, mixPeak: result.mixPeak, stopped: false,
                revision: revision)
            if !result.faults.isEmpty { alert = .exported(paths(of: result.faults, in: session), nil) }
        } catch .exportStems(.stopped(.cancelled)) {
            stemsShown = StemsShown(
                folder: target.folder, files: [], mixPeak: nil, stopped: true, revision: revision)
        } catch {
            alert = .error(error)
        }
    }
}
