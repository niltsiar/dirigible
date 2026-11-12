import DirigibleCore
import Foundation

/// The rows of the session index: the clips, markers, and chapters of a session in timeline order,
/// with the kind filter and the search of the index pane.
public struct SessionIndex: Equatable, Sendable {
    /// The kind of a row, for the kind filter.
    public enum Kind: CaseIterable, Sendable { case clip, marker, chapter }

    public enum Item: Hashable, Sendable {
        case clip(ClipID, track: String)
        case marker(MarkerID)
        case chapter(MarkerID)
    }

    /// The row that the selection or the current marker shows (`TimelineState.selectedRow`).
    public enum Pick: Hashable, Sendable {
        case clip(ClipID)
        case marker(MarkerID)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let item: Item
        public let name: String
        public let position: Frames
        /// The name, a line break, and the track name of a clip, folded once at the row build.
        fileprivate let searchText: String
        /// The track order of a clip, 0 for a marker.
        fileprivate let track: Int

        public var id: Pick {
            switch item {
            case .clip(let id, _): .clip(id)
            case .marker(let id), .chapter(let id): .marker(id)
            }
        }

        public var kind: Kind {
            switch item {
            case .clip: .clip
            case .marker: .marker
            case .chapter: .chapter
            }
        }

        fileprivate var key: Key {
            switch item {
            case .clip(let id, _): (position, 2, track, id.rawValue)
            case .marker(let id): (position, 1, track, id.rawValue)
            case .chapter(let id): (position, 0, track, id.rawValue)
            }
        }
    }

    /// The timeline order of a row: the position, then chapter, marker, clip, then the
    /// track order, then the ID.
    fileprivate typealias Key = (position: Frames, rank: Int, track: Int, id: String)

    /// In timeline order (`Key`).
    public let rows: [Row]

    public init(session: Session) {
        var keyed: [(key: Key, row: Row)] = []
        for (order, track) in session.tracks.enumerated() {
            for clip in track.clips {
                let row = Row(clip: clip, of: track, at: order, in: session)
                keyed.append((row.key, row))
            }
        }
        for marker in session.markers.values {
            let row = Row(marker: marker)
            keyed.append((row.key, row))
        }
        keyed.sort { $0.key < $1.key }
        rows = keyed.map(\.row)
    }

    /// The most rows that an update removes and adds: a larger change builds all rows, and the
    /// list reloads.
    public static let updateLimit = 256

    /// The rows of `session` from `index`, the rows of `earlier`: only the rows of the clips and
    /// markers that changed are built again, and each goes to its place in the order. A change of the
    /// files or of a track (the count, the order, a name) builds all rows.
    public init(session: Session, updating index: SessionIndex, of earlier: Session) {
        guard session.files == earlier.files, session.tracks.count == earlier.tracks.count,
            zip(session.tracks, earlier.tracks).allSatisfy({ $0.id == $1.id && $0.name == $1.name })
        else {
            self = SessionIndex(session: session)
            return
        }
        var gone: [Key] = []
        var added: [Row] = []
        for (order, (track, old)) in zip(session.tracks, earlier.tracks).enumerated() where track.clips != old.clips {
            let change = Self.change(from: old.clips, to: track.clips) {
                $0.id == $1.id && $0.start == $1.start && $0.file == $1.file
            }
            gone += old.clips[change.old].map { Row(clip: $0, of: old, at: order, in: earlier).key }
            added += track.clips[change.new].map { Row(clip: $0, of: track, at: order, in: session) }
        }
        if session.markers != earlier.markers {
            for (id, marker) in earlier.markers where session.markers[id] != marker {
                gone.append(Row(marker: marker).key)
            }
            for (id, marker) in session.markers where earlier.markers[id] != marker {
                added.append(Row(marker: marker))
            }
        }
        guard gone.count + added.count <= Self.updateLimit else {
            self = SessionIndex(session: session)
            return
        }
        var rows = index.rows
        for key in gone { rows.remove(at: Self.place(of: key, in: rows)) }
        for row in added { rows.insert(row, at: Self.place(of: row.key, in: rows)) }
        self.rows = rows
    }

    /// The rows that differ between `old` and `new`: the ranges between their common start and their common end.
    public static func change(from old: [Row], to new: [Row]) -> (old: Range<Int>, new: Range<Int>) {
        change(from: old, to: new, same: ==)
    }

    private static func change<C: RandomAccessCollection>(from old: C, to new: C, same: (C.Element, C.Element) -> Bool)
        -> (old: Range<Int>, new: Range<Int>) where C.Index == Int
    {
        var head = 0
        while head < old.count, head < new.count, same(old[head], new[head]) { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
            same(old[old.count - 1 - tail], new[new.count - 1 - tail])
        {
            tail += 1
        }
        return (head..<old.count - tail, head..<new.count - tail)
    }

    /// The index of the first row at or after `key`.
    private static func place(of key: Key, in rows: [Row]) -> Int {
        var (low, high) = (0, rows.count)
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].key < key { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The rows of one kind (all kinds for nil) whose name or track name has `search` as a
    /// substring, with no case and no diacritics. An empty search matches every row. The row `kept` always
    /// shows: the row of an open name field.
    public func rows(kind: Kind?, search: String, keeping kept: Pick? = nil) -> [Row] {
        let needle = Array(Self.folded(search).utf8)
        // The same array, not a copy: the list compares it with the rows it shows.
        if kind == nil, needle.isEmpty { return rows }
        return rows.filter { row in
            row.id == kept
                || (kind == nil || row.kind == kind) && (needle.isEmpty || Self.contains(row.searchText, needle))
        }
    }

    /// A byte search: 12,250 rows with `String.contains` took 11.7 ms per key.
    private static func contains(_ text: String, _ needle: [UInt8]) -> Bool {
        var text = text
        return text.withUTF8 { haystack in
            needle.withUnsafeBufferPointer {
                memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil
            }
        }
    }

    fileprivate static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension SessionIndex.Row {
    fileprivate init(clip: Clip, of track: Track, at order: Int, in session: Session) {
        let name = ClipInspection.name(of: clip, in: session)
        self.init(
            item: .clip(clip.id, track: track.name), name: name, position: clip.start,
            searchText: SessionIndex.folded(name + "\n" + track.name), track: order)
    }

    fileprivate init(marker: Marker) {
        self.init(
            item: marker.kind == .chapter ? .chapter(marker.id) : .marker(marker.id), name: marker.name,
            position: marker.position, searchText: SessionIndex.folded(marker.name), track: 0)
    }
}
