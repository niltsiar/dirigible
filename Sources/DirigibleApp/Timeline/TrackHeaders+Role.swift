import AppKit
import DirigibleCore
import SwiftUI

/// The look of a track role in the header (decision 0060, U12): a 4 pt strip at the leading edge
/// and a letter glyph, so the role does not depend on color alone. No role shows nothing.
extension Track.Role {
    var title: L10n {
        switch self {
        case .dialogue: .trackRoleDialogue
        case .music: .trackRoleMusic
        case .effects: .trackRoleEffects
        }
    }

    var letter: L10n {
        switch self {
        case .dialogue: .trackRoleDialogueLetter
        case .music: .trackRoleMusicLetter
        case .effects: .trackRoleEffectsLetter
        }
    }

    /// A system color, so the strip and the glyph follow light and dark mode.
    var color: NSColor {
        switch self {
        case .dialogue: .systemTeal
        case .music: .systemGreen
        case .effects: .systemYellow
        }
    }
}

/// The role letter on the role color, before the name.
struct RoleGlyph: View {
    static let size = 14.0
    let role: Track.Role

    var body: some View {
        Text(verbatim: role.letter.text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(width: Self.size, height: Self.size)
            .background(Color(nsColor: role.color), in: RoundedRectangle(cornerRadius: 3))
            .help(Text(role.title.key))
            .accessibilityLabel(Text(role.title.key))
    }
}

extension View {
    /// The strip covers 4 pt of the 8 pt leading padding of the row, so it hides no control.
    func roleStrip(_ role: Track.Role?) -> some View {
        overlay(alignment: .leading) { if let role { Color(nsColor: role.color).frame(width: 4) } }
    }
}

/// The items of Track > Role and of the header menu. An item is checked when each track of the
/// menu has its role.
struct RoleItems: View {
    let model: SessionWindow
    /// The row of the header menu; nil for Track > Role. The tracks come from the selection in
    /// this body, so a range drag runs no row body (ui-polish C16).
    let headerRow: TrackID?

    var body: some View {
        let tracks = headerRow.map(model.headerMenuTracks) ?? model.roleMenuTracks
        item(nil, .trackRoleNone, tracks)
        Divider()
        ForEach(Track.Role.allCases, id: \.self) { role in item(role, role.title, tracks) }
    }

    private func item(_ role: Track.Role?, _ title: L10n, _ tracks: [TrackID]) -> some View {
        let roles = tracks.map { model.studio?.session.track($0)?.role }
        return Toggle(
            title.key,
            isOn: Binding(
                get: { !roles.isEmpty && roles.allSatisfy { $0 == role } },
                set: { _ in model.setRole(role, tracks: tracks) })
        ).disabled(!model.canEdit)
    }
}

/// The content of the header context menu. SwiftUI builds it when the menu opens (ui-panel 8).
struct HeaderMenu: View {
    let model: SessionWindow
    let track: TrackID

    var body: some View {
        Button(L10n.menuTrackRemove.key) { model.removeFromHeader(track) }
            .onAppear { model.showHeaderMenu(track) }
        Menu(L10n.menuTrackRole.key) { RoleItems(model: model, headerRow: track) }
        Divider()
        Button(L10n.menuToolsTranscribe.key) { model.transcribeTrack(track) }.disabled(!model.canTranscribe)
    }
}

extension SessionWindow {
    /// One edit, so one undo entry and an autosave.
    func setRole(_ role: Track.Role?, tracks: [TrackID]) {
        edit(ripple: false) { session throws(SessionError) in try session.setRole(role, tracks: tracks) }
    }

    /// The tracks of the header menu of `track`: the selected tracks when the row is selected,
    /// else the track of the row.
    func headerMenuTracks(_ track: TrackID) -> [TrackID] {
        guard let studio else { return [] }
        let selected = timeline.selection.headerTracks(in: studio.session)
        return selected.contains(track) ? selected : [track]
    }

    /// The tracks of Track > Role: the header tracks of the selection.
    var roleMenuTracks: [TrackID] { studio.map { timeline.selection.headerTracks(in: $0.session) } ?? [] }
}
