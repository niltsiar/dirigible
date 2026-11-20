import DirigibleCore
import Foundation

/// One file of a split export and its path.
public struct ExportPartTarget: Hashable, Sendable {
    public let part: ExportPart
    public let url: URL
}

/// One file that a split export wrote.
public struct ExportedPart: Hashable, Sendable {
    public let url: URL
    public let part: ExportPart
    public let result: ExportResult
}

/// The files of a split export.
public struct ExportPartsResult: Hashable, Sendable {
    /// In part order; one file or more.
    public let files: [ExportedPart]
    /// The split points of the rendered session that have no file of their own.
    public let dropped: [Marker]

    /// The chapters that the file of `file` leaves out, except the split points in `dropped`: each of
    /// those has one warning of its own, so the part does not name it again.
    public func droppedChapters(of file: ExportedPart) -> [Marker] {
        let points = Set(dropped.map(\.id))
        return file.result.droppedChapters.filter { !points.contains($0.id) }
    }
}

/// A split export that stopped or failed after the check of its targets.
public struct ExportPartsStop: Hashable, Sendable {
    /// `.cancelled` for a stop: Cancel, a take, a close, or a cancel of the caller.
    public let error: ExportError
    /// The files on disk, in part order.
    public let written: [ExportedPart]
    /// The targets of the part in hand and of each part after it. An old item at each one stays.
    public let remaining: [URL]
}

public enum ExportPartsError: Error, Hashable, Sendable {
    /// An item is at each of these targets and `replacing` does not hold it. Nothing was written.
    case exists([URL])
    /// The rendered session has no split point of the kind in the range. Nothing was written.
    case noPoint(SplitKind, Range<Frames>)
    case stopped(ExportPartsStop)
}

/// The progress of a split export.
public struct ExportPartsProgress: Hashable, Sendable {
    /// The fraction of the set, by frames.
    public let fraction: Double
    /// The place of the part in hand in the set, from 1.
    public let number: Int
    public let count: Int
    /// The file name of the part in hand.
    public let name: String
}

/// The targets of a split export of `range` (decision 0067): one file for each part of
/// `Session.exportParts`, named by `Session.partFileName` in `folder`. The one owner of the target
/// URLs: the keys of `replacing` of `exportParts` come from it.
public func exportPartTargets(
    _ session: Session, range: Range<Frames>, by kind: SplitKind, options: ExportOptions, folder: URL, prefix: String
) -> (targets: [ExportPartTarget], dropped: [Marker]) {
    let parts = session.exportParts(in: range, by: kind, introTitle: options.introTitle)
    let targets = parts.parts.map { part in
        ExportPartTarget(
            part: part,
            url: folder.appending(path: exportPartFileName(part, of: parts, options: options, prefix: prefix)))
    }
    return (targets, parts.dropped)
}

/// The file name of `part` of `parts` (decision 0067): the one owner of the name that
/// `exportPartTargets` uses. A caller that holds the parts asks it for one name.
public func exportPartFileName(_ part: ExportPart, of parts: ExportParts, options: ExportOptions, prefix: String)
    -> String
{
    Session.partFileName(
        part, digits: parts.digits, prefix: prefix, pathExtension: options.format.pathExtension, limit: exportNameLimit)
}

/// The old files of the prefix: the items of `folder` whose name `Session.isPartFileName` matches
/// with the extension of `format`, and that are not in `besides`. It reads the folder, so call it off
/// the main actor.
public func oldPartFiles(in folder: URL, prefix: String, format: ExportFormat, besides names: Set<String>) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return items.filter {
        !names.contains($0) && Session.isPartFileName($0, prefix: prefix, pathExtension: format.pathExtension)
    }
    .sorted().map { folder.appending(path: $0) }
}

/// Exports one file for each part of `range` of `session`, split at `kind`, to the targets of
/// `exportPartTargets` (decision 0067). It computes the parts and the targets on `session`, so a
/// caller list of an older session only feeds `replacing`. First it checks every target: an item
/// that `replacing` does not hold as the same device and inode throws `.exists` with every such
/// path, and nothing is written. Then `exportItems` runs `exportMix` for each part with
/// `session.forPart`, so each part file has its own loudness gain, title tag, and chapters. A stop or a failure in part k
/// throws `.stopped`: the files before part k stay, and part k leaves no file. `progress` gets the
/// fraction of the set by frames at each new whole percent and at the start of each part. The source
/// of each part keeps the tracks of `source`. Thread rule: as `exportMix`.
public func exportParts(
    _ session: Session, source: ExportSource, by kind: SplitKind, options: ExportOptions, folder: URL, prefix: String,
    replacing: [URL: ConfirmedFile], package: () throws(SessionFileError) -> URL,
    progress: (ExportPartsProgress) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled }
) throws(ExportPartsError) -> ExportPartsResult {
    let range = source.range
    let (targets, dropped) = exportPartTargets(
        session, range: range, by: kind, options: options, folder: folder, prefix: prefix)
    guard !targets.isEmpty else { throw .noPoint(kind, range) }
    let items = targets.map {
        ExportItem(
            session: session.forPart($0.part), source: source.part($0.part.range), options: options, url: $0.url)
    }
    func parts(_ results: [ExportResult]) -> [ExportedPart] {
        zip(targets, results).map { ExportedPart(url: $0.url, part: $0.part, result: $1) }
    }
    do throws(ExportItemsError) {
        let results = try exportItems(
            items, replacing: replacing, package: package,
            progress: { fraction, index in
                progress(
                    ExportPartsProgress(
                        fraction: fraction, number: index + 1, count: targets.count,
                        name: targets[index].url.lastPathComponent))
            }, isCancelled: isCancelled)
        return ExportPartsResult(files: parts(results), dropped: dropped)
    } catch {
        switch error {
        case .exists(let urls): throw .exists(urls)
        case .stopped(let stop):
            throw .stopped(ExportPartsStop(error: stop.error, written: parts(stop.written), remaining: stop.remaining))
        }
    }
}

extension ExportFormat {
    /// The extensions of the formats that `export` writes: wav, flac, m4a, and mp3.
    public static let exportPathExtensions: Set<String> = Set(
        [ExportFormat.wav(.bits24), .flac(.bits24), .aac(.k128), .mp3(.k128)].map(\.pathExtension))

    /// The extension of the files of the format.
    public var pathExtension: String {
        switch self {
        case .wav: "wav"
        case .flac: "flac"
        case .aac: "m4a"
        case .mp3: "mp3"
        case .floatCAF: "caf"
        }
    }
}
