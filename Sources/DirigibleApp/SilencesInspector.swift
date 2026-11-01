import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The Silences tab of the inspector (decision 0066): the settings, Scan, the summary, the rows
/// with the Action pop-up, Apply, and the note.
struct SilencesInspector: View {
    let model: SessionWindow
    let studio: Studio
    @FocusState private var keepFocus: Bool

    private var state: SilenceState { model.silences }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            settings
            Button((state.review == nil ? L10n.silencesScan : L10n.silencesScanAgain).key) {
                Task { await model.scanSilences() }
            }
            .disabled(!model.canScanSilences)
            if let review = state.review {
                if review.rows.isEmpty {
                    Text(verbatim: review.emptyText()).fixedSize(horizontal: false, vertical: true)
                } else {
                    list(review)
                }
            }
            if let note = state.note {
                Text(verbatim: note.text()).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("silences.note")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .font(.system(size: 11))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.silencesTracks.key).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(studio.session.tracks, id: \.id) { track in
                        Toggle(
                            isOn: Binding(
                                get: { !state.settings.unchecked.contains(track.id) },
                                set: { on in
                                    if on {
                                        state.settings.unchecked.remove(track.id)
                                    } else {
                                        state.settings.unchecked.insert(track.id)
                                    }
                                })
                        ) { Text(verbatim: track.name) }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 72)
            .help(L10n.silencesHelpTracks.text)
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    Text(L10n.silencesThreshold.key).lineLimit(1).fixedSize()
                    stepper(
                        Binding(get: { state.settings.threshold }, set: { state.settings.threshold = $0 }),
                        SilenceSettings.thresholds, step: 0.5, unit: .inspectorDecibels, help: .silencesHelpThreshold)
                }
                GridRow {
                    Text(L10n.silencesMinimum.key).lineLimit(1).fixedSize()
                    stepper(
                        Binding(
                            get: { Double(state.settings.minimum) },
                            set: { state.settings.minimum = Int($0) }),
                        Double(SilenceSettings.minimums.lowerBound)...Double(SilenceSettings.minimums.upperBound),
                        step: 500, unit: .inspectorMilliseconds, help: .silencesHelpMinimum)
                }
                GridRow {
                    Text(L10n.silencesKeep.key).lineLimit(1).fixedSize()
                    HStack(spacing: 4) {
                        TextField(
                            text: Binding(get: { state.keepText }, set: { state.setKeep($0) }),
                            label: { Text(L10n.silencesKeep.key) }
                        )
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
                        .focused($keepFocus)
                        .onSubmit { model.focusLanes() }
                        .accessibilityLabel(
                            Text(L10n.silencesKeep.key) + Text(verbatim: ", ") + Text(L10n.inspectorMilliseconds.key)
                        )
                        .help(L10n.silencesHelpKeep.text)
                        Text(L10n.inspectorMilliseconds.key).foregroundStyle(.secondary)
                    }
                }
            }
            if state.settings.keepRefused {
                Text(L10n.silencesKeepRefusal.key).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: keepFocus) { _, new in state.keepFocused = new }
    }

    private func stepper(
        _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: L10n, help: L10n
    ) -> some View {
        let shown = SilenceReview.plain(value.wrappedValue)
        return Stepper(value: value, in: range, step: step) {
            Text(verbatim: shown + " " + unit.text).monospacedDigit()
        }
        .accessibilityValue(Text(verbatim: shown + " " + unit.text))
        .help(help.text)
    }

    @ViewBuilder private func list(_ review: SilenceReview) -> some View {
        let summary = review.summary
        let count = { summary.counts[$0] ?? 0 }
        VStack(alignment: .leading, spacing: 2) {
            Text(
                verbatim: L10n.silencesSummaryCounts.format(
                    count(.shorten), count(.mute), count(.mark), count(.skip))
            )
            Text(
                verbatim: L10n.silencesSummaryTime.format(
                    SilenceReview.seconds(summary.removed, rate: review.rate),
                    SilenceReview.seconds(summary.length, rate: review.rate))
            )
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier("silences.summary")
        Picker(
            selection: Binding(
                get: { state.selectedAction },
                set: { if let action = $0 { model.setSilenceAction(action, rows: state.selection) } }),
            content: {
                if state.selectedAction == nil { Text(L10n.inspectorMixed.key).tag(SilenceAction?.none) }
                ForEach(SilenceAction.allCases, id: \.self) { action in
                    Text(action.title.key).tag(SilenceAction?.some(action))
                        .help(action == .mute ? L10n.silencesHelpMute.text : "")
                }
            }, label: { Text(L10n.silencesAction.key) }
        )
        .disabled(state.selection.isEmpty).help(L10n.silencesHelpAction.text)
        List(
            selection: Binding(get: { state.selection }, set: { model.selectSilences($0) })
        ) {
            ForEach(review.rows) { row in
                SilenceRowView(review: review, row: row) { model.setSilenceAction($0, rows: [row.id]) }.tag(row.id)
            }
        }
        .frame(minHeight: 120)
        .onKeyPress(.return) {
            guard model.canApplySilences else { return .ignored }
            model.applySilences()
            return .handled
        }
        .onDeleteCommand { model.setSilenceAction(.skip, rows: state.selection) }
        .accessibilityLabel(Text(L10n.inspectorTabSilences.key))
        HStack {
            Button(L10n.silencesApply.key) { model.applySilences() }.disabled(!model.canApplySilences)
            if state.isStale { Text(L10n.silencesStale.key).foregroundStyle(.secondary) }
        }
    }
}

/// One row of the list: its time, its length, and its action, with the reason when it starts as Mark.
private struct SilenceRowView: View {
    let review: SilenceReview
    let row: SilenceReview.Row
    let set: (SilenceAction) -> Void

    var body: some View {
        let length = row.silence.upperBound - row.silence.lowerBound
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(verbatim: SilenceReview.clock(row.silence.lowerBound, rate: review.rate)).monospacedDigit()
                Text(verbatim: SilenceReview.seconds(length, rate: review.rate)).monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.action.title.key)
            }
            if let reason = row.reason {
                Text(verbatim: SilenceReview.reasonText(reason)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: review.label(of: row)))
        .accessibilityActions {
            ForEach(SilenceAction.allCases, id: \.self) { action in Button(action.title.key) { set(action) } }
        }
    }
}
