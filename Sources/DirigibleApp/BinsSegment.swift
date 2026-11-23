import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The Bins segment of the leading pane (F22): the list of the bins and their items, then the
/// Favorites section (F23), and New Bin. A session with no bin shows "No Bins" with a New Bin button
/// (C31) above the list, which then holds the Favorites section only. The body reads the bins and the
/// media faults of the studio, and the store of the app, not the playhead. Each show reads the store
/// again, because another process can write it (C18).
struct BinsSegment: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        let bins = studio.session.bins
        let favorites = model.app.map { BinsRow.favorites($0.favorites.state) } ?? []
        VStack(spacing: 8) {
            if bins.isEmpty {
                ContentUnavailableView {
                    Text(L10n.binsEmpty.key)
                } description: {
                    Text(L10n.binsEmptyHint.key)
                } actions: {
                    Button(L10n.binsNew.key) { model.newBin() }.disabled(!model.canEdit)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            BinsTable(
                model: model, rows: BinsRow.rows(bins, faults: studio.missingMedia) + favorites,
                rate: studio.session.sampleRate)
            if !bins.isEmpty {
                HStack {
                    Button(L10n.binsNew.key) { model.newBin() }.disabled(!model.canEdit)
                    Spacer()
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.app?.favorites.reload() }
    }
}

/// The leading pane: the switch "Index" and "Bins" at the top, then only the shown segment (C19).
struct LeadingPane: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                selection: Binding(get: { model.leadingPane.segment }, set: { model.selectSegment($0) })
            ) {
                Text(L10n.indexSegmentIndex.key).tag(PaneSegment.index)
                Text(L10n.indexSegmentBins.key).tag(PaneSegment.bins)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 8)
            switch model.leadingPane.segment {
            case .index: SessionIndexView(model: model, studio: studio)
            case .bins: BinsSegment(model: model, studio: studio)
            }
        }
    }
}
