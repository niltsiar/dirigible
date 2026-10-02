import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The track headers: row n is the header of lane n, with the lane height.
struct TrackHeaders: View {
    let model: SessionWindow
    let studio: Studio
    let laneHeight: Double
    #if DEBUG
        /// The runs of the body of a row, for a test: a header width change that keeps the layout
        /// runs no row body (code gate 3).
        static var rowBodies = 0
        static func countRowBody() { rowBodies += 1 }
    #endif

    var body: some View {
        // The layout of a row comes from the header width and the lane height only, never from
        // the text: a typed name that picks another layout rebuilds its field (code gate 1).
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(studio.session.tracks) { track in
                    TrackRow(
                        model: model, studio: studio, track: track, secondLine: laneHeight >= 56,
                        showsLayout: geometry.size.width >= (laneHeight >= 56 ? 220 : 240)
                    )
                    .frame(height: laneHeight, alignment: .leading).clipped()
                    // At the lane edge, as the lanes have no line: the rows read as rows (D8).
                    .overlay(alignment: .bottom) { Color(nsColor: .separatorColor).frame(height: 1) }
                }
            }
        }
    }
}

/// The header of one lane. In a lane of 56 pt or more: arm, name, and layout on the first line;
/// the route menu, and during a take or a monitor the meter and the state, on the second. In a
/// lower lane, one line: the arm check box, the name, the layout, a route symbol menu, and the
/// compact meter and state (code gate 1 item 4).
private struct TrackRow: View {
    let model: SessionWindow
    let studio: Studio
    let track: Track
    /// True in a lane of 56 pt or more: the row has two lines (H7).
    let secondLine: Bool
    /// The layout text, when the header width has room for it: from 220 pt on two lines, from 240 pt
    /// on one line. "Armar", a name of 60 pt, and "Estéreo" are wider than a row of 180 pt, and no
    /// control goes under the handle. The width alone picks it, never the typed name. A Bool, not
    /// the width: a row whose inputs do not change is not drawn again (a width input made the
    /// one-off header events 2 to 3 times slower).
    let showsLayout: Bool
    @FocusState private var focused: Bool

    var body: some View {
        #if DEBUG
            let _ = TrackHeaders.countRowBody()
        #endif
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if secondLine { arm } else { arm.labelsHidden() }
                nameField
                if showsLayout {
                    // One line: a squeezed text wraps into the lane below. It is cut only after the
                    // name is at its minimum, so the route and the state always show.
                    Text(track.layout == .mono ? L10n.trackLayoutMono.key : L10n.trackLayoutStereo.key)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !secondLine {
                    // A lost device must show during a take at every lane height, so the route and
                    // the state stay on one line, in compact form.
                    compactRoute
                    if let live = studio.liveTracks[track.id] { CompactLiveState(live: live, source: sourceLabel) }
                }
            }
            if secondLine {
                HStack(spacing: 8) {
                    routeMenu.frame(minWidth: 0, maxWidth: 240, alignment: .leading).disabled(!model.canEdit)
                    if let live = studio.liveTracks[track.id] {
                        LiveState(live: live, source: sourceLabel, openSettings: model.openAudioCaptureSettings)
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .contextMenu { Button(L10n.menuTrackRemove.key) { model.removeTracks([track.id]) } }
    }

    private var arm: some View {
        Toggle(L10n.trackArm.key, isOn: armed).toggleStyle(.checkbox).disabled(!model.canEdit).fixedSize()
    }

    /// The name is the main text of the row: 13 pt, and it takes the free width.
    private var nameField: some View {
        TextField(L10n.trackName.key, text: name)
            .focused($focused)
            .onSubmit { model.commitName(track.id) }
            .onChange(of: focused) { if !focused { model.commitName(track.id) } }
            .disabled(!model.canEdit)
            .controlSize(.regular)
            .frame(minWidth: 60, maxWidth: .infinity)
    }

    private var name: Binding<String> {
        Binding(get: { model.drafts[track.id] ?? track.name }, set: { model.drafts[track.id] = $0 })
    }

    private var armed: Binding<Bool> {
        Binding(
            get: { model.armed.contains(track.id) },
            set: { if $0 { model.armed.insert(track.id) } else { model.armed.remove(track.id) } })
    }

    /// The route as a symbol menu, with the route text for VoiceOver and as its tooltip.
    private var compactRoute: some View {
        Menu {
            routeItems
        } label: {
            Image(systemName: "mic")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(!model.canEdit)
        .accessibilityLabel(Text(verbatim: routeText))
        .help(Text(verbatim: routeText))
    }

    private var routeMenu: some View {
        Menu {
            routeItems
        } label: {
            Text(verbatim: routeText).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private var routeItems: some View {
        Button(L10n.trackRouteNone.key) { model.setRoute(nil, device: nil, track: track.id) }
        ForEach(model.devices, id: \.uid) { device in
            Section(device.name) {
                ForEach(routeOptions(channelCount: device.channelCount), id: \.self) { channels in
                    Button(channelsText(channels)) { model.setRoute(channels, device: device, track: track.id) }
                }
            }
        }
        Divider()
        // A15: the running apps, read off the main actor when the menu opens.
        Section(L10n.trackRouteApps.key) {
            ForEach(appMenuItems(model.apps, tapsAvailable: model.tapsAvailable), id: \.self) { item in
                switch item {
                case .app(let bundleID, let name):
                    Button {
                        model.setAppRoute(bundleID, track: track.id)
                    } label: {
                        Text(verbatim: name)
                    }
                case .unavailable:
                    Button(L10n.trackRouteAppsUnavailable.key) {}.disabled(true)
                }
            }
        }
        .onAppear { model.refreshApps() }
    }

    /// The source of the route: a device name or an app name; empty with no route.
    private var sourceLabel: String {
        switch track.route {
        case nil: ""
        case .app(let bundleID): model.appName(bundleID)
        case let route?: routeLabel(route: route, devices: model.devices)
        }
    }

    private var routeText: String {
        // "No Input" reads as a state; the label asks for the action. The item stays "No Input".
        guard let route = track.route else { return L10n.trackRouteChoose.text }
        guard case .device(_, let channels) = route else { return sourceLabel }
        return L10n.trackRoute.format(sourceLabel, channelsText(channels))
    }
}

/// The source of a route: the device name, or the "missing" text when it is not in `devices`;
/// the bundle ID of an app.
func routeLabel(route: Route, devices: [InputDevice]) -> String {
    switch route {
    case .device(let uid, _): devices.first { $0.uid == uid }?.name ?? L10n.trackRouteMissing.text
    case .app(let bundleID): bundleID
    }
}

private func channelsText(_ channels: Route.Channels) -> String {
    switch channels {
    case .mono(let channel): L10n.trackRouteChannel.format(channel)
    case .stereo(let left, let right): L10n.trackRouteChannels.format(left, right)
    }
}

/// The level of a live track on the meter scale: -60 dBFS to 0 dBFS as 0 to 1.
private func meterLevel(_ live: LiveTrack) -> Double {
    live.peak > 0 ? max(0, min(1, (20 * log10(Double(live.peak)) + 60) / 60)) : 0
}

/// The meter and the state of a one-line row: a meter of 16 pt, and a symbol for a fault (red) or
/// dropped frames (orange), with the state text for VoiceOver and as its tooltip.
private struct CompactLiveState: View {
    let live: LiveTrack
    /// The route label: the app of a `.waitingForApp` or `.noSound` track.
    let source: String

    var body: some View {
        ProgressView(value: meterLevel(live)).frame(width: 16)
        if let fault {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel(Text(fault)).help(Text(fault))
        } else if live.droppedFrames > 0 {
            let text = L10n.trackDropped.format(live.droppedFrames)
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel(Text(verbatim: text)).help(Text(verbatim: text))
        }
    }

    private var fault: String? {
        switch live.state {
        case .recording, .monitoring: nil
        case .deviceLost: L10n.trackStateDeviceLost.text
        case .writeFailed: L10n.trackStateWriteFailed.text
        case .retryStopped: L10n.trackStateRetryStopped.text
        case .waitingForApp: L10n.trackStateWaitingForApp.format(source)
        case .noSound: L10n.trackStateNoSound.format(source)
        }
    }
}

/// The meter and the state of an armed track during a take or a monitor.
private struct LiveState: View {
    let live: LiveTrack
    /// The route label: the app of a `.waitingForApp` or `.noSound` track.
    let source: String
    /// Opens Privacy & Security > System Audio Recording (A9).
    let openSettings: () -> Void

    var body: some View {
        ProgressView(value: meterLevel(live)).frame(width: 60)
        switch live.state {
        case .recording, .monitoring: EmptyView()
        case .deviceLost: Text(L10n.trackStateDeviceLost.key).foregroundStyle(.red)
        case .writeFailed: Text(L10n.trackStateWriteFailed.key).foregroundStyle(.red)
        case .retryStopped: Text(L10n.trackStateRetryStopped.key).foregroundStyle(.red)
        case .waitingForApp: Text(verbatim: L10n.trackStateWaitingForApp.format(source)).foregroundStyle(.secondary)
        case .noSound:
            Text(verbatim: L10n.trackStateNoSound.format(source)).foregroundStyle(.orange)
            Button(L10n.trackNoSoundSettings.key, action: openSettings)
        }
        if live.droppedFrames > 0 {
            Text(verbatim: L10n.trackDropped.format(live.droppedFrames)).foregroundStyle(.orange)
        }
    }
}
