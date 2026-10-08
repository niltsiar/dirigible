import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// One banner row (decision 0023): a symbol by kind, the text, an opaque 12 % tint of the kind
/// color over the window background, and a 1 pt separator. No shadow, no material, no animation.
/// VoiceOver reads the row as one element with the kind word first; its buttons stay separate.
struct BannerRow: View {
    let kind: WindowBanner.Kind
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
            Text(verbatim: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(kind.color.opacity(0.12))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: kind.label(text)))
    }
}

extension WindowBanner.Kind {
    var color: Color {
        switch self {
        case .warning: .orange
        case .error, .recording: .red
        case .info: .secondary
        }
    }
}

/// The banner rows that the chrome loop writes on a change: no body here reads `Studio.play`.
struct WindowBanners: View {
    let model: SessionWindow

    var body: some View {
        let _ = model.countBody()
        ForEach(model.shown.banners, id: \.key) { banner in BannerRow(kind: banner.kind, text: banner.text) }
    }
}

/// The record-over warning (decisions 0016, 0017) over the top of the lanes. It shows only for a
/// clip that the lanes do not show. The clicks go through to the ruler and the lanes under it,
/// where the user acts on the warning.
struct RecordOverOverlay: View {
    let model: SessionWindow

    var body: some View {
        let _ = model.countBody()
        if model.shown.recordOver {
            let _ = model.countOverlay()
            BannerRow(kind: .warning, text: L10n.transportRecordOver.text).allowsHitTesting(false)
        }
    }
}

/// The take state: recording, finishing, pending, or the result of the last take.
struct TakeBanner: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        switch studio.transport {
        case .recording(let take):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                BannerRow(kind: .recording, text: L10n.takeRecording.format(take) + "  " + elapsed(at: context.date))
            }
        case .finalizing(let take):
            BannerRow(kind: .info, text: L10n.takeFinishing.format(take))
        case .placing(let segment):
            BannerRow(kind: .info, text: L10n.takePlacing.format(segment.stem))
        case .leveling:
            BannerRow(kind: .info, text: L10n.takeLeveling.text)
        case .importing where model.importJob?.visible == false:
            EmptyView()  // A paste shows its banner after 0.5 s.
        case .importing(let run):
            let text = run.bannerText
            HStack {
                BannerRow(kind: .info, text: text)
                // VoiceOver reads the bar with the banner text (ui-panel.md item 7).
                ProgressView(value: model.importJob?.progress ?? 0).frame(width: 160)
                    .accessibilityLabel(Text(verbatim: text))
                // Command-period is the Mac key of Cancel; a focused field does not take it.
                Button(L10n.importCancel.key) { model.cancelImport() }.keyboardShortcut(".", modifiers: .command)
                    .padding(.trailing)
            }
        case .idle:
            if let pending = studio.pendingTake {
                HStack {
                    BannerRow(kind: .warning, text: pendingText(pending.take))
                    if model.canFinishLeavingUnreadable {
                        Button(L10n.menuRecordLeaveUnreadable.key) { Task { await model.finishLeavingUnreadable() } }
                    }
                    Button(L10n.menuRecordRetry.key) { Task { await model.retry() } }.padding(.trailing)
                }
                .task(id: pending.take) { await model.refreshPendingSpace() }
            } else {
                if let text = resultText { BannerRow(kind: .info, text: text) }
                if !studio.unplacedSegments.isEmpty { unplacedRows }
            }
        }
    }

    /// One row for each unplaced segment (decision 0021), at most 4 in view; the list scrolls.
    private var unplacedRows: some View {
        let rowHeight = 28.0
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.takeUnplaced.key)
            if model.placeWaitsForRedo { Text(L10n.takeUnplacedRedo.key).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(studio.unplacedSegments, id: \.self) { segment in
                        HStack {
                            Text(verbatim: segment.stem)
                            Spacer()
                            Menu(L10n.menuUnplacedPlace.key) {
                                Button(L10n.menuUnplacedPlacePlayhead.key) {
                                    Task { await model.place(segment, atPlayhead: true) }
                                }
                                .disabled(!model.canPlaceAtPlayhead)
                            } primaryAction: {
                                Task { await model.place(segment, atPlayhead: false) }
                            }
                            .fixedSize()
                            .disabled(!model.canPlace)
                        }
                        .frame(height: rowHeight)
                    }
                }
            }
            .frame(height: rowHeight * Double(min(studio.unplacedSegments.count, 4)))
        }
        .padding(8)
        .background(Color.secondary.opacity(0.15))
    }

    private func elapsed(at date: Date) -> String {
        guard let since = studio.recordingSince else { return "" }
        let seconds = Int((ContinuousClock.now - since) / .seconds(1))
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }

    private func pendingText(_ take: Int) -> String {
        var lines = [L10n.takePending.format(take)]
        if let error = studio.takeError { lines.append(L10n.message(for: error, session: studio.session)) }
        if model.canFinishLeavingUnreadable { lines.append(L10n.takePendingLeaveHint.text) }
        if let space = model.pendingSpace {
            lines.append(L10n.takePendingSpace.format(L10n.bytes(space.needed), L10n.bytes(space.free)))
        }
        return lines.joined(separator: "\n")
    }

    /// The last take (gaps, dropped frames, a disk-low stop) and a recovered take.
    private var resultText: String? {
        let name = { (id: TrackID) in studio.session.track(id)?.name ?? id.rawValue }
        var lines: [String] = []
        if let take = studio.lastTake {
            lines.append(
                take.end == .diskLow ? L10n.takeEndedDiskLow.format(take.take) : L10n.takeEnded.format(take.take))
            for (track, gap) in take.gaps.sorted(by: { $0.key < $1.key }) {
                lines.append(
                    (gap == .deviceLost ? L10n.takeGapDeviceLost : L10n.takeGapWriteFailed).format(name(track)))
            }
            for (track, frames) in take.droppedFrames.sorted(by: { $0.key < $1.key }) {
                lines.append(L10n.takeDropped.format(name(track), frames))
            }
        }
        if let take = studio.recoveredTake { lines.append(L10n.takeRecovered.format(take.take)) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension ImportRun {
    /// The text of the banner of an import or of a paste from another package (decision 0042).
    var bannerText: String {
        switch kind {
        case .file: L10n.importBanner.format(name)
        case .paste: L10n.pasteBanner.format(name)
        }
    }
}
