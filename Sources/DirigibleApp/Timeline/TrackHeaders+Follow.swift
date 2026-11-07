import DirigibleCore
import SwiftUI

/// The mark of a follow track in its header (decision 0073): the SF Symbol `link` after the role
/// glyph. A shape, so the state does not depend on color alone. It is no button: the Track menu and
/// the header action change the flag.
struct FollowGlyph: View {
    static let size = 14.0

    var body: some View {
        Image(systemName: "link")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: Self.size, height: Self.size)
            .help(Text(L10n.trackFollowHelp.key))
            .accessibilityElement()
            .accessibilityLabel(Text(L10n.trackFollowLabel.key))
            .accessibilityValue(Text(L10n.trackFollowValue.key))
    }
}

/// Track > Follow in Ripples and the same item in the header menu. It is checked when each track
/// of the menu follows.
struct FollowItem: View {
    let model: SessionWindow
    /// The row of the header menu; nil for the Track menu.
    let headerRow: TrackID?

    var body: some View {
        let tracks = headerRow.map(model.headerMenuTracks) ?? model.roleMenuTracks
        Toggle(
            L10n.menuTrackFollowRipples.key,
            isOn: Binding(
                get: { model.follows(tracks) },
                set: { on in model.setFollowTrack(on, tracks: tracks) })
        ).disabled(!model.canEdit)
    }
}

extension SessionWindow {
    /// True when there is a track and each track follows ripples.
    func follows(_ tracks: [TrackID]) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { studio?.session.track($0)?.isFollowTrack == true }
    }

    /// One edit, so one undo entry and an autosave.
    func setFollowTrack(_ on: Bool, tracks: [TrackID]) {
        edit(ripple: false) { session throws(SessionError) in try session.setFollowTrack(on, tracks: tracks) }
    }

    /// The button of the follow alert: the named track stops following. The ripple does not run again.
    func turnOffFollow(in alert: WindowAlert) {
        guard case .followOverlap(let overlap) = alert else { return }
        self.alert = nil
        setFollowTrack(false, tracks: [overlap.track])
    }
}
