import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation
import SwiftUI

/// The result of the last archive or unarchive of the window and the session revision after it
/// (decision 0072).
struct ArchiveShown: Equatable {
    let kind: ArchiveRun.Kind
    let report: ArchiveReport
    let revision: Int

    /// The pool paths that the job kept as damaged, sorted.
    var damaged: [String] {
        report.kept.compactMap { path, reason in
            guard case .damaged = reason else { return nil }
            return path
        }.sorted()
    }
}

/// The FLAC files and the pool files of an archived session, for the subtitle.
struct ArchiveCounts: Equatable {
    let flac: Int
    let total: Int
}

/// The facts of the confirm sheet: the pool WAVs that convert, their bytes, and the disk need of
/// the unarchive after it.
struct ArchiveFacts: Equatable {
    let files: Int
    let bytes: Int64

    /// The unarchive need of decision 0072 with a FLAC of 0 private bytes: its upper bound.
    var unarchiveNeed: Int64 { bytes + diskMargin }
}

extension TimelineCommand {
    /// True when the command writes the session or reads the clip files in time, so an archived
    /// window unarchives first (decision 0072). A view change, a selection, a move to a marker or
    /// a gain point, and Show Clips in Finder run on the FLAC files.
    var unarchivesFirst: Bool {
        switch self {
        case .zoomIn, .zoomOut, .zoomToSession, .zoomToSelection, .zoomBack, .zoomForward, .pagePrevious, .pageNext,
            .toggleFollow, .tallerTracks, .shorterTracks, .fitTracks, .waveformZoomIn, .waveformZoomOut,
            .waveformZoomReset, .setIn, .setOut, .deselectAll, .selectAll, .previousMarker, .nextMarker,
            .previousGainPoint, .nextGainPoint, .showInFinder:
            false
        case .cut, .copy, .paste, .delete, .deleteCloseGap, .insert, .cutSelectedTracks, .deleteCloseGapSelectedTracks,
            .replace, .fill, .split, .nudgeLeft, .nudgeRight, .fade, .heal, .closeGaps, .rollToPlayhead, .slipLeft,
            .slipRight, .addMarker, .addChapter, .markerInfo, .moveMarker, .deleteMarker, .renameTrack, .removeTrack,
            .muteTracks, .soloTracks, .importAudio, .importTranscript, .importSession, .export, .exportSelection,
            .raiseVolume, .lowerVolume, .resetVolume, .exportChapters, .exportStems, .exportPresets, .exportTranscript,
            .episodeInfo, .autoLevel, .autoLevelPerTrack, .levelOverTime, .removeLevelOverTime, .duck, .splitStereo,
            .reduceNoise, .repairSound, .restoreOriginal, .transcribe, .useAsVoiceReference, .findSilences, .syncClip,
            .addGainPoint:
            true
        }
    }
}

extension SessionWindow {
    /// The one File menu item of the package jobs: Archive Session... or Unarchive Session.
    var archiveMenuTitle: L10n { studio?.isArchived == true ? .menuFileUnarchive : .menuFileArchive }

    /// File > Archive Session... or Unarchive Session.
    func toggleArchive() {
        guard let studio = idleStudio else { return }
        if studio.isArchived { unarchiveFirst(then: nil) } else { Task { await confirmArchive(studio) } }
    }

    /// The store refusal, then the confirm sheet, then the archive with the progress sheet. The
    /// store is the Favorites store of the app, by the path test of `Favorites.backups`.
    func confirmArchive(_ studio: Studio) async {
        commitDrafts()
        let store = app?.favorites.writer.map { ["DIRIGIBLE_FAVORITES": $0.store.path] } ?? [:]
        if Favorites.backups(for: studio.url, environment: store) == .store {
            alert = .error(.archive(.favoritesStore))
            return
        }
        let facts = await archiveFacts(of: studio.session, in: studio.url)
        guard let window else { return }
        let name = studio.url.deletingPathExtension().lastPathComponent
        guard await archiveQuestion(name: name, facts).beginSheetModal(for: window) == .alertFirstButtonReturn,
            idleStudio === studio, !studio.isArchived
        else { return }
        await runPackageJob(.archive, studio, then: nil)
    }

    /// Runs the unarchive with the progress sheet, then `command` once. The window keeps only
    /// the command: each replayed command reads the session and the disk again. A Cancel, a fault,
    /// or a disk refusal drops the command.
    func unarchiveFirst(then command: (@MainActor () -> Void)?) {
        guard let studio = idleStudio, studio.isArchived else { return }
        Task { await runPackageJob(.unarchive, studio, then: command) }
    }

    /// The Unarchive button of the archived banner and of the archived alert of an edit that no
    /// dispatch site held.
    func unarchive() { unarchiveFirst(then: nil) }

    /// The Cancel of the progress sheet of a package job: the job stops after the file in hand.
    func cancelPackageJob() { studio?.cancelArchive() }

    /// "Archiving file 12 of 40": the file in hand by the fraction of the files that the job
    /// converts.
    var archiveSheetTitle: String {
        let count = max(1, studio?.archiveProgress.files ?? 0)
        let number = min(count, Int((studio?.archiveProgress.fraction ?? 0) * Double(count)) + 1)
        let kind = studio?.archiveRun?.kind ?? .archive
        return (kind == .archive ? L10n.sheetArchiveFile : L10n.sheetUnarchiveFile).format(number, count)
    }

    /// The subtitle part of an archived studio: nil on a working window. It reads the disk only
    /// at a change of the session or after a job.
    func archiveCounts(_ studio: Studio) -> ArchiveCounts? {
        guard studio.isArchived, studio.archiveRun == nil else { return nil }
        if let cached = archiveCountsCache, cached.revision == studio.sessionRevision { return cached.counts }
        let paths = Set(studio.session.files.values.map(\.path))
        let flac = paths.count { poolFileName(path: $0, in: studio.url).form == .flac }
        let counts = ArchiveCounts(flac: flac, total: paths.count)
        archiveCountsCache = (studio.sessionRevision, counts)
        return counts
    }

    private func runPackageJob(
        _ kind: ArchiveRun.Kind, _ studio: Studio, then command: (@MainActor () -> Void)?
    ) async {
        archiveShown = nil
        archiveCountsCache = nil
        defer { archiveCountsCache = nil }
        do throws(StudioError) {
            let report =
                kind == .archive ? try await studio.archive { _ in } : try await studio.unarchive { _ in }
            archiveShown = ArchiveShown(kind: kind, report: report, revision: studio.sessionRevision)
            guard idleStudio === studio, !studio.isArchived else { return }
            command?()
        } catch .archive(.cancelled) {
            return
        } catch {
            guard case .open = phase else { return }
            alert = .error(error)
        }
    }
}

/// The progress sheet of a package job: "Archiving file 12 of 40", one bar, and Cancel, with
/// no Record. Esc gives Cancel.
struct ArchiveSheet: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: model.archiveSheetTitle).font(.headline)
            ProgressView(value: studio.archiveProgress.fraction).frame(width: 320)
            HStack {
                Spacer()
                Button(L10n.sheetExportCancel.key) { model.cancelPackageJob() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}

/// The confirm sheet of Archive Session..., in the shape of the Remove Unused Files sheet: Archive
/// is the first button and the default, and Esc gives Cancel.
@MainActor func archiveQuestion(name: String, _ facts: ArchiveFacts) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = L10n.alertArchiveTitle.format(name)
    alert.informativeText = L10n.alertArchiveBody.format(
        facts.files, L10n.bytes(facts.bytes), L10n.bytes(facts.unarchiveNeed))
    alert.addButton(withTitle: L10n.alertArchiveConfirm.text)
    alert.addButton(withTitle: L10n.alertCancel.text).keyEquivalent = "\u{1b}"
    return alert
}

/// The pool WAVs of `session` that the archive converts (`archiveSources`) and their bytes. It
/// reads the disk.
@concurrent func archiveFacts(of session: Session, in package: URL) async -> ArchiveFacts {
    var (files, bytes) = (0, Int64(0))
    for source in archiveSources(of: session, in: package).files {
        guard let size = try? source.wav.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
        files += 1
        bytes += Int64(size)
    }
    return ArchiveFacts(files: files, bytes: bytes)
}
