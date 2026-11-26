import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// One banner row (decision 0023): a symbol by kind, the text, an opaque 12 % tint of the kind
/// color over the window background, and a 1 pt separator. No shadow, no material, no animation.
/// VoiceOver reads the row as one element with the kind word first; its buttons stay separate.
struct BannerRow<Actions: View>: View {
    let kind: WindowBanner.Kind
    let text: String
    /// A second line in the secondary style.
    var detail: String? = nil
    /// The buttons at the trailing edge, on the tint. They are not in the one element of the text,
    /// so VoiceOver reaches each button (ui-polish-chrome U9).
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: kind.symbol).foregroundStyle(kind.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: text)
                    if let detail { Text(verbatim: detail).foregroundStyle(.secondary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: kind.label(detail.map { text + " " + $0 } ?? text)))
            actions
        }
        .padding(8)
        .background(kind.color.opacity(0.12))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
    }
}

extension BannerRow where Actions == EmptyView {
    init(kind: WindowBanner.Kind, text: String) { self.init(kind: kind, text: text) { EmptyView() } }
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
        ForEach(model.shown.banners, id: \.key) { banner in
            if case .takeSyncBroken(_, let from, _, let agent, let revision) = banner {
                // Only this row reads the studio state, so a play runs no body of a session without it.
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(agent.map { L10n.undoAgent.format($0) } ?? L10n.undoAgentUnnamed.text) {
                        model.undoAgentEdit(revision: revision)
                    }
                    .disabled(!model.canUndoAgentEdit(revision: revision))
                    Button(L10n.bannerTakeSyncShow.key) { model.transport(.seek(.frame(from))) }
                }
            } else if case .syncMoved(_, let revision?, _) = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.bannerSyncUndo.key) { model.undoAgentEdit(revision: revision) }
                        .disabled(!model.canUndoAgentEdit(revision: revision))
                }
            } else if case .syncNoMatch(let clip, let track, _, _, let drift, _) = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.bannerSyncChoose.key) {
                        model.chooseAnotherSyncTrack(for: clip, after: track, correctsDrift: drift)
                    }
                    .disabled(!model.canChooseAnotherSyncTrack(for: clip))
                }
            } else if case .exportReport(_, _, let url) = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.bannerExportSetShow.key) { model.showInFinder([url]) }
                }
            } else if case .exportSetDone(let files, _) = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.bannerExportSetShow.key) { model.showInFinder(files) }
                }
            } else if case .stemsDone(let folder, _) = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.bannerExportSetShow.key) { model.showInFinder([folder]) }
                }
            } else if case .archived = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.bannerArchiveUnarchive.key) { model.unarchive() }.disabled(!model.canEdit)
                }
            } else if case .transcriptionStopped = banner {
                BannerRow(kind: banner.kind, text: banner.text) {
                    Button(L10n.transcribeAgain.key) { model.transcribeAgain() }.disabled(!model.canTranscribe)
                }
            } else {
                BannerRow(kind: banner.kind, text: banner.text)
            }
        }
    }
}

/// The running job of Tools > Transcribe Track... (decision 0065, UI council C-4): the stage, the
/// percent, the elapsed time, a bar, and Cancel. The window stays editable.
struct TranscribeBanner: View {
    let model: SessionWindow

    var body: some View {
        if let job = model.transcribe.job {
            TimelineView(.periodic(from: .now, by: model.bannerTick)) { _ in
                let text = job.text + "  " + TakeBanner.elapsed(since: job.since)
                BannerRow(kind: .info, text: text, detail: job.hintText) {
                    ProgressView(value: job.fraction).frame(width: 160).accessibilityLabel(Text(verbatim: text))
                    Button(L10n.importCancel.key) { model.cancelTranscribe() }.keyboardShortcut(
                        ".", modifiers: .command)
                }
            }
        }
    }
}

extension SessionWindow {
    /// Undo `<agent>` Edit of a take sync row: on only while the studio is idle at `revision`, the
    /// revision of the agent edit, so it undoes that edit or nothing.
    func canUndoAgentEdit(revision: Int) -> Bool { idleStudio?.sessionRevision == revision }

    func undoAgentEdit(revision: Int) {
        if canUndoAgentEdit(revision: revision) { undo() }
    }
}

/// The take state: recording, finishing, pending, or the result of the last take.
struct TakeBanner: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        switch studio.transport {
        case .recording(let take):
            // The model reads stay here: a read in the 1 s content would register again each tick.
            let agent = model.agentRecord.take.flatMap { $0.take == take ? $0 : nil }
            let hasGrant = model.agentRecord.grant != nil
            let since = studio.recordingSince
            TimelineView(.periodic(from: .now, by: model.bannerTick)) { _ in
                let _ = model.countBannerRun()
                if let agent {
                    // An agent take (decision 0050): Stop, and Always Ask Again while a grant lives.
                    BannerRow(kind: .recording, text: model.agentTakeText(agent)) {
                        Button(L10n.transportStop.key) { Task { await model.stop() } }
                        if hasGrant {
                            Button(L10n.takeAgentAlwaysAsk.key) { model.alwaysAskAgain() }
                        }
                    }
                } else {
                    BannerRow(
                        kind: .recording, text: L10n.takeRecording.format(take) + "  " + Self.elapsed(since: since))
                }
            }
        case .finalizing(let take):
            BannerRow(kind: .info, text: L10n.takeFinishing.format(take))
        case .placing(let segment):
            BannerRow(kind: .info, text: L10n.takePlacing.format(segment.stem))
        case .leveling:
            BannerRow(kind: .info, text: L10n.takeLeveling.text) {
                // Also an agent level (decision 0049). Command-period is the Mac key of Cancel.
                Button(L10n.importCancel.key) { model.cancelReadJob() }.keyboardShortcut(".", modifiers: .command)
            }
        case .riding:
            BannerRow(kind: .info, text: L10n.takeRiding.text) {
                Button(L10n.importCancel.key) { model.cancelReadJob() }.keyboardShortcut(".", modifiers: .command)
            }
        case .matching:
            let text = L10n.takeMatching.text
            BannerRow(kind: .info, text: text) {
                // An agent match has no bar here: its progress goes to the agent (decision 0049).
                if let progress = model.matchProgress {
                    ProgressView(value: progress).frame(width: 160).accessibilityLabel(Text(verbatim: text))
                }
                Button(L10n.importCancel.key) { model.cancelReadJob() }.keyboardShortcut(".", modifiers: .command)
            }
        case .ducking:
            let text = L10n.takeDucking.text
            BannerRow(kind: .info, text: text) {
                // An agent duck has no bar here: its progress goes to the agent (decision 0049).
                if let progress = model.duckProgress {
                    ProgressView(value: progress).frame(width: 160).accessibilityLabel(Text(verbatim: text))
                }
                Button(L10n.importCancel.key) { model.cancelReadJob() }.keyboardShortcut(".", modifiers: .command)
            }
        case .findingSilences:
            BannerRow(kind: .info, text: L10n.takeFindingSilences.text) {
                Button(L10n.importCancel.key) { model.cancelReadJob() }.keyboardShortcut(".", modifiers: .command)
            }
        case .syncing:
            let text = L10n.takeSyncing.text
            BannerRow(kind: .info, text: text) {
                // An agent sync has no bar here: its progress goes to the agent (decision 0049).
                if let progress = model.syncProgress {
                    ProgressView(value: progress).frame(width: 160).accessibilityLabel(Text(verbatim: text))
                }
                Button(L10n.importCancel.key) { model.cancelReadJob() }.keyboardShortcut(".", modifiers: .command)
            }
        case .archiving:
            EmptyView()
        case .importing where model.importJob?.visible == false:
            EmptyView()  // A paste and a split show their banner after 0.5 s.
        case .importing(let run):
            let text = run.bannerText
            BannerRow(kind: .info, text: text) {
                // VoiceOver reads the bar with the banner text (ui-panel.md item 7).
                ProgressView(value: model.importBarProgress).frame(width: 160)
                    .accessibilityLabel(Text(verbatim: text))
                // Command-period is the Mac key of Cancel; a focused field does not take it.
                Button(L10n.importCancel.key) { model.cancelImport() }.keyboardShortcut(".", modifiers: .command)
            }
        case .idle:
            if let pending = studio.pendingTake {
                BannerRow(kind: .warning, text: pendingText(pending.take)) {
                    if model.canFinishLeavingUnreadable {
                        Button(L10n.menuRecordLeaveUnreadable.key) { Task { await model.finishLeavingUnreadable() } }
                    }
                    Button(L10n.menuRecordRetry.key) { Task { await model.retry() } }
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

    static func elapsed(since: ContinuousClock.Instant?, now: ContinuousClock.Instant = .now) -> String {
        guard let since else { return "" }
        let seconds = Int((now - since) / .seconds(1))
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
        var lines = studio.lastTake?.bannerLines { studio.session.track($0)?.name ?? $0.rawValue } ?? []
        if let take = studio.recoveredTake { lines.append(L10n.takeRecovered.format(take.take)) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension TakeResult {
    /// The rows of the take banner: the end, then a row for each gap, each track that dropped
    /// frames, and each track of a pre-roll take that started late. `name` gives a track name and
    /// `text` the value of a key.
    func bannerLines(name: (TrackID) -> String, text: (L10n) -> String = { $0.text }) -> [String] {
        func row(_ key: L10n, _ arguments: any CVarArg...) -> String {
            String(format: text(key), locale: .current, arguments: arguments)
        }
        var lines = [end == .diskLow ? row(.takeEndedDiskLow, take) : row(.takeEnded, take)]
        for (track, gap) in gaps.sorted(by: { $0.key < $1.key }) {
            lines.append(row(gap == .deviceLost ? .takeGapDeviceLost : .takeGapWriteFailed, name(track)))
        }
        for (track, frames) in droppedFrames.sorted(by: { $0.key < $1.key }) {
            lines.append(row(.takeDropped, name(track), frames))
        }
        for track in lateStarts.sorted() { lines.append(row(.takeLateStart, name(track))) }
        return lines
    }
}

extension ImportRun {
    /// The text of the banner of an import or of a paste from another package (decision 0042).
    var bannerText: String {
        switch kind {
        case .file, .session: L10n.importBanner.format(name)
        case .paste: L10n.pasteBanner.format(name)
        case .split: L10n.splitBanner.text
        case .clipRender: L10n.denoiseBanner.text
        case .drift: L10n.driftBanner.format(name)
        case .favorite: L10n.favoritesBanner.text
        }
    }
}
