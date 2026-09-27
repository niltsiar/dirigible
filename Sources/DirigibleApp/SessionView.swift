import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The content of a session window. It reads `SessionWindow` and `Studio` and sends the actions
/// back; it keeps no copy of the take state.
struct SessionView: View {
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
            // 720 pt keeps the transport and the time display in the toolbar (probe P1c).
            .frame(minWidth: 720, minHeight: 360)
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
            VStack(alignment: .leading, spacing: 0) {
                if let error = studio.saveError {
                    BannerRow(
                        kind: .error,
                        text: L10n.bannerSaveError.format(L10n.message(for: error, session: studio.session)))
                }
                TakeBanner(model: model, studio: studio)
                WindowBanners(model: model)
                if studio.session.tracks.isEmpty {
                    Text(L10n.trackNone.key).foregroundStyle(.secondary).frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // An overlay, not a row: the lanes do not move when it shows or goes.
                    TimelinePane(model: model, studio: studio).overlay(alignment: .top) {
                        RecordOverOverlay(model: model)
                    }
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
}

/// The track headers on the left and the lanes on the right (decision 0017). The lanes share
/// the height, 40 to 120 pt each; the headers take the same height. Lanes that do not fit
/// scroll vertically, and the headers scroll with them.
private struct TimelinePane: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        GeometryReader { geometry in
            let tracks = studio.session.tracks
            // The ruler above, and a scroller below that can take its own height.
            let free = geometry.size.height - TimelineRuler.thickness - 16
            let height = min(120, max(40, (free / Double(max(1, tracks.count))).rounded(.down)))
            TimelineLanes(
                model: model, studio: studio, inputs: laneInputs(model, studio, laneHeight: height),
                headers: VStack(alignment: .leading, spacing: 0) {
                    ForEach(tracks) { track in
                        TrackRow(model: model, studio: studio, track: track)
                            .frame(height: height, alignment: .leading).clipped()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        }
    }
}

/// The drawn inputs of the lanes. It reads no value that the playhead poll writes, so a play
/// updates no SwiftUI view of the lanes (decision 0017).
@MainActor func laneInputs(_ model: SessionWindow, _ studio: Studio, laneHeight: Double) -> LaneInputs {
    LaneInputs(
        session: studio.session, peaks: studio.peaks, missingMedia: studio.missingMedia, marks: model.timeline.marks,
        scale: model.timeline.scale, laneHeight: laneHeight)
}

/// The header of one lane: arm, name, and layout on the first line; route, and during a take or
/// a monitor the meter and the state, on the second.
private struct TrackRow: View {
    let model: SessionWindow
    let studio: Studio
    let track: Track
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle(L10n.trackArm.key, isOn: armed).toggleStyle(.checkbox).disabled(!model.canEdit)
                TextField(L10n.trackName.key, text: name)
                    .focused($focused)
                    .onSubmit { model.commitName(track.id) }
                    .onChange(of: focused) { if !focused { model.commitName(track.id) } }
                    .disabled(!model.canEdit)
                    .frame(width: 150)
                Text(track.layout == .mono ? L10n.trackLayoutMono.key : L10n.trackLayoutStereo.key)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                routeMenu.frame(width: 180).disabled(!model.canEdit)
                if let live = studio.liveTracks[track.id] { LiveState(live: live) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .contextMenu { Button(L10n.menuTrackRemove.key) { model.removeTracks([track.id]) } }
    }

    private var name: Binding<String> {
        Binding(get: { model.drafts[track.id] ?? track.name }, set: { model.drafts[track.id] = $0 })
    }

    private var armed: Binding<Bool> {
        Binding(
            get: { model.armed.contains(track.id) },
            set: { if $0 { model.armed.insert(track.id) } else { model.armed.remove(track.id) } })
    }

    private var routeMenu: some View {
        Menu {
            Button(L10n.trackRouteNone.key) { model.setRoute(nil, device: nil, track: track.id) }
            ForEach(model.devices, id: \.uid) { device in
                Section(device.name) {
                    ForEach(routeOptions(channelCount: device.channelCount), id: \.self) { channels in
                        Button(channelsText(channels)) { model.setRoute(channels, device: device, track: track.id) }
                    }
                }
            }
        } label: {
            Text(verbatim: routeText)
        }
    }

    private var routeText: String {
        guard let route = track.route else { return L10n.trackRouteNone.text }
        return L10n.trackRoute.format(routeLabel(route: route, devices: model.devices), channelsText(route.channels))
    }
}

/// The device of a route: its name, or the "missing" text when it is not in `devices`.
func routeLabel(route: Route, devices: [InputDevice]) -> String {
    devices.first { $0.uid == route.deviceUID }?.name ?? L10n.trackRouteMissing.text
}

private func channelsText(_ channels: Route.Channels) -> String {
    switch channels {
    case .mono(let channel): L10n.trackRouteChannel.format(channel)
    case .stereo(let left, let right): L10n.trackRouteChannels.format(left, right)
    }
}

/// The meter and the state of an armed track during a take or a monitor.
private struct LiveState: View {
    let live: LiveTrack

    var body: some View {
        // -60 dBFS to 0 dBFS.
        let level = live.peak > 0 ? max(0, min(1, (20 * log10(Double(live.peak)) + 60) / 60)) : 0
        ProgressView(value: level).frame(width: 60)
        switch live.state {
        case .recording, .monitoring: EmptyView()
        case .deviceLost: Text(L10n.trackStateDeviceLost.key).foregroundStyle(.red)
        case .writeFailed: Text(L10n.trackStateWriteFailed.key).foregroundStyle(.red)
        case .retryStopped: Text(L10n.trackStateRetryStopped.key).foregroundStyle(.red)
        }
        if live.droppedFrames > 0 {
            Text(verbatim: L10n.trackDropped.format(live.droppedFrames)).foregroundStyle(.orange)
        }
    }
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
        case .exported(let paths): L10n.alertExported.format(paths.joined(separator: "\n"))
        }
    }
}

extension SessionWindow {
    /// Counts a run of a SwiftUI body of the window content, for the tests (ui-shell A21).
    func countBody() { bodyRuns += 1 }
    /// Counts a body run of the record-over overlay that shows the warning, for the tests.
    func countOverlay() { overlayShows += 1 }
}
