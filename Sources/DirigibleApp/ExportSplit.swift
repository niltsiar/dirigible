import DirigibleAudio
import DirigibleCore
import Foundation

/// The Files pop-up of the Export save panel (decision 0067). It starts at `.one` at each panel
/// and is not stored.
enum ExportFiles: Hashable, CaseIterable {
    case one, chapters, markers

    var kind: SplitKind? {
        switch self {
        case .one: nil
        case .chapters: .chapters
        case .markers: .markers
        }
    }
}

/// What a split export needs from the save panel: the kind, the folder, and the prefix that the panel
/// name gives.
struct SplitTarget: Hashable {
    let kind: SplitKind
    let folder: URL
    let prefix: String

    /// The prefix of a panel name: the name without the extension of an export format. A split panel has
    /// no type, so it adds no extension, and a name field that showed `.wav` before a change of the
    /// format keeps it: the prefix drops it, whatever the format of now is.
    static func prefix(of name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ExportFormat.exportPathExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
    }
}

/// The source of a split export as the save panel sees it: the range and the parts of each kind. The
/// panel builds the parts once, so a tick of its line builds only the first file name.
struct ExportSplitPlan {
    let source: ExportSource
    let chapters: ExportParts
    let markers: ExportParts

    /// True for the Marks: the source names tracks.
    var isSelection: Bool { source.tracks != nil }

    func parts(_ kind: SplitKind) -> ExportParts {
        switch kind {
        case .chapters: chapters
        case .markers: markers
        }
    }

    /// The count of the files that a split writes.
    func count(_ kind: SplitKind) -> Int { parts(kind).parts.count }

    /// The help tag of an item with no point of its kind. Nil when the item is on.
    func help(_ kind: SplitKind) -> L10n? {
        guard count(kind) == 0 else { return nil }
        switch (kind, isSelection) {
        case (.chapters, true): return .panelExportFilesNoChaptersSelection
        case (.chapters, false): return .panelExportFilesNoChaptersSession
        case (.markers, true): return .panelExportFilesNoMarkersSelection
        case (.markers, false): return .panelExportFilesNoMarkersSession
        }
    }

    func title(_ files: ExportFiles) -> String {
        switch files {
        case .one: L10n.panelExportFilesOne.text
        case .chapters: L10n.panelExportFilesChapters.format(count(.chapters))
        case .markers: L10n.panelExportFilesMarkers.format(count(.markers))
        }
    }

    /// The line under the pop-ups: the count, the first file, and the prefix file that stays.
    func line(_ kind: SplitKind, options: ExportOptions, prefix: String, pathExtension: String) -> SplitLine? {
        let parts = parts(kind)
        guard let first = parts.parts.first else { return nil }
        return SplitLine(
            count: parts.parts.count, first: exportPartFileName(first, of: parts, options: options, prefix: prefix),
            prefixFile: "\(prefix).\(pathExtension)")
    }
}

extension ExportSplitPlan {
    /// The parts of `source` in the session of now.
    init(session: Session, source: ExportSource) {
        let intro = L10n.exportChapterIntro.text
        self.init(
            source: source,
            chapters: session.exportParts(in: source.range, by: .chapters, introTitle: intro),
            markers: session.exportParts(in: source.range, by: .markers, introTitle: intro))
    }
}

/// The three facts of the line under the pop-ups.
struct SplitLine: Equatable {
    let count: Int
    let first: String
    let prefixFile: String

    var text: String {
        count == 1
            ? L10n.panelExportLineOne.format(first, prefixFile) : L10n.panelExportLine.format(count, first, prefixFile)
    }
}

/// The result of the last split export, for its banners at its session revision (decision 0067).
struct ExportSetShown: Equatable {
    /// The files on disk, in part order.
    let files: [URL]
    /// The files of the set.
    let count: Int
    /// The loudness report of each file in `files`, or none when no target was on.
    let loudness: [LoudnessReport]
    /// The names of the files of the prefix that an older set wrote and this set did not.
    let old: [String]
    /// A file rendered as silence: the alert is the result, and the done banner shows only for older files.
    var faulty = false
    /// The tag warnings of the files that have one, each naming its file.
    var warnings: [ChapterWarningsShown] = []
    /// The split points with no file of their own.
    var dropped: [Marker] = []
    let revision: Int

    var stopped: Bool { files.count < count }

    /// What VoiceOver hears when the set ends. Nil after a stop: its banner says the count.
    var doneText: String? {
        guard !stopped else { return nil }
        let outputs = loudness.compactMap { $0.output?.value }
        return exportSetDoneText(files, outputs.min(), outputs.max())
    }

    /// The banners of the set. A stop gives only the count banner. A finished set gives the done banner
    /// (a warning when older files of the prefix stay), and a banner for each file with a gain over the limit.
    /// A fault with no older file removes the done banner: the alert names the parts.
    var banners: [WindowBanner] {
        guard !stopped else { return [.exportSetStopped(written: files.count, count: count)] }
        var banners: [WindowBanner] = faulty && old.isEmpty ? [] : [.exportSetDone(files: files, old: old)]
        for (url, report) in zip(files, loudness) where report.exceedsLevelLimit {
            banners.append(.exportReport(report, file: url.lastPathComponent, url: url))
        }
        return banners + dropped.map { .exportSetDropped($0) } + warnings.flatMap(\.banners)
    }
}

extension L10n {
    /// A loudness in LUFS with one decimal, in the number format of `locale`.
    static func loudnessNumber(_ value: Double, locale: Locale = .current) -> String {
        String(format: "%.1f", locale: locale, value)
    }

    /// "a, b, c, d, e and 2 more": the first five names, then the rest as a count.
    static func firstNames(_ names: [String]) -> String {
        let (shown, more) = nameList(names)
        return shown.joined(separator: ", ") + (more > 0 ? " " + exportNamesMore.format(more) : "")
    }

    /// The first five names and the count of the others.
    static func nameList(_ names: [String]) -> (shown: [String], more: Int) {
        (Array(names.prefix(5)), max(0, names.count - 5))
    }

    /// "Exported 10 files to Episode 12.": the count of a finished set and the name of its folder.
    static func exportSetDoneText(_ files: [URL]) -> String {
        let folder = files.first?.deletingLastPathComponent().lastPathComponent ?? ""
        return files.count == 1
            ? bannerExportSetDoneOne.format(folder) : bannerExportSetDone.format(files.count, folder)
    }

    /// The sentence about the older files of the prefix that stay.
    static func oldFilesText(_ old: [String]) -> String {
        old.count == 1
            ? bannerExportSetOldOne.format(firstNames(old)) : bannerExportSetOldMany.format(old.count, firstNames(old))
    }
}
