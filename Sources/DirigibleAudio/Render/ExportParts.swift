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
    _ session: Session, range: Range<Frames>, by kind: SplitKind, options: ExportOptions, folder: URL, stem: String
) -> (targets: [ExportPartTarget], dropped: [Marker]) {
    let parts = session.exportParts(in: range, by: kind, introTitle: options.introTitle)
    let targets = parts.parts.map { part in
        let name = Session.partFileName(
            part, digits: parts.digits, stem: stem, pathExtension: options.format.pathExtension, limit: exportNameLimit)
        return ExportPartTarget(part: part, url: folder.appending(path: name))
    }
    return (targets, parts.dropped)
}

/// The old files of the stem: the items of `folder` whose name `Session.isPartFileName` matches
/// and that are not in `targets`, by name. It reads the folder, so call it off the main actor.
public func oldPartFiles(in folder: URL, stem: String, pathExtension: String, targets: [ExportPartTarget]) -> [URL] {
    let names = Set(targets.map(\.url.lastPathComponent))
    let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return items.filter { !names.contains($0) && Session.isPartFileName($0, stem: stem, pathExtension: pathExtension) }
        .sorted().map { folder.appending(path: $0) }
}

/// Exports one file for each part of `range` of `session`, split at `kind`, to the targets of
/// `exportPartTargets` (decision 0067). It computes the parts and the targets on `session`, so a
/// caller list of an older session only feeds `replacing`. First it checks every target: an item
/// that `replacing` does not hold as the same device and inode throws `.exists` with every such
/// path, and nothing is written. Then it calls `exportMix` for each part with `session.forPart`, so
/// each part file has its own loudness gain, title tag, and chapters. A stop or a failure in part k
/// throws `.stopped`: the files before part k stay, and part k leaves no file. `progress` gets the
/// fraction of the set by frames at each new whole percent and at the start of each part. `tracks`
/// is nil or not empty, as for `ExportSource`. Thread rule: as `exportMix`.
public func exportParts(
    _ session: Session, range: Range<Frames>, by kind: SplitKind, tracks: Set<TrackID>?, options: ExportOptions,
    folder: URL, stem: String, replacing: [URL: ConfirmedFile], package: () throws(SessionFileError) -> URL,
    progress: (ExportPartsProgress) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled }
) throws(ExportPartsError) -> ExportPartsResult {
    let (targets, dropped) = exportPartTargets(
        session, range: range, by: kind, options: options, folder: folder, stem: stem)
    guard !targets.isEmpty else { throw .noPoint(kind, range) }
    let existing = targets.map(\.url).filter { url in
        ConfirmedFile(at: url).map { replacing[url] != $0 } ?? false
    }
    guard existing.isEmpty else { throw .exists(existing) }
    let total = Double((range.upperBound - range.lowerBound).count)
    var written: [ExportedPart] = []
    var done = 0
    var percent = -1
    for (index, target) in targets.enumerated() {
        let part = target.part
        let length = (part.range.upperBound - part.range.lowerBound).count
        func report(_ fraction: Double) {
            percent = Int(fraction * 100)
            progress(
                ExportPartsProgress(
                    fraction: fraction, number: index + 1, count: targets.count, name: target.url.lastPathComponent))
        }
        func stop(_ error: ExportError) -> ExportPartsError {
            .stopped(ExportPartsStop(error: error, written: written, remaining: targets[index...].map(\.url)))
        }
        report(Double(done) / total)
        if isCancelled() { throw stop(.cancelled) }
        do {
            let result = try exportMix(
                session.forPart(part), source: ExportSource(range: part.range, tracks: tracks)!, options: options,
                to: target.url, replacing: replacing[target.url], package: package,
                progress: { fraction in
                    let set = (Double(done) + fraction * Double(length)) / total
                    if Int(set * 100) > percent { report(set) }
                }, isCancelled: isCancelled)
            written.append(ExportedPart(url: target.url, part: part, result: result))
        } catch {
            throw stop(error)
        }
        done += length
    }
    return ExportPartsResult(files: written, dropped: dropped)
}

extension ExportFormat {
    var pathExtension: String {
        switch self {
        case .wav: "wav"
        case .flac: "flac"
        case .aac: "m4a"
        case .mp3: "mp3"
        case .floatCAF: "caf"
        }
    }
}
