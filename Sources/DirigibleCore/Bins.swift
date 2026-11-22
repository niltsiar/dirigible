import Foundation

public typealias BinID = ID<Bin>
public typealias BinItemID = ID<BinItem>

/// A named group of stored excerpts of the session (F22). `Session.bins` is in the order that the user
/// sees.
public struct Bin: Hashable, Sendable {
    public let id: BinID
    public internal(set) var name: String
    public internal(set) var items: [BinItem] = []
}

/// A stored excerpt. It holds only what `<item>` of `session.xml` holds, so a session equals its
/// read-back: no file record and no transcript word. `Session.excerpt(of:)` gives the excerpt with the
/// pool records at the paste time. A clip of an item holds its file, as a clip of a track (decision 0024).
public struct BinItem: Hashable, Sendable {
    public let id: BinItemID
    public internal(set) var name: String
    public let kind: Excerpt.Kind
    public let length: Frames
    public let lanes: [Excerpt.Lane]
}

/// The bin edits. Each is one session edit, so one undo entry. A name is trimmed; a name with a
/// character that `checkText` refuses throws `.invalidText`, and an empty name `.emptyName`. Two bins
/// or two items can have one name. A throw changes nothing.
extension Session {
    @discardableResult
    public mutating func addBin(_ id: BinID = BinID(), named name: String) throws(SessionError) -> BinID {
        let name = try Self.binName(name)
        try Self.checkText(id.rawValue)
        guard !bins.contains(where: { $0.id == id }) else { throw .duplicateID(id.rawValue) }
        bins.append(Bin(id: id, name: name))
        return id
    }

    public mutating func renameBin(_ id: BinID, to name: String) throws(SessionError) {
        let name = try Self.binName(name)
        bins[try binIndex(id)].name = name
    }

    /// Moves the bin to `index` of the list after the move.
    public mutating func moveBin(_ id: BinID, to index: Int) throws(SessionError) {
        let from = try binIndex(id)
        guard bins.indices.contains(index) else { throw .binIndexOutOfRange(index) }
        bins.insert(bins.remove(at: from), at: index)
    }

    /// Removes the bin and its items.
    public mutating func removeBin(_ id: BinID) throws(SessionError) {
        bins.remove(at: try binIndex(id))
    }

    /// Adds the kind, the length, and the lanes of `excerpt` at the end of `bin`. It refuses an excerpt
    /// at another rate, a used ID, a clip whose file record differs from the pool record (`.foreignFile`),
    /// and a lane that a track with its layout could not hold: each clip passes the checks of a track
    /// clip and ends at or before the excerpt length, and the clips of a lane are in start order with no
    /// overlap, so a damaged `<item>` refuses its file at the read. A crossfade with no partner stays, as
    /// in the excerpt: a paste repairs it.
    @discardableResult
    public mutating func addItem(_ excerpt: Excerpt, named name: String, to bin: BinID, id: BinItemID = BinItemID())
        throws(SessionError) -> BinItemID
    {
        let name = try Self.binName(name)
        try Self.checkText(id.rawValue)
        let index = try binIndex(bin)
        guard excerpt.sampleRate == sampleRate else { throw .otherSampleRate(excerpt.sampleRate) }
        guard excerpt.length.isInRange else { throw .frameOutOfRange }
        guard !bins.contains(where: { $0.items.contains { $0.id == id } }) else { throw .duplicateID(id.rawValue) }
        for lane in excerpt.lanes {
            try Self.checkText(lane.source.rawValue, lane.name)
            let track = Track(id: lane.source, name: lane.name, layout: lane.layout)
            for clip in lane.clips {
                if let record = excerpt.files[clip.file], let present = files[clip.file], present != record {
                    throw .foreignFile(clip.file)
                }
                try check(clip, on: track)
                guard clip.end <= excerpt.length else { throw .clipPastItemEnd(clip.id) }
            }
            for (left, right) in zip(lane.clips, lane.clips.dropFirst()) where right.start < left.end {
                throw .overlap(right.id, left.id)
            }
        }
        bins[index].items.append(
            BinItem(id: id, name: name, kind: excerpt.kind, length: excerpt.length, lanes: excerpt.lanes))
        return id
    }

    public mutating func renameItem(_ id: BinItemID, to name: String) throws(SessionError) {
        let name = try Self.binName(name)
        let (bin, item) = try itemPosition(id)
        bins[bin].items[item].name = name
    }

    public mutating func removeItem(_ id: BinItemID) throws(SessionError) {
        let (bin, item) = try itemPosition(id)
        bins[bin].items.remove(at: item)
    }

    /// The excerpt of the item with the current pool records and transcript words of its files, as
    /// `excerpt(of:on:)` gives them.
    public func excerpt(of id: BinItemID) throws(SessionError) -> Excerpt {
        let (bin, index) = try itemPosition(id)
        let item = bins[bin].items[index]
        let named = Set(item.lanes.flatMap { $0.clips.map(\.file) })
        return Excerpt(
            kind: item.kind, length: item.length, lanes: item.lanes, sampleRate: sampleRate, pool: files,
            transcripts: transcripts(copiedFor: named))
    }

    /// The files of the clips of the tracks and of the bins: a file that one of them names is in use.
    var clipFiles: Set<FileID> {
        var used = Set(tracks.flatMap { $0.clips.map(\.file) })
        for lane in bins.lazy.flatMap(\.items).flatMap(\.lanes) { used.formUnion(lane.clips.lazy.map(\.file)) }
        return used
    }

    private static func binName(_ name: String) throws(SessionError) -> String {
        try checkText(name)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .emptyName }
        return trimmed
    }

    private func binIndex(_ id: BinID) throws(SessionError) -> Int {
        guard let index = bins.firstIndex(where: { $0.id == id }) else { throw .unknownBin(id) }
        return index
    }

    private func itemPosition(_ id: BinItemID) throws(SessionError) -> (bin: Int, item: Int) {
        for (bin, group) in bins.enumerated() {
            if let item = group.items.firstIndex(where: { $0.id == id }) { return (bin, item) }
        }
        throw .unknownBinItem(id)
    }
}
