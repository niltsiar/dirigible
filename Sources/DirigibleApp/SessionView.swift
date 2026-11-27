import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The content of a session window. It reads `SessionWindow` and `Studio` and sends the actions
/// back; it keeps no copy of the take state.
struct SessionView: View {
    /// The minimum content width with no inspector (0023).
    static let minWidth = 720.0

    let model: SessionWindow

    var body: some View {
        let _ = model.countBody()
        content
            // 720 pt keeps the transport and the time display in the toolbar (probe P1c). Each
            // shown pane adds its width.
            .frame(minWidth: model.paneMinimum, minHeight: 360)
            .alert(
                Text(verbatim: model.alert.map(\.text) ?? ""),
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { alert in
                switch alert {
                case .followOverlap:
                    // The default button: Return closes the alert, and the edit does not run again.
                    Button(L10n.alertOK.key) {}
                    Button(L10n.alertFollowTurnOff.key) { model.turnOffFollow(in: alert) }
                // Stop and Close is the default (Return), as Stop and Quit: the user chose Close, and the
                // finalize keeps the audio (HIG). The unsaved Close has no Return: Undo cannot give back
                // the edits that the failed save lost.
                case .confirmStopAndClose:
                    Button(L10n.alertCloseRecordingConfirm.key) { Task { await model.close() } }
                    Button(L10n.alertCancel.key, role: .cancel) {}
                case .confirmUnsavedClose:
                    Button(L10n.alertCloseUnsavedConfirm.key, role: .destructive) { model.closeAnyway() }
                    Button(L10n.alertCancel.key, role: .cancel) { model.cancelUnsavedClose() }
                case .confirmRemoveTracks(let ids):
                    ForEach(removeQuestionButtons, id: \.title) { button in
                        Button(button.title.key, role: button.role) {
                            if button.role == nil { model.confirmRemoveTracks(ids) }
                        }
                    }
                case .confirmRemoveFavorite(let part, _):
                    Button(L10n.alertFavoritesRemoveConfirm.key) { model.confirmRemoveFavorite(part) }
                    Button(L10n.alertCancel.key, role: .cancel) {}
                case .microphone:
                    Button(L10n.alertMicrophoneSettings.key) { model.openPrivacySettings() }
                    Button(L10n.alertCancel.key, role: .cancel) {}
                case .error, .importChain, .exported, .exportedSet, .noUnusedFiles, .transcriptExport,
                    .transcriptImport, .placedWithNoClip, .templateTrash, .templateOpen, .binFileFault:
                    // The default button: Return closes the alert (HIG: Cancel is never the default).
                    Button(L10n.alertOK.key) {}
                    if alert == .error(.archived) { Button(L10n.bannerArchiveUnarchive.key) { model.unarchive() } }
                case .templateNewKept(_, let path), .templateOldKept(_, let path):
                    Button(L10n.alertOK.key) {}
                    Button(L10n.bannerExportSetShow.key) { model.showInFinder([URL(filePath: path)]) }
                case .transcribeFile(_, let request), .transcribeNoData(_, let request):
                    Button(L10n.alertOK.key) {}
                    if let pick = alert.pickButton { Button(pick.key) { model.startWithPickedFile(request) } }
                }
            } message: { alert in
                if let message = alert.message { Text(verbatim: message) }
            }
            // An AppKit sheet, so the close button is off (decision 0048). Only its buttons answer.
            .sheet(isPresented: Binding(get: { model.consent?.phase == .waiting }, set: { _ in })) {
                if let consent = model.consent, let studio = model.studio {
                    ConsentSheet(model: model, consent: consent, sampleRate: studio.session.sampleRate)
                }
            }
            // Only the buttons answer: a set of the binding comes before the action of Export.
            .alert(
                Text(verbatim: L10n.alertExportMissing.format(model.exportQuestionPaths.joined(separator: "\n"))),
                isPresented: Binding(get: { model.isAskingExportQuestion }, set: { _ in })
            ) {
                Button(L10n.alertExportConfirm.key) { model.answerExportQuestion(export: true) }
                Button(L10n.alertCancel.key, role: .cancel) { model.answerExportQuestion(export: false) }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .opening:
            if model.recovering {
                ProgressView(L10n.windowRecovering.key)
            } else {
                ProgressView().accessibilityLabel(Text(L10n.windowOpening.key))
            }
        case .failed(let error):
            VStack(spacing: 12) {
                Text(verbatim: L10n.message(for: error))
                Button(L10n.windowTryAgain.key) { model.open(recovering: model.recovering) }
            }
        case .open(let studio), .closing(let studio?):
            HStack(spacing: 0) {
                if model.leadingPane.shown {
                    HStack(spacing: 0) {
                        LeadingPane(model: model, studio: studio).frame(width: model.leadingPane.width.points - 1)
                        // Centered on the divider, so its trailing half is over the lanes (0023).
                        Divider().overlay { PaneHandle(model: model, edge: .leading).frame(width: 6) }
                    }
                    .frame(width: model.leadingPane.width.points, alignment: .leading)
                    .zIndex(1)
                }
                lanes(studio)
                // Not in the tree when hidden, so a hidden pane runs no body (run 11b-2).
                if model.showsInspector {
                    HStack(spacing: 0) {
                        // The handle is centered on the 1 pt divider, above the lanes (0023).
                        Divider().overlay { PaneHandle(model: model, edge: .trailing).frame(width: 6) }
                        InspectorView(model: model, studio: studio)
                    }
                    // Leading: a pane wider than the column overflows at the window edge, and the
                    // divider stays on the lanes edge.
                    .frame(width: model.shownInspectorWidth, alignment: .leading)
                }
            }
            // An AppKit sheet: the close button is off while it shows (probe S1).
            .sheet(
                isPresented: Binding(get: { studio.exportProgress != nil || studio.archiveRun != nil }, set: { _ in })
            ) {
                ExportSheet(model: model, studio: studio)
            }
            // The list of Remove Unused Files (decision 0047). Only its buttons and Esc close it.
            .background {
                Color.clear.sheet(isPresented: Binding(get: { model.unusedFiles != nil }, set: { _ in })) {
                    if let scan = model.unusedFiles { UnusedFilesSheet(model: model, scan: scan) }
                }
            }
            // Tools > Duck Music Under Speech... (decision 0060), Sync Clip to Track... (decision 0076), and
            // File > Export with Presets... (decision 0080). Only their buttons close them.
            .background {
                Color.clear.sheet(isPresented: Binding(get: { model.duckDraft != nil }, set: { _ in })) {
                    if let draft = model.duckDraft {
                        DuckSheet(model: model, tracks: studio.session.tracks, draft: draft)
                    }
                }
                syncSheet(studio)
                presetSheet(studio)
            }
            // Tools > Reduce Noise... (decision 0054). Only its buttons close it.
            .background {
                Color.clear.sheet(isPresented: Binding(get: { model.denoiseDraft != nil }, set: { _ in })) {
                    if let draft = model.denoiseDraft { ReduceNoiseSheet(model: model, studio: studio, draft: draft) }
                }
            }
            // Tools > Repair Sound... (decision 0064). Only its buttons close it.
            .background {
                Color.clear.sheet(isPresented: Binding(get: { model.repairDraft != nil }, set: { _ in })) {
                    if let draft = model.repairDraft { RepairSheet(model: model, studio: studio, draft: draft) }
                }
            }
            // Tools > Transcribe Track... (decision 0065). Only its buttons close it.
            .background {
                Color.clear.sheet(isPresented: Binding(get: { model.transcribe.draft != nil }, set: { _ in })) {
                    if model.transcribe.draft != nil { TranscribeSheet(model: model) }
                }
            }
            // Transport > Go to Take Time... (decision 0061). Only its buttons close it.
            .background {
                Color.clear.sheet(isPresented: Binding(get: { model.takeTimeDraft != nil }, set: { _ in })) {
                    if let draft = model.takeTimeDraft { TakeTimeSheet(model: model, draft: draft) }
                }
            }
        case .closing(nil), .closed:
            EmptyView()
        }
    }

    private func presetSheet(_ studio: Studio) -> some View {
        Color.clear.sheet(isPresented: Binding(get: { model.presetSheet != nil }, set: { _ in })) {
            if let sheet = model.presetSheet { ExportPresetsSheet(model: model, studio: studio, sheet: sheet) }
        }
    }

    private func syncSheet(_ studio: Studio) -> some View {
        Color.clear.sheet(isPresented: Binding(get: { model.syncDraft != nil }, set: { _ in })) {
            if let draft = model.syncDraft { SyncSheet(model: model, studio: studio, draft: draft) }
        }
    }

    /// The text and the buttons of a session with no tracks. The first action has its button
    /// (ux-decisions 14): Add Track is the one prominent action, above Add Call Tracks, at one
    /// width. The full frame centers them in the area beside the inspector, also under a banner
    /// (ui-polish-chrome U2).
    private var emptyContent: some View {
        ContentUnavailableView {
            Label(L10n.emptyTitle.key, systemImage: "waveform")
        } description: {
            Text(L10n.emptySteps.key)
        } actions: {
            VStack {
                Button {
                    model.run(.addTrack)
                } label: {
                    Text(L10n.menuTrackAdd.key).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Menu {
                    CallTracksItems(model: model)
                } label: {
                    Text(L10n.menuTrackAddCall.key).frame(maxWidth: .infinity)
                }
                .menuStyle(.button).buttonStyle(.bordered)
            }
            .fixedSize().disabled(!model.canEdit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The banners, the lanes, and the loudness strip of an open session.
    private func lanes(_ studio: Studio) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let app = model.app, let window = model.window, app.uncleanNotice.shows(in: window) {
                UncleanNoticeBanner(app: app)
            }
            if let error = studio.saveError {
                BannerRow(
                    kind: .error, text: L10n.bannerSaveError.text,
                    detail: L10n.message(for: error, session: studio.session))
            }
            TakeBanner(model: model, studio: studio)
            TranscribeBanner(model: model)
            WindowBanners(model: model)
            if studio.session.tracks.isEmpty {
                EmptyDropHost(model: model, content: emptyContent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // An overlay, not a row: the lanes do not move when it shows or goes. It shows in the
                // ruler band over the track headers, so it covers no ruler time (0025).
                TimelinePane(model: model, studio: studio).overlay(alignment: .topLeading) {
                    RecordOverChip(model: model).padding(.top, OverviewGeometry.height)
                }
                if model.showsLoudness {
                    LoudnessStripView(model: model).frame(height: LoudnessStrip.height)
                }
            }
        }
    }
}

/// The track headers on the left and the lanes on the right (decision 0017). The lanes share
/// the height, 40 to 200 pt each, or take the fixed height of Taller and Shorter Tracks, 40 to
/// 200 pt (0025); the headers take the same height. Lanes that do not fit scroll vertically, and
/// the headers scroll with them.
private struct TimelinePane: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        GeometryReader { geometry in
            let tracks = studio.session.tracks
            // The overview strip and the ruler above, and a scroller below that can take its own height.
            let free = geometry.size.height - OverviewGeometry.height - TimelineRuler.thickness - 16
            let height = model.timeline.laneHeight.points(free: free, tracks: tracks.count)
            TimelineLanes(
                model: model, studio: studio, inputs: laneInputs(model, studio, laneHeight: height),
                currentMarker: model.timeline.marker, silences: model.silenceBands(in: studio),
                headers: TrackHeaders(
                    model: model, studio: studio, laneHeight: height,
                    selected: model.timeline.selection.headerTracks(in: studio.session)))
        }
    }
}

/// The drawn inputs of the lanes. It reads no value that the playhead poll writes, so a play
/// updates no SwiftUI view of the lanes (decision 0017).
@MainActor func laneInputs(_ model: SessionWindow, _ studio: Studio, laneHeight: Double) -> LaneInputs {
    LaneInputs(
        session: studio.session, peaks: studio.peaks, missingMedia: studio.missingMedia,
        selection: model.timeline.selection,
        scale: model.timeline.scale, laneHeight: laneHeight, range: model.timeline.waveformRange)
}

/// The progress of a running export, with Cancel and Record (decision 0019). The sheet can hold
/// the key status, so the Record menu item may not reach the window: its button is the Record
/// path. Studio cancels the export when the take checks pass. A package job shows its file count
/// and Cancel, with no Record (decision 0072).
private struct ExportSheet: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        if studio.archiveRun != nil { ArchiveSheet(model: model, studio: studio) } else { exportBody }
    }

    private var exportBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: model.sheetTitle).font(.headline)
            ProgressView(value: studio.exportProgress ?? 1).frame(width: 320)
            if let refusal = model.recordRefusal {
                Text(verbatim: L10n.message(for: refusal, session: studio.session)).foregroundStyle(.red)
                    .frame(width: 320, alignment: .leading)
            }
            HStack {
                Button(L10n.transportRecord.key) { Task { await model.record() } }.disabled(!model.canRecord)
                Spacer()
                Button(L10n.sheetExportCancel.key) { model.cancelExport() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}

extension WindowAlert {
    /// The body under the title: only the follow alert and the question before a favorite removal have one.
    var message: String? {
        switch self {
        case .followOverlap(let overlap): overlap.body()
        case .confirmRemoveFavorite: L10n.alertFavoritesRemoveBody.text
        case .error(.sessionImport(let error, _)): L10n.detail(for: error)
        default: nil
        }
    }

    var text: String {
        switch self {
        case .error(let error): L10n.message(for: error)
        case .importChain(let errors, let notImported):
            L10n.alertImportChain.format(errors.map { L10n.message(for: $0) }.joined(separator: "\n"))
                + (notImported.isEmpty
                    ? "" : "\n\n" + L10n.alertImportNotImported.format(notImported.joined(separator: "\n")))
        case .microphone(let access): L10n.message(for: .microphoneAccess(access))
        case .followOverlap(let overlap): overlap.title()
        case .confirmStopAndClose: L10n.alertCloseRecording.text
        case .confirmUnsavedClose: L10n.alertCloseUnsaved.text
        case .confirmRemoveTracks: L10n.alertTrackRemove.text
        case .noUnusedFiles(let scan): ([L10n.alertUnusedNone.text] + L10n.scanLines(scan)).joined(separator: "\n\n")
        case .exported(let paths, let report):
            L10n.alertExported.format(paths.joined(separator: "\n"))
                + (report.flatMap(L10n.exportedLoudness).map { "\n\n" + $0 } ?? "")
        case .exportedSet(let media, let parts):
            L10n.alertExported.format(media.joined(separator: "\n")) + "\n\n"
                + L10n.alertExportedParts.format(parts.joined(separator: "\n"))
        case .transcriptExport(let error): L10n.message(for: error)
        case .transcriptImport(let text): text
        case .placedWithNoClip(let segment): L10n.alertPlaceNoClip.format(segment.stem)
        case .transcribeFile(let error, let request):
            if case .file(let url, _) = request.model {
                L10n.message(for: error, modelFile: url)
            } else {
                L10n.message(for: error)
            }
        case .transcribeNoData(let error, _): L10n.message(for: error)
        case .templateTrash(let name): L10n.errorTemplateTrash.format(name)
        case .templateOpen(let name): L10n.errorTemplateOpen.format(name)
        case .templateNewKept(let name, _): L10n.errorTemplateKeptNew.format(name)
        case .templateOldKept(let name, _): L10n.errorTemplateKeptOld.format(name)
        case .binFileFault(let path, .missing): L10n.errorBinMissing.format(path)
        case .binFileFault(let path, .short): L10n.errorBinShort.format(path)
        case .binFileFault(let path, .unreadable): L10n.errorBinUnreadable.format(path)
        case .confirmRemoveFavorite(_, let name): L10n.alertFavoritesRemove.format(name)
        }
    }
}

/// The buttons of the Remove Track question. Remove is the default button (Return) and has no
/// destructive style: the user chose Remove, and Undo gives the tracks back (ui-panel 2). Cancel
/// has the cancel role (Esc).
let removeQuestionButtons: [(title: L10n, role: ButtonRole?)] = [
    (.alertTrackRemoveConfirm, nil), (.alertCancel, .cancel),
]

extension SessionWindow {
    /// Counts a run of a SwiftUI body of the window content, for the tests (ui-shell A21).
    func countBody() { bodyRuns += 1 }
    /// Counts a body run of the record-over chip that shows the warning, for the tests.
    func countOverlay() { overlayShows += 1 }
    /// Counts a run of the periodic content of the take banner, for the tests.
    func countBannerRun() { bannerRuns += 1 }
}

/// The items of Track > Add Call Tracks and of the empty state menu (B1c).
struct CallTracksItems: View {
    let model: SessionWindow

    var body: some View {
        ForEach(callMenuItems(model.apps, tapsAvailable: model.tapsAvailable), id: \.self) { item in
            switch item {
            case .app(let bundleID, let name):
                Button {
                    model.addCallTracks(app: bundleID)
                } label: {
                    Text(verbatim: name)
                }
            case .noApps: Button(L10n.menuTrackAddCallNoApps.key) {}.disabled(true)
            case .unavailable: Button(L10n.trackRouteAppsUnavailable.key) {}.disabled(true)
            case .divider: Divider()
            case .noApp: Button(L10n.menuTrackAddCallNone.key) { model.addCallTracks(app: nil) }
            }
        }
    }
}
