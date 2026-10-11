import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The track headers: row n is the header of lane n, with the lane height.
struct TrackHeaders: View {
    let model: SessionWindow
    let studio: Studio
    let laneHeight: Double
    /// The tracks that `Selection.headerTracks` gives, not the selection: a range drag over the
    /// same tracks gives an equal input, so it runs no row body (ui-polish C16).
    let selected: [TrackID]
    /// The header widths from which a row shows M and S, on one line and on two lines (decision
    /// 0039): the narrowest widths where every view of a row with a full live state stays inside
    /// the row (`HeaderRowTests.muteAndSoloShowOnlyWhereTheyFit`). Measure them again with a width
    /// sweep when a control of the row changes. Under them the route and the state keep their
    /// room; Shift-M and Shift-S still act.
    static let muteSoloWidth = 328.0
    static let muteSoloTwoLineWidth = 230.0
    /// The header widths from which a row shows the Monitor box, on one line and on two lines:
    /// measured as the M and S widths, with M and S hidden. Under them a row shows R only, and
    /// Track > Monitor Track still acts.
    static let monitorWidth = 284.0
    static let monitorTwoLineWidth = 186.0
    /// The header width from which a one-line row shows the layout text (`TrackRow.showsLayout`).
    static let layoutWidth = 235.0
    /// The header width from which a one-line row shows the short-term text: under it the text
    /// pushes the dropped-frames symbol out of the row. The guide and `loudness.take.tip` give it.
    static let compactLoudnessWidth = 262.0
    /// The header width from which a two-line row shows the volume fader (F94): the narrowest
    /// width where the route menu keeps `faderRouteWidth` and every view stays inside the row
    /// (`HeaderRowTests.theFaderShowsOnlyWhereItFits`). Under it Track > Raise Track Volume and
    /// the other volume items still act. A one-line row has no fader.
    static let faderTwoLineWidth = 252.0
    static let faderRouteWidth = 80.0

    /// The boxes of a row of `width`: M and S from their gate, Monitor from its gate.
    static func boxes(width: Double, twoLines: Bool) -> HeaderBoxes {
        if width >= (twoLines ? muteSoloTwoLineWidth : muteSoloWidth) { return .all }
        return width >= (twoLines ? monitorTwoLineWidth : monitorWidth) ? .armMonitor : .arm
    }

    var body: some View {
        let _ = model.countHeaderRun(row: false)
        // The layout of a row comes from the header width and the lane height only, never from
        // the text: a typed name that picks another layout rebuilds its field (code gate 1).
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(studio.session.tracks) { track in
                    TrackRow(
                        model: model, studio: studio, track: track, selected: selected.contains(track.id),
                        secondLine: laneHeight >= 56, tall: laneHeight >= 80,
                        showsLayout: laneHeight >= 56 || geometry.size.width >= Self.layoutWidth,
                        boxes: Self.boxes(width: geometry.size.width, twoLines: laneHeight >= 56),
                        showsCompactLoudness: geometry.size.width >= Self.compactLoudnessWidth,
                        showsFader: laneHeight >= 56 && geometry.size.width >= Self.faderTwoLineWidth
                    )
                    .frame(height: laneHeight, alignment: .leading).clipped()
                    // At the lane edge, as the lanes have no line: the rows read as rows (D8).
                    .overlay(alignment: .bottom) { Color(nsColor: .separatorColor).frame(height: 1) }
                }
            }
        }
    }
}

/// The header of one lane. In a lane of 56 pt or more: the R, Monitor, M, and S buttons, the
/// name, and the layout on the first line; the route menu and the volume fader, or during a take
/// or a monitor the meter and the state, on the second. In a lower lane, one line: the buttons,
/// the name, the layout, a route symbol menu, and the compact meter and state.
private struct TrackRow: View {
    let model: SessionWindow
    let studio: Studio
    let track: Track
    let selected: Bool
    /// True in a lane of 56 pt or more: the row has two lines (H7).
    let secondLine: Bool
    /// True in a lane of 80 pt or more: the state text has a line 3. A Bool, as `showsLayout`.
    let tall: Bool
    /// The layout text, when the header width has room for it: at every width on two lines, from
    /// `TrackHeaders.layoutWidth` on one line, so no control goes under the handle. The width
    /// alone picks it, never the typed name. A Bool, not the width: a row whose inputs do not
    /// change is not drawn again (a width input made the one-off header events 2 to 3 times slower).
    let showsLayout: Bool
    /// The boxes from the width gates of `TrackHeaders`. An enum of three values, not the width,
    /// as `showsLayout`.
    let boxes: HeaderBoxes
    /// The short-term text in the one-line row, from `TrackHeaders.compactLoudnessWidth`. A Bool,
    /// as `showsLayout`.
    let showsCompactLoudness: Bool
    /// The fader on line 2, from `TrackHeaders.faderTwoLineWidth`. A Bool, as `showsLayout`.
    let showsFader: Bool
    @FocusState private var focused: Bool
    /// Key: the window is key, so a selected row shows the emphasized fill.
    @Environment(\.controlActiveState) private var activeState

    private var style: HeaderRowStyle { HeaderRowStyle(selected: selected, emphasized: activeState == .key) }
    private var textColor: Color { style.text.map { Color(nsColor: $0) } ?? .primary }
    private var renaming: Bool { model.renamingTrack == track.id }

    var body: some View {
        let _ = model.countHeaderRun(row: true)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TrackToggles(model: model, track: track, boxes: boxes)
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
                    if let live = studio.liveTracks[track.id] {
                        CompactLiveState(live: live, source: sourceLabel, showsLoudness: showsCompactLoudness)
                    }
                    if let quiet { quietSymbol(quiet) }
                }
            }
            if secondLine {
                let live = studio.liveTracks[track.id]
                // The live state and the quiet text take the place of the fader, so the fader
                // never reads as an input gain next to the meter.
                let fader = showsFader && live == nil && quiet == nil
                HStack(spacing: 8) {
                    routeMenu.frame(minWidth: 0, maxWidth: 240, alignment: .leading).disabled(!model.canEdit)
                        .layoutPriority(fader ? 1 : 0)
                    if let live {
                        LiveState(
                            live: live, source: sourceLabel, showsNoSound: !tall,
                            openSettings: model.openAudioCaptureSettings)
                    }
                    if let quiet, !tall { quietSymbol(quiet) }
                    if fader {
                        // At the trailing edge, so the faders of the rows make one column.
                        Spacer(minLength: 0)
                        TrackFader(model: model, track: track.id, name: track.name, dB: track.gain.dB)
                            .fixedSize().disabled(!model.canEdit)
                    }
                }
                if tall { stateLine(live) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(textColor)
        .background { if let fill = style.fill { Color(nsColor: fill) } }
        .contentShape(Rectangle())
        // The controls of the row take their own clicks.
        .onTapGesture(perform: click)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            // The menu content appears when the menu opens (ui-panel 8).
            Button(L10n.menuTrackRemove.key) { model.removeFromHeader(track.id) }
                .onAppear { model.showHeaderMenu(track.id) }
        }
    }

    /// The name is the main text of the row: 13 pt, and it takes the free width. It reads as a
    /// label: a click on it selects the track, and a double-click starts the rename (ui-panel 5).
    /// The field stays in the row, so a rename keeps the layout.
    private var nameField: some View {
        TextField(L10n.trackName.key, text: name)
            .textFieldStyle(.plain)
            .focused($focused)
            // Return ends a rename: the lanes take the focus, so a later key is not a draft. A field
            // that has the focus with no rename keeps it, so the field keeps the keys it uses.
            .onSubmit { if renaming { model.endNameEdit() } else { model.commitName(track.id) } }
            .onChange(of: focused) { if !focused { model.commitName(track.id) } }
            .disabled(!model.canEdit)
            .controlSize(.regular)
            .foregroundStyle(renaming ? .primary : textColor)
            .background { if renaming { Color(nsColor: .textBackgroundColor) } }
            .overlay {
                // Over the field, so a click does not give it the text focus.
                if !renaming { Color.clear.contentShape(Rectangle()).onTapGesture(perform: click) }
            }
            .accessibilityAction(named: Text(L10n.headerRename.key)) { model.startRename(track.id) }
            // A one-line row has the arm box of 18 pt at every width, so its name gives up 6 pt.
            .frame(minWidth: secondLine ? 60 : 54, maxWidth: .infinity)
    }

    /// A click selects at once. `HeaderHost` takes the second click of a double-click on the name;
    /// on the row background that click does nothing more.
    private func click() {
        let event = model.headerMouseDown
        guard (event?.clickCount ?? 1) < 2 else { return }
        model.clickHeader(track.id, flags: event?.modifierFlags ?? [])
    }

    /// The saved name comes from the session, not from `track`: the end of an edit after a commit
    /// reads the name before this row has the new track, and it wrote the old name as a draft.
    private var name: Binding<String> {
        Binding(
            get: { model.drafts[track.id] ?? studio.session.track(track.id)?.name ?? track.name },
            set: { model.drafts[track.id] = $0 })
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

    /// The state of a listened track that plays no monitor sound (decision 0044).
    private var quiet: HeaderStateText? {
        HeaderStateText.quiet(
            live: studio.liveTracks[track.id], quiet: studio.quietListens.contains(track.id),
            loopback: studio.loopbackListens.contains(track.id))
    }

    private func quietSymbol(_ quiet: HeaderStateText) -> some View {
        Image(systemName: "speaker.slash.fill").foregroundStyle(.orange)
            .accessibilityLabel(Text(verbatim: quiet.full)).help(Text(verbatim: quiet.full))
    }

    /// Line 3 of a row of 80 pt or more: the short state on one line, then the "Privacy…" button of
    /// an app track that gets no sound. The full sentence wrapped to 3 to 13 lines (run
    /// 2026-10-11-ui-polish-header U5).
    @ViewBuilder private func stateLine(_ live: LiveTrack?) -> some View {
        let noSound = live?.state == .noSound
        if let state = noSound ? HeaderStateText.noSound(sourceLabel) : quiet {
            HStack(spacing: 8) {
                Text(verbatim: state.row).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                    .help(Text(verbatim: state.full)).accessibilityLabel(Text(verbatim: state.full))
                if noSound {
                    // A short title; the full name is the help and the VoiceOver name.
                    Button(L10n.trackNoSoundPrivacy.key, action: model.openAudioCaptureSettings)
                        .fixedSize()
                        .help(L10n.trackNoSoundSettings.key)
                        .accessibilityLabel(L10n.trackNoSoundSettings.key)
                }
            }
        }
    }

    /// The source of the route: a device name or an app name; empty with no route.
    private var sourceLabel: String {
        switch track.route {
        case nil: ""
        case .app(let bundleID): model.appName(bundleID)
        case .device(let uid, _): routeLabel(uid: uid, devices: model.devices)
        }
    }

    private var routeText: String {
        // "No Input" reads as a state; the label asks for the action. The item stays "No Input".
        guard let route = track.route else { return L10n.trackRouteChoose.text }
        guard case .device(_, let channels) = route else { return sourceLabel }
        return L10n.trackRoute.format(sourceLabel, channelsText(channels))
    }
}

extension SessionWindow {
    /// Counts a body run of the track headers or of one row, for the tests.
    func countHeaderRun(row: Bool) {
        if row { headerRuns.rows += 1 } else { headerRuns.headers += 1 }
    }
}

/// The look of a header row: the selection colors of a macOS source list (ui-panel 4). Nil: the
/// default of the row.
struct HeaderRowStyle: Equatable {
    let fill: NSColor?
    let text: NSColor?

    /// `emphasized`: the window is key.
    init(selected: Bool, emphasized: Bool) {
        fill =
            selected
            ? (emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor) : nil
        text = selected && emphasized ? .alternateSelectedControlTextColor : nil
    }
}

/// The device of a route: its name, or the "missing" text when it is not in `devices`.
func routeLabel(uid: String, devices: [InputDevice]) -> String {
    devices.first { $0.uid == uid }?.name ?? L10n.trackRouteMissing.text
}

private func channelsText(_ channels: Route.Channels) -> String {
    switch channels {
    case .mono(let channel): L10n.trackRouteChannel.format(channel)
    case .stereo(let left, let right): L10n.trackRouteChannels.format(left, right)
    }
}
