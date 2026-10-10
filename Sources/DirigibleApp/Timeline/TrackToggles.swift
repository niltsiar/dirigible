import AppKit
import DirigibleCore
import SwiftUI

/// The R, M, and S buttons of a header row (ui-panel.md 1, 2, 9):
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
