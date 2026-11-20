import DirigibleCore
import Foundation

/// One file of a set export: the session of the file, its source, its options, and its target.
struct ExportItem: Sendable {
    let session: Session
    let source: ExportSource
    let options: ExportOptions
    let url: URL
}

/// A set export that stopped or failed after the check of its targets.
struct ExportItemsStop: Sendable {
    /// `.cancelled` for a stop: Cancel, a take, a close, or a cancel of the caller.
    let error: ExportError
    /// The results of the files on disk, in item order.
    let written: [ExportResult]
    /// The targets of the item in hand and of each item after it. An old item at each one stays.
    let remaining: [URL]
}

enum ExportItemsError: Error {
    /// An item is at each of these targets and `replacing` does not hold it. Nothing was written.
    case exists([URL])
    case stopped(ExportItemsStop)
}

/// Exports each item with `exportMix`, in order, as one job: the one loop of the split export
/// (decision 0067) and the set exports. First it checks every target: an item that `replacing` does
/// not hold as the same device and inode throws `.exists` with every such path, and nothing is
/// written. A stop or a failure in item k throws `.stopped`: the files before item k stay, and item
/// k leaves no file. `progress` gets the fraction of the set, weighted by the frames of each item
/// source, and the index of the item in hand, at each new whole percent and at the start of each
/// item. Thread rule: as `exportMix`.
func exportItems(
    _ items: [ExportItem], replacing: [URL: ConfirmedFile], package: () throws(SessionFileError) -> URL,
    progress: (_ fraction: Double, _ index: Int) -> Void, isCancelled: () -> Bool
) throws(ExportItemsError) -> [ExportResult] {
    let existing = items.map(\.url).filter { url in
        ConfirmedFile(at: url).map { replacing[url] != $0 } ?? false
    }
    guard existing.isEmpty else { throw .exists(existing) }
    func length(_ item: ExportItem) -> Int { (item.source.range.upperBound - item.source.range.lowerBound).count }
    let total = Double(items.reduce(0) { $0 + length($1) })
    var written: [ExportResult] = []
    var done = 0
    var percent = -1
    for (index, item) in items.enumerated() {
        let length = length(item)
        func report(_ fraction: Double) {
            percent = Int(fraction * 100)
            progress(fraction, index)
        }
        func stop(_ error: ExportError) -> ExportItemsError {
            .stopped(ExportItemsStop(error: error, written: written, remaining: items[index...].map(\.url)))
        }
        report(Double(done) / total)
        if isCancelled() { throw stop(.cancelled) }
        do {
            let result = try exportMix(
                item.session, source: item.source, options: item.options, to: item.url,
                replacing: replacing[item.url], package: package,
                progress: { fraction in
                    let set = (Double(done) + fraction * Double(length)) / total
                    if Int(set * 100) > percent { report(set) }
                }, isCancelled: isCancelled)
            written.append(result)
        } catch {
            throw stop(error)
        }
        done += length
    }
    return written
}
