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
            // Only the buttons end the rename: OK during a take keeps the typed name (code gate 1).
            .alert(
                L10n.alertMarkerRename.key,
                isPresented: Binding(get: { model.timeline.renaming != nil }, set: { _ in })
            ) {
                TextField(
                    L10n.trackName.key,
                    text: Binding(
                        get: { model.timeline.renaming?.name ?? "" }, set: { model.timeline.renaming?.name = $0 }))
                Button(L10n.alertOK.key) { model.commitRename() }
                Button(L10n.alertCancel.key, role: .cancel) { model.timeline.renaming = nil }
            }
            // 720 pt keeps the transport and the time display in the toolbar (probe P1c). The
            // inspector adds its width (run 11b-2).
            .frame(minWidth: Self.minWidth + (model.showsInspector ? InspectorView.width : 0), minHeight: 360)
            .alert(
                Text(verbatim: model.alert.map(\.text) ?? ""),
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { alert in
                switch alert {
                case .confirmStopAndClose:
                    Button(L10n.alertCloseRecordingConfirm.key, role: .destructive) { Task { await model.close() } }
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
                case .microphone:
                    Button(L10n.alertMicrophoneSettings.key) { model.openPrivacySettings() }
                    Button(L10n.alertCancel.key, role: .cancel) {}
                case .error, .exported:
                    Button(L10n.alertOK.key, role: .cancel) {}
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
            ProgressView(model.recovering ? L10n.windowRecovering.key : L10n.windowOpening.key)
        case .failed(let error):
            VStack(spacing: 12) {
                Text(verbatim: L10n.message(for: error))
                Button(L10n.windowTryAgain.key) { model.open(recovering: model.recovering) }
            }
        case .open(let studio), .closing(let studio?):
            HStack(spacing: 0) {
                lanes(studio)
                // Not in the tree when hidden, so a hidden pane runs no body (run 11b-2).
                if model.showsInspector {
                    HStack(spacing: 0) {
                        Divider()
                        InspectorView(model: model, studio: studio)
                    }
                    .frame(width: InspectorView.width)
                }
            }
            // An AppKit sheet: the close button is off while it shows (probe S1).
            .sheet(isPresented: Binding(get: { studio.exportProgress != nil }, set: { _ in })) {
                ExportSheet(model: model, studio: studio)
            }
        case .closing(nil), .closed:
            EmptyView()
        }
    }

    /// The banners, the lanes, and the loudness strip of an open session.
    private func lanes(_ studio: Studio) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = studio.saveError {
                BannerRow(
                    kind: .error,
                    text: L10n.bannerSaveError.format(L10n.message(for: error, session: studio.session)))
            }
            TakeBanner(model: model, studio: studio)
            WindowBanners(model: model)
            if studio.session.tracks.isEmpty {
                // The first action has its button (ux-decisions 14).
                ContentUnavailableView {
                    Label(L10n.emptyTitle.key, systemImage: "waveform")
                } description: {
                    Text(L10n.emptySteps.key)
                } actions: {
                    Button(L10n.menuTrackAdd.key) { model.run(.addTrack) }.disabled(!model.canEdit)
                    Menu(L10n.menuTrackAddCall.key) { CallTracksItems(model: model) }
                        .fixedSize().disabled(!model.canEdit)
                }
            } else {
                // An overlay, not a row: the lanes do not move when it shows or goes. It shows
                // over the ruler, below the overview strip, where the user acts on it (0025).
                TimelinePane(model: model, studio: studio).overlay(alignment: .top) {
                    RecordOverOverlay(model: model).padding(.top, OverviewGeometry.height)
                }
                if model.showsLoudness {
                    LoudnessStripView(model: model).frame(height: LoudnessStrip.height)
                }
            }
        }
    }
}

/// The track headers on the left and the lanes on the right (decision 0017). The lanes share
/// the height, 40 to 120 pt each, or take the fixed height of Taller and Shorter Tracks, 40 to
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
                currentMarker: model.timeline.marker,
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
        scale: model.timeline.scale, laneHeight: laneHeight)
}

/// The progress of a running export, with Cancel and Record (decision 0019). The sheet can hold
/// the key status, so the Record menu item may not reach the window: its button is the Record
/// path. Studio cancels the export when the take checks pass.
private struct ExportSheet: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetExportTitle.key).font(.headline)
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
    var text: String {
        switch self {
        case .error(let error): L10n.message(for: error)
        case .microphone(let access): L10n.message(for: .microphoneAccess(access))
        case .confirmStopAndClose: L10n.alertCloseRecording.text
        case .confirmUnsavedClose: L10n.alertCloseUnsaved.text
        case .confirmRemoveTracks: L10n.alertTrackRemove.text
        case .exported(let paths, let report):
            L10n.alertExported.format(paths.joined(separator: "\n"))
                + (report.map {
                    "\n\n" + L10n.alertExportedLoudness.format(L10n.message(for: $0)) + L10n.largeGainHint(for: $0)
                } ?? "")
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
    /// Counts a body run of the record-over overlay that shows the warning, for the tests.
    func countOverlay() { overlayShows += 1 }
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
