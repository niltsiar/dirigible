import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The Gain at Playhead field of the Clip pane (decision 0060, C11): the envelope in dB of the clips
/// of the selected tracks at the playhead, and a typed value sets a point there. It has its own body,
/// so a playhead move runs this body and not the pane (W7). The field is off when no clip plays the
/// playhead, so it stays in the tab order and for VoiceOver.
struct PointGainField: View {
    let model: SessionWindow
    let studio: Studio
    var focus: FocusState<InspectorField?>.Binding
    /// False with no clip fields: the field then shows only when a clip plays the playhead.
    let alwaysShown: Bool

    var body: some View {
        let point = PointGain(at: studio.playhead, selection: model.timeline.selection, session: studio.session)
        if alwaysShown || point != nil { field(point) }
    }

    @ViewBuilder private func field(_ point: PointGain?) -> some View {
        let shown = InspectorView.pointText(point)
        let text = Binding(
            get: { model.inspectorDraft?.field == .pointGain ? model.inspectorDraft?.text ?? shown : shown },
            set: { model.type($0, in: .pointGain) })
        GridRow {
            Text(L10n.inspectorGainAtPlayhead.key).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                TextField(
                    text: text,
                    prompt: point?.gain == .mixed
                        ? Text(L10n.inspectorMixed.key) : Text(verbatim: InspectorView.emptyFieldPrompt)
                ) {
                    Text(L10n.inspectorGainAtPlayhead.key)
                }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .focused(focus, equals: .pointGain)
                .disabled(point == nil || !model.canEdit)
                .onSubmit {
                    model.commitInspector()
                    model.focusLanes()
                }
                .onExitCommand {
                    model.inspectorDraft = nil
                    model.focusLanes()
                }
                .accessibilityLabel(
                    Text(L10n.inspectorGainAtPlayhead.key) + Text(verbatim: ", ") + Text(L10n.inspectorDecibels.key))
                Text(L10n.inspectorDecibels.key).foregroundStyle(.secondary)
            }
            .gridColumnAlignment(.leading)
        }
    }
}

extension InspectorView {
    /// The prompt of an empty field: a dash, so the label does not show as the placeholder.
    static let emptyFieldPrompt = "\u{2013}"

    /// The text of the Gain at Playhead field: the envelope to 0.1 dB, empty for Mixed or no clip.
    static func pointText(_ point: PointGain?) -> String {
        guard case .value(let dB)? = point?.gain else { return "" }
        return ReadoutLayer.decibels(dB, locale: .current)
    }
}

extension SessionWindow {
    /// Edit > Add Gain Point: a point at the playhead on each clip of the selected tracks that plays
    /// it and has none there, with the value of its envelope, so no sample changes; one edit. Else a
    /// beep: no selected track, the playhead outside every clip, or a point at the playhead on each
    /// of them. Previous and Next Gain Point move the playhead to the nearest point of those clips,
    /// or beep with none. Each result is announced for VoiceOver.
    func runGainPoint(_ command: TimelineCommand, _ studio: Studio) {
        let selection = timeline.selection
        if command == .addGainPoint {
            guard let point = PointGain(at: studio.playhead, selection: selection, session: studio.session),
                let envelopes = PointGain.envelopes(nil, at: point.frame, for: point.clips, in: studio.session)
            else { return beep() }
            if edit(ripple: false, { s throws(SessionError) in try s.setEnvelopes(envelopes) }) != nil {
                announceGainPoint(.gainPointAdded, at: point.frame)
            }
            return
        }
        let forward = command == .nextGainPoint
        guard
            let frame = PointGain.neighbor(
                of: forward ? studio.playhead : studio.previousFrom, forward: forward, selection: selection,
                session: studio.session)
        else { return beep() }
        Task { await studio.perform(.seek(.frame(frame))) }
        announceGainPoint(.gainPointAt, at: frame)
    }

    /// Announces `format` with the envelope value at `frame` of the selected tracks, as the field shows it.
    func announceGainPoint(_ format: L10n, at frame: Frames) {
        guard let studio, let point = PointGain(at: frame, selection: timeline.selection, session: studio.session)
        else { return }
        let value =
            point.gain == .mixed
            ? L10n.inspectorMixed.text : InspectorView.pointText(point) + " " + L10n.inspectorDecibels.text
        chrome?.announce(format.format(value), .high)
    }
}
