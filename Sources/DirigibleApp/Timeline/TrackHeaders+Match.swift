import DirigibleCore
import SwiftUI

extension VoiceMatch.Amount {
    /// "75%", in the number format of the locale.
    static func text(_ percent: Int) -> String { percent.formatted(.percent) }
}

/// What the match mark of a header row shows (decision 0074). A track with no match and no read
/// has no mark.
enum MatchMarkState: Equatable {
    case learning
    case matched(VoiceMatch.Amount)
    case bypassed

    init?(_ match: VoiceMatch?, learning: Bool) {
        if learning {
            self = .learning
        } else if let match {
            self = match.isBypassed ? .bypassed : .matched(match.amount)
        } else {
            return nil
        }
    }

    /// The accessibility value of the mark. `text` gives the value of a key, so a test can read a table.
    func value(text: (L10n) -> String = { $0.text }) -> String {
        switch self {
        case .learning: text(.trackMatchValueLearning)
        case .bypassed: text(.trackMatchValueOff)
        case .matched(let amount): String(format: text(.trackMatchValueOn), VoiceMatch.Amount.text(amount.percent))
        }
    }

    /// The tooltip of the mark: "Voice matched to Dani, 75%".
    func help(reference: String, text: (L10n) -> String = { $0.text }) -> String {
        switch self {
        case .learning: value(text: text)
        case .bypassed: String(format: text(.trackMatchHelpOff), reference)
        case .matched(let amount):
            String(format: text(.trackMatchHelpOn), reference, VoiceMatch.Amount.text(amount.percent))
        }
    }
}

extension VoiceMatch {
    /// The first line of the popover: the stored reference name, and the largest boost and cut of
    /// the stored curve at the amount, to 0.1 dB.
    func title(locale: Locale = .current, text: (L10n) -> String = { $0.text }) -> String {
        let (boost, cut) = extremes(at: amount)
        return String(
            format: text(.trackMatchTitle), reference, L10n.matchDecibels(boost, locale: locale, text: text),
            L10n.matchDecibels(cut, locale: locale, text: text))
    }
}

/// The room that the glyphs of a header row take from its name, so the name gives way first at
/// each width gate (`HeaderRowTests`).
@MainActor enum HeaderGlyphs {
    static func room(_ track: Track, follow: Bool, marked: Bool) -> Double {
        (track.role == nil ? 0 : RoleGlyph.size + 8) + (follow ? FollowGlyph.size + 8 : 0)
            + (marked ? MatchMark.size + 8 : 0)
    }
}

/// The mark of a matched track in its header, after the name: a button that opens the popover. A
/// filled symbol is a match that plays, an outline in the secondary color is a bypassed match, and
/// a small progress wheel is the read of a match.
struct MatchMark: View {
    static let size = 14.0
    let model: SessionWindow
    let track: Track
    let state: MatchMarkState
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            symbol
        }
        .buttonStyle(.borderless)
        .frame(width: Self.size, height: Self.size)
        .disabled(track.match == nil || state == .learning || !model.canEdit)
        .help(Text(verbatim: state.help(reference: track.match?.reference ?? "")))
        .accessibilityLabel(Text(L10n.menuTrackMatch.key))
        .accessibilityValue(Text(verbatim: state.value()))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            if let match = track.match { MatchPopover(model: model, track: track.id, match: match) }
        }
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .learning: ProgressView().controlSize(.mini)
        case .matched: Image(systemName: "waveform.circle.fill").font(.system(size: 13)).foregroundStyle(.primary)
        case .bypassed: Image(systemName: "waveform.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

/// The popover of the mark: what the stored curve does at the amount, the Amount slider, Bypass,
/// and Remove. The header has no room for a slider (decision 0074, UI council ruling 1).
struct MatchPopover: View {
    let model: SessionWindow
    let track: TrackID
    let match: VoiceMatch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: match.title()).lineLimit(2).truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(L10n.trackMatchAmount.key)
                MatchAmountSlider(model: model, track: track, percent: match.amount.percent)
            }
            Toggle(
                L10n.trackMatchBypass.key,
                isOn: Binding(get: { match.isBypassed }, set: { model.setMatchBypassed($0, tracks: [track]) })
            ).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button(L10n.trackMatchRemove.key) {
                    dismiss()
                    model.removeMatch(tracks: [track])
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// Track > Match Voice and the same submenu of the header menu: the reference, the match, the
/// bypass, and Remove. Each item is off when it cannot act.
struct MatchItems: View {
    let model: SessionWindow
    /// The row of the header menu; nil for Track > Match Voice.
    let headerRow: TrackID?

    var body: some View {
        let tracks = headerRow.map(model.headerMenuTracks) ?? model.roleMenuTracks
        Button(L10n.menuTrackMatchReference.key) { model.run(.useAsVoiceReference) }
            .disabled(!model.isOn(.useAsVoiceReference))
        if let reference = model.activeVoiceReference {
            Button(L10n.menuTrackMatchTo.format(reference.name)) { Task { await model.matchVoice(tracks: tracks) } }
                .disabled(!model.canMatchVoice(tracks: tracks))
        } else {
            Button(L10n.menuTrackMatchToNone.key) {}.disabled(true).help(Text(L10n.trackMatchReferenceHelp.key))
        }
        Divider()
        Toggle(
            L10n.trackMatchBypass.key,
            isOn: Binding(get: { model.matchBypassed(tracks) }, set: { model.setMatchBypassed($0, tracks: tracks) })
        ).disabled(!model.canChangeMatch(tracks: tracks))
        Button(L10n.trackMatchRemove.key) { model.removeMatch(tracks: tracks) }
            .disabled(!model.canChangeMatch(tracks: tracks))
    }
}

extension SessionWindow {
    /// True when there is a match among `tracks` and each match is bypassed.
    func matchBypassed(_ tracks: [TrackID]) -> Bool {
        let matches = tracks.compactMap { studio?.session.track($0)?.match }
        return !matches.isEmpty && matches.allSatisfy(\.isBypassed)
    }
}
