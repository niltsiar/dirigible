import DirigibleAudio
import DirigibleCore

/// A row of the Bins list. The session rows come first, then the Favorites section (F23): its header,
/// then the favorites, or one note row. Each row names its source by its case.
enum BinsRow: Hashable {
    /// The header of a bin of the session.
    case bin(Bin)
    /// An item of a session bin, with the first media fault of its clips.
    case item(BinItem, fault: MediaFault?)
    /// The header of the Favorites section.
    case favoritesHeader
    /// A group of the store, shown only from its second group (C28).
    case favoriteGroup(Bin)
    /// A favorite, with the sample rate of the store for its length.
    case favorite(BinItem, rate: Int)
    /// "No Favorites" with its hint for nil, else the fault of the store read (C31, C38).
    case favoritesNote(StudioError?)

    /// The rows of `bins` in user order: each bin, then its items.
    static func rows(_ bins: [Bin], faults: [FileID: MediaFault]) -> [BinsRow] {
        bins.flatMap { bin in
            [.bin(bin)]
                + bin.items.map { item in
                    .item(item, fault: item.lanes.lazy.flatMap(\.clips).compactMap { faults[$0.file] }.first)
                }
        }
    }

    /// The Favorites section of the store as last read: the favorites flat while the store has one
    /// group, else a row for each group, then its favorites.
    static func favorites(_ state: FavoritesModel.State) -> [BinsRow] {
        switch state {
        case .fault(let error): return [.favoritesHeader, .favoritesNote(error)]
        case .loaded(let store):
            let favorites = { (bin: Bin) in bin.items.map { BinsRow.favorite($0, rate: store.sampleRate) } }
            switch store.bins.count {
            case 0: return [.favoritesHeader, .favoritesNote(nil)]
            case 1:
                let flat = favorites(store.bins[0])
                return [.favoritesHeader] + (flat.isEmpty ? [.favoritesNote(nil)] : flat)
            default: return [.favoritesHeader] + store.bins.flatMap { [.favoriteGroup($0)] + favorites($0) }
            }
        }
    }

    /// The selection of an item row; nil for a row that does not select.
    var pick: BinsPick? {
        switch self {
        case .item(let item, _): .session(item.id)
        case .favorite(let item, _): .favorite(item.id)
        case .bin, .favoritesHeader, .favoriteGroup, .favoritesNote: nil
        }
    }

    /// The rename that edits the name of this row; nil for a row with no name to edit.
    var rename: BinRename? {
        switch self {
        case .bin(let bin): .bin(bin.id)
        case .item(let item, _): .item(item.id)
        case .favoriteGroup(let bin): .favoriteBin(bin.id)
        case .favorite(let item, _): .favorite(item.id)
        case .favoritesHeader, .favoritesNote: nil
        }
    }
}
