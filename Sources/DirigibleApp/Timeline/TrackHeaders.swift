import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The track headers: row n is the header of lane n, with the lane height.
struct TrackHeaders: View {
    let model: SessionWindow
    let studio: Studio
    let laneHeight: Double

    var body: some View {
        // The layout of a row comes from the header width and the lane height only, never from
        // the text: a typed name that picks another layout rebuilds its field (code gate 1).
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(studio.session.tracks) { track in
                    TrackRow(
                        model: model, studio: studio, track: track, secondLine: laneHeight >= 56,
                        showsLayout: geometry.size.width >= 220
                    )
                    .frame(height: laneHeight, alignment: .leading).clipped()
                    // At the lane edge, as the lanes have no line: the rows read as rows (D8).
                    .overlay(alignment: .bottom) { Color(nsColor: .separatorColor).frame(height: 1) }
                }
            }
        }
    }
}

/// The header of one lane: arm, name, and layout on the first line; route, and during a take or
/// a monitor the meter and the state, on the second.
private struct TrackRow: View {
    let model: SessionWindow
    let studio: Studio
    let track: Track
    /// The route and the live state. Off in a lane under 56 pt: one line fits (H7).
    let secondLine: Bool
    /// The layout text. Off under 220 pt: "Armar", a name of 60 pt, and "Estéreo" are wider than
    /// a row of 180 pt, and no control goes under the handle.
    let showsLayout: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                arm
                nameField
                if showsLayout {
                    // One line: a squeezed text wraps into the row below. The same for the arm label.
                    Text(track.layout == .mono ? L10n.trackLayoutMono.key : L10n.trackLayoutStereo.key)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if secondLine {
                HStack(spacing: 8) {
                    routeMenu.frame(minWidth: 0, maxWidth: 240, alignment: .leading).disabled(!model.canEdit)
                    if let live = studio.liveTracks[track.id] { LiveState(live: live) }
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
            Text(verbatim: routeText).lineLimit(1).truncationMode(.tail)
        }
    }

    private var routeText: String {
        // "No Input" reads as a state; the label asks for the action. The item stays "No Input".
        guard let route = track.route else { return L10n.trackRouteChoose.text }
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
