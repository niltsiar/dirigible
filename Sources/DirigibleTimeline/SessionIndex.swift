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
        public fileprivate(set) var position: Frames
        /// The length of a clip, and for a chapter the time to the next chapter or to the session end.
        /// A marker has none.
        public fileprivate(set) var duration: Frames?
        /// The name, a line break, and the track name of a clip, folded once at the row build.
        fileprivate let searchText: String
        /// The track order of a clip, 0 for a marker.
        fileprivate let track: Int

        public var id: Pick { item.pick }

        public var kind: Kind {
            switch item {
            case .clip: .clip
            case .marker: .marker
            case .chapter: .chapter
            }
        }

        fileprivate var key: Key { SessionIndex.key(of: item, at: position, track: track) }
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
        var rows = keyed.map(\.row)
        Self.setChapterDurations(&rows, end: session.end)
        self.rows = rows
    }

    /// The most rows that the list removes and inserts: a larger change reloads the list.
    public static let updateLimit = 256

    /// The rows of `session` from `index`, the rows of `earlier`. Only the rows of the clips and
    /// markers that are new or changed are built again. A row whose clip or marker only moved keeps
    /// its name and takes the new position, so a ripple that moves thousands of rows builds none
    /// of them. A change of the files or of a track (the count, the order, a name) builds all rows.
    public init(session: Session, updating index: SessionIndex, of earlier: Session) {
        guard session.files == earlier.files, session.tracks.count == earlier.tracks.count,
            zip(session.tracks, earlier.tracks).allSatisfy({ $0.id == $1.id && $0.name == $1.name })
        else {
            self = SessionIndex(session: session)
            return
        }
        var moved: [Pick: Frames] = [:]
        var resized: [Pick: Frames] = [:]
        var gone: Set<Pick> = []
        var added: [Row] = []
        for (order, (track, old)) in zip(session.tracks, earlier.tracks).enumerated() where track.clips != old.clips {
            let (was, now) = (old.clips, track.clips)
            var head = 0
            while head < was.count, head < now.count, was[head].id == now[head].id,
                was[head].start == now[head].start, was[head].file == now[head].file,
                was[head].length == now[head].length
            {
                head += 1
            }
            // A clip row depends on the ID, the file, the start, and the length only.
            var tail = 0
            while tail < was.count - head, tail < now.count - head {
                let (before, after) = (was[was.count - 1 - tail], now[now.count - 1 - tail])
                guard before.id == after.id, before.file == after.file else { break }
                if before.start != after.start { moved[.clip(after.id)] = after.start }
                if before.length != after.length { resized[.clip(after.id)] = after.length }
                tail += 1
            }
            gone.formUnion(was[head..<was.count - tail].map { .clip($0.id) })
            added += now[head..<now.count - tail].map { Row(clip: $0, of: track, at: order, in: session) }
        }
        if session.markers != earlier.markers {
            for (id, marker) in earlier.markers where session.markers[id] != marker {
                if let after = session.markers[id], after.name == marker.name, after.kind == marker.kind {
                    moved[.marker(id)] = after.position
                } else {
                    gone.insert(.marker(id))
                }
            }
            for (id, marker) in session.markers {
                if let before = earlier.markers[id], before.name == marker.name, before.kind == marker.kind { continue }
                added.append(Row(marker: marker))
            }
        }
        // The kept rows stay in order. A ripple moves the later rows by one length, so the moved
        // rows stay in order too; a Close Gaps on some tracks can mix them.
        var kept: [Row] = []
        var shifted: [Row] = []
        kept.reserveCapacity(index.rows.count)
        for row in index.rows {
            if let position = moved[row.id] {
                var row = row
                row.position = position
                row.duration = resized[row.id] ?? row.duration
                shifted.append(row)
            } else if let length = resized[row.id] {
                var row = row
                row.duration = length
                kept.append(row)
            } else if !gone.contains(row.id) {
                kept.append(row)
            }
        }
        if !zip(shifted, shifted.dropFirst()).allSatisfy({ $0.key < $1.key }) { shifted.sort { $0.key < $1.key } }
        added.sort { $0.key < $1.key }
        var rows = Self.merged(Self.merged(kept, shifted), added)
        Self.setChapterDurations(&rows, end: session.end)
        self.rows = rows
    }

    /// Sets the duration of each chapter row: the time to the next chapter row, or to `end`, and
    /// 0 for a chapter at or after `end`. The pass runs at each update, as a clip that moves or
    /// resizes, or a chapter that moves, changes the duration of other rows.
    private static func setChapterDurations(_ rows: inout [Row], end: Frames) {
        var next = end
        for n in rows.indices.reversed() where rows[n].kind == .chapter {
            let position = rows[n].position
            rows[n].duration = next < position ? .zero : next - position
            next = position
        }
    }

    /// The rows of `first` and `second`, each in timeline order, in timeline order.
    private static func merged(_ first: [Row], _ second: [Row]) -> [Row] {
        if first.isEmpty || second.isEmpty { return first.isEmpty ? second : first }
        var rows: [Row] = []
        rows.reserveCapacity(first.count + second.count)
        var (i, j) = (0, 0)
        while i < first.count, j < second.count {
            if second[j].key < first[i].key {
                rows.append(second[j])
                j += 1
            } else {
                rows.append(first[i])
                i += 1
            }
        }
        rows += first[i...]
        rows += second[j...]
        return rows
    }

    /// The rows whose IDs differ between `old` and `new`: the ranges between their common start and
    /// their common end. A row outside the ranges keeps its ID, and can have a new name or position.
    public static func change(from old: [Row], to new: [Row]) -> (old: Range<Int>, new: Range<Int>) {
        var head = 0
        while head < old.count, head < new.count, old[head].id == new[head].id { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
            old[old.count - 1 - tail].id == new[new.count - 1 - tail].id
        {
            tail += 1
        }
        return (head..<old.count - tail, head..<new.count - tail)
    }

    /// The first of `picks` in timeline order, nil when no pick is in `session`. It builds no row.
    public static func first(of picks: Set<Pick>, in session: Session) -> Pick? {
        var first: (key: Key, pick: Pick)?
        func take(_ item: Item, at position: Frames, track: Int) {
            let key = Self.key(of: item, at: position, track: track)
            if first.map({ key < $0.key }) ?? true { first = (key, item.pick) }
        }
        for (order, track) in session.tracks.enumerated() {
            for clip in track.clips where picks.contains(.clip(clip.id)) {
                take(.clip(clip.id, track: track.name), at: clip.start, track: order)
            }
        }
        for marker in session.markers.values where picks.contains(.marker(marker.id)) {
            take(Item(marker), at: marker.position, track: 0)
        }
        return first?.pick
    }

    fileprivate static func key(of item: Item, at position: Frames, track: Int) -> Key {
        switch item {
        case .clip(let id, _): (position, 2, track, id.rawValue)
        case .marker(let id): (position, 1, track, id.rawValue)
        case .chapter(let id): (position, 0, track, id.rawValue)
        }
    }

    /// The rows of one kind (all kinds for nil) whose name or track name has `search` as a
    /// substring, with no case and no diacritics. An empty search matches every row. The row `kept` always
    /// shows: the row of an open name field.
    public func rows(kind: Kind?, search: String, keeping kept: Pick? = nil) -> [Row] {
        let needle = Array(Self.folded(search).utf8)
        // The same array, not a copy: the list compares it with the rows it shows.
        if kind == nil, needle.isEmpty { return rows }
        return rows.filter { Self.shows($0, kind: kind, needle: needle, keeping: kept) }
    }

    /// The picks of `picks` that `rows(kind:search:keeping:)` shows. It tests only the rows whose
    /// pick is in `picks`, in one pass; a pick with no row in the index stays.
    public func shownPicks(of picks: Set<Pick>, kind: Kind?, search: String, keeping kept: Pick? = nil) -> Set<Pick> {
        let needle = Array(Self.folded(search).utf8)
        if picks.isEmpty || kind == nil && needle.isEmpty { return picks }
        var shown = picks
        for row in rows where picks.contains(row.id) && !Self.shows(row, kind: kind, needle: needle, keeping: kept) {
            shown.remove(row.id)
        }
        return shown
    }

    private static func shows(_ row: Row, kind: Kind?, needle: [UInt8], keeping kept: Pick?) -> Bool {
        row.id == kept || (kind == nil || row.kind == kind) && (needle.isEmpty || contains(row.searchText, needle))
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
            item: .clip(clip.id, track: track.name), name: name, position: clip.start, duration: clip.length,
            searchText: SessionIndex.folded(name + "\n" + track.name), track: order)
    }

    fileprivate init(marker: Marker) {
        self.init(
            item: SessionIndex.Item(marker), name: marker.name,
            position: marker.position, duration: nil, searchText: SessionIndex.folded(marker.name), track: 0)
    }
}

extension SessionIndex.Item {
    fileprivate init(_ marker: Marker) { self = marker.kind == .chapter ? .chapter(marker.id) : .marker(marker.id) }

    fileprivate var pick: SessionIndex.Pick {
        switch self {
        case .clip(let id, _): .clip(id)
        case .marker(let id), .chapter(let id): .marker(id)
        }
    }
}
