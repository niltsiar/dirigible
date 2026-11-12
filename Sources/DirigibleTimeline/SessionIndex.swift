import DirigibleCore
import Foundation

/// The rows of the session index: the clips, markers, and chapters of a session in timeline order,
/// with the kind filter and the search of the index pane (run 2026-10-28-session-index-zoom).
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

        /// At one position a chapter comes first, then a marker, then a clip (decision U17).
        fileprivate var rank: Int { kind == .chapter ? 0 : kind == .marker ? 1 : 2 }
    }

    /// In timeline order: the position, then chapter, marker, clip, then the track order, then the ID.
    public let rows: [Row]

    public init(session: Session) {
        var keyed: [(row: Row, track: Int, id: String)] = []
        for (trackIndex, track) in session.tracks.enumerated() {
            for clip in track.clips {
                let name = ClipInspection.name(of: clip, in: session)
                let row = Row(
                    item: .clip(clip.id, track: track.name), name: name, position: clip.start,
                    searchText: Self.folded(name + "\n" + track.name))
                keyed.append((row, trackIndex, clip.id.rawValue))
            }
        }
        for marker in session.markers.values {
            let item: Item = marker.kind == .chapter ? .chapter(marker.id) : .marker(marker.id)
            let row = Row(
                item: item, name: marker.name, position: marker.position, searchText: Self.folded(marker.name))
            keyed.append((row, 0, marker.id.rawValue))
        }
        keyed.sort { ($0.row.position, $0.row.rank, $0.track, $0.id) < ($1.row.position, $1.row.rank, $1.track, $1.id) }
        rows = keyed.map(\.row)
    }

    /// The rows of one kind (all kinds for nil) whose name or track name has `search` as a
    /// substring, with no case and no diacritics. An empty search matches every row. The row `kept` always
    /// shows: the row of an open name field.
    public func rows(kind: Kind?, search: String, keeping kept: Pick? = nil) -> [Row] {
        let needle = Array(Self.folded(search).utf8)
        return rows.filter { row in
            row.id == kept
                || (kind == nil || row.kind == kind) && (needle.isEmpty || Self.contains(row.searchText, needle))
        }
    }

    /// A byte search: 12,250 rows with `String.contains` took 11.7 ms per key (run bench U2).
    private static func contains(_ text: String, _ needle: [UInt8]) -> Bool {
        var text = text
        return text.withUTF8 { haystack in
            needle.withUnsafeBufferPointer {
                memmem(haystack.baseAddress, haystack.count, $0.baseAddress, $0.count) != nil
            }
        }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
