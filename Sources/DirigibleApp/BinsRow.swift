import DirigibleAudio
import DirigibleCore

/// A row of the Bins list: the header of a bin, or an item with the first media fault of its clips.
enum BinsRow: Hashable {
    case bin(Bin)
    case item(BinItem, fault: MediaFault?)

    /// The rows of `bins` in user order: each bin, then its items.
    static func rows(_ bins: [Bin], faults: [FileID: MediaFault]) -> [BinsRow] {
        bins.flatMap { bin in
            [.bin(bin)]
                + bin.items.map { item in
                    .item(item, fault: item.lanes.lazy.flatMap(\.clips).compactMap { faults[$0.file] }.first)
                }
        }
    }
}
