import AppKit
import DirigibleCore
import SwiftUI

/// Mute or solo, the two flags of a track (decision 0039).
enum TrackFlag: CaseIterable {
    case muted, soloed

    func isOn(_ track: Track) -> Bool { self == .muted ? track.isMuted : track.isSoloed }

    func set(_ on: Bool, _ tracks: [TrackID], in session: inout Session) throws(SessionError) {
        switch self {
        case .muted: try session.setMuted(on, tracks: tracks)
        case .soloed: try session.setSoloed(on, tracks: tracks)
        }
    }

    /// The VoiceOver label of the button of `name`: "Mute Host".
    func label(_ name: String) -> String { (self == .muted ? L10n.trackMuteLabel : .trackSoloLabel).format(name) }
}

extension SessionWindow {
    /// The M or S button of a header row: one edit, so one undo entry and an autosave. With `all`
    /// (Option-click) every track gets the new state. During a take it does nothing.
    func setFlag(_ flag: TrackFlag, _ on: Bool, track: TrackID, all: Bool) {
        edit { session throws(SessionError) in
            try flag.set(on, all ? session.tracks.map(\.id) : [track], in: &session)
        }
    }

    /// Track > Mute Track and Solo Track: the tracks of the range selection. When one of them is
    /// off, all go on; else all go off. No track, or a clip set: a beep (decision 0038).
    func toggleFlag(_ flag: TrackFlag) {
        guard let studio else { return }
        let tracks = timeline.selection.headerTracks(in: studio.session)
        guard !tracks.isEmpty else { return beep() }
        let on = tracks.contains { studio.session.track($0).map { !flag.isOn($0) } ?? false }
        edit { session throws(SessionError) in try flag.set(on, tracks, in: &session) }
    }
}

/// The R, M, and S buttons of a header row (ui-panel.md 1, 2, 9; run 2026-10-10-arm-toggle-button):
/// arm on is a fixed systemRed fill with a white dot, mute on a systemBlue fill with a white letter,
/// solo on a systemYellow fill with a black letter, never the accent color. Off is a plain bordered
/// button, so the state is the fill, not the hue only. Arm shows at every header width; M and S
/// only with `showsMuteSolo`.
struct TrackToggles: View {
    let model: SessionWindow
    let track: Track
    let showsMuteSolo: Bool

    var body: some View {
        HStack(spacing: 4) {
            arm
            if showsMuteSolo {
                toggle(.muted, letter: .trackMuteLetter, help: .trackMuteHelp, fill: .systemBlue, text: .white)
                toggle(.soloed, letter: .trackSoloLetter, help: .trackSoloHelp, fill: .systemYellow, text: .black)
            }
        }
        .disabled(!model.canEdit)
        // A disabled button gives its click to the row, which selects the track. An enabled button
        // takes its own click before this tap.
        .onTapGesture {}
    }

    /// Arm is window state, not a session edit, so a click adds no undo entry. The symbol has no
    /// language, so English and Spanish show the same dot.
    private var arm: some View {
        Toggle(
            isOn: Binding(
                get: { model.armed.contains(track.id) },
                set: { if $0 { model.armed.insert(track.id) } else { model.armed.remove(track.id) } })
        ) { Image(systemName: "circle.fill").imageScale(.small) }
        .toggleStyle(FlagToggleStyle(fill: Color(nsColor: .systemRed), letter: .white))
        .accessibilityLabel(Text(verbatim: L10n.trackArmLabel.format(track.name)))
        .help(Text(L10n.trackArmHelp.key))
    }

    /// True for a mouse click with Option. A key press or an AX press of the button sets only its
    /// track, also with Option held.
    static func isOptionClick(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown || event.type == .leftMouseUp else { return false }
        return event.modifierFlags.contains(.option)
    }

    private func toggle(_ flag: TrackFlag, letter: L10n, help: L10n, fill: NSColor, text: Color) -> some View {
        Toggle(
            isOn: Binding(
                // The session now, not `track`: a second click can come before the row has the
                // new track.
                get: { model.studio?.session.track(track.id).map(flag.isOn) ?? false },
                set: { on in
                    model.setFlag(flag, on, track: track.id, all: Self.isOptionClick(NSApp.currentEvent))
                })
        ) { Text(letter.key) }
        .toggleStyle(FlagToggleStyle(fill: Color(nsColor: fill), letter: text))
        .accessibilityLabel(Text(verbatim: flag.label(track.name)))
        .help(Text(help.key))
    }
}

/// A letter or a symbol in a small box: filled when on, bordered when off. VoiceOver reads a toggle with its
/// on and off value.
private struct FlagToggleStyle: ToggleStyle {
    let fill: Color
    let letter: Color

    func makeBody(configuration: Configuration) -> some View {
        FlagBox(configuration: configuration, fill: fill, letter: letter)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

private struct FlagBox: View {
    let configuration: ToggleStyleConfiguration
    let fill: Color
    let letter: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let on = configuration.isOn
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? letter : Color.primary)
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? fill : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Color.clear : Color.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(FlagButtonStyle())
        // During a take an on button keeps its full color, so the state of each track reads.
        .opacity(isEnabled || on ? 1 : 0.4)
    }
}

/// A button that draws its label with no dimming when disabled, unlike `.plain`: `FlagBox` dims
/// only an off box. A pressed button dims its label.
private struct FlagButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
