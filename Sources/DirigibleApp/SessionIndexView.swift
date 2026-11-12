import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The leading pane of a session window (decision 0023): the segment switch, the search field, the
/// kind filter, and the list of the index. Its body reads the rows only through
/// `LeadingPaneState.sessionIndex(for:)`: it never reads the playhead or a field of
/// `SessionWindow.timeline`, which a lane scroll writes.
struct SessionIndexView: View {
    static let searchIdentifier = "index.search"

    let model: SessionWindow
    let studio: Studio

    /// What the list shows in place of rows.
    enum Empty: Equatable {
        case none, session, noResults

        /// An empty session shows its hint; rows hidden by the filter or the search show the
        /// no-results text.
        init(rows: Int, of all: Int) { self = rows > 0 ? .none : all == 0 ? .session : .noResults }
    }

    var body: some View {
        let pane = model.leadingPane
        let _ = pane.countBody()
        let index = pane.sessionIndex(for: studio.session)
        let rows = index.rows(kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        VStack(spacing: 8) {
            if Self.showsSwitch(segments: LeadingPaneState.Segment.allCases.count) {
                Picker(selection: Bindable(pane).segment) {
                    ForEach(LeadingPaneState.Segment.allCases, id: \.self) {
                        Text(L10n.indexSegmentIndex.key).tag($0)
                    }
                } label: {
                    Text(L10n.indexSegmentIndex.key)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            TextField(L10n.indexSearchPlaceholder.key, text: Bindable(pane).search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(Self.searchIdentifier)
                .onKeyPress(.escape) {
                    model.escapeInIndexSearch()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    model.focusFirstIndexRow()
                    return .handled
                }
            IndexKindFilter(kind: Bindable(pane).kind)
            SessionIndexTable(model: model, pane: pane, rows: rows, rate: studio.session.sampleRate)
                .overlay { emptyView(Empty(rows: rows.count, of: index.rows.count), search: pane.search) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: pane.search) { pane.table?.mark.holdFollow(.search) }
    }

    /// A switch with one segment is a control with one option: it shows from two segments.
    static func showsSwitch(segments: Int) -> Bool { segments > 1 }

    /// The text of the empty session with the key of Add Marker, as the menu shows it.
    static func hint(text: (L10n) -> String = { $0.text }) -> String {
        String(
            format: text(.indexEmptyHint), locale: .current,
            keyText(WindowCommand.timeline(.addMarker).menuItem.key))
    }

    @ViewBuilder private func emptyView(_ empty: Empty, search: String) -> some View {
        switch empty {
        case .none: EmptyView()
        case .session:
            ContentUnavailableView {
                Text(L10n.indexEmptySession.key)
            } description: {
                Text(verbatim: Self.hint())
            }
        case .noResults: ContentUnavailableView.search(text: search)
        }
    }
}

/// The kind filter: four segments, the text "All" and the glyphs for Clips, Markers,
/// and Chapters, each with a label and a help tag. Under the width that the segments need, a
/// pull-down menu with the same four choices.
struct IndexKindFilter: View {
    @Binding var kind: SessionIndex.Kind?

    /// The four choices: nil is All. A choice with a symbol shows it in place of its title.
    static let choices: [(kind: SessionIndex.Kind?, title: L10n, symbol: String?)] = [
        (nil, .indexFilterAll, nil), (.clip, .indexFilterClips, "waveform"), (.marker, .menuMarkers, "flag"),
        (.chapter, .indexFilterChapters, "bookmark"),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            IndexKindSegments(kind: $kind)
            Picker(selection: $kind) {
                ForEach(Self.choices, id: \.title) { Text($0.title.key).tag($0.kind) }
            } label: {
                Text(L10n.indexFilterAll.key)
            }
            .pickerStyle(.menu).labelsHidden()
        }
    }
}

/// The segments as an `NSSegmentedControl`, so each glyph has its accessibility description and
/// its help tag.
private struct IndexKindSegments: NSViewRepresentable {
    @Binding var kind: SessionIndex.Kind?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = IndexKindFilter.choices.count
        control.trackingMode = .selectOne
        control.controlSize = .small
        for (n, choice) in IndexKindFilter.choices.enumerated() {
            let title = choice.title.text
            if let symbol = choice.symbol {
                control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: n)
            } else {
                control.setLabel(title, forSegment: n)
            }
            control.setToolTip(title, forSegment: n)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.pick(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.kind = $kind
        let selected = IndexKindFilter.choices.firstIndex { $0.kind == kind } ?? 0
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }

    /// The pane asks again at each list update: the segments keep the size of the first measure.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        if context.coordinator.fitting == nil { context.coordinator.fitting = nsView.fittingSize }
        return context.coordinator.fitting
    }

    @MainActor final class Coordinator: NSObject {
        var kind: Binding<SessionIndex.Kind?>?
        var fitting: CGSize?

        @objc func pick(_ control: NSSegmentedControl) {
            kind?.wrappedValue = IndexKindFilter.choices[control.selectedSegment].kind
        }
    }
}
