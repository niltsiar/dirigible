import DirigibleAudio
import DirigibleCore

/// The edits and the list of `dirigible bin` and its tools (F22): the one owner of the argument rules
/// and the texts. Each edit runs on the session of a package under the lock, or on the session of an
/// open window as one undo step, and gives the lines that the command prints.
package enum BinWork {
    package typealias Edit = @Sendable (inout Session) throws(SessionError) -> [String]

    /// The excerpt of `bin item-add`: a range of tracks, or whole clips.
    package enum Selection: Sendable {
        case range(Range<Frames>, tracks: [TrackID])
        case clips([ClipID])
    }

    /// `from`, `to`, and one or more tracks give a range; one or more clips give whole clips. Any
    /// other mix is a usage error.
    package static func selection(from: Int?, to: Int?, tracks: [String], clips: [String], spelling: OptionSpelling)
        throws(ToolError) -> Selection
    {
        switch (from, to, tracks.isEmpty, clips.isEmpty) {
        case (nil, nil, true, false):
            return .clips(clips.map { ClipID($0) })
        case (let from?, let to?, false, true):
            guard let range = EditRules.frameRange(from: from, to: to) else {
                throw ToolError("\(spelling("from")) must not be more than \(spelling("to")).")
            }
            return .range(range, tracks: tracks.map { TrackID($0) })
        default:
            let clip = spelling == .cli ? "--clip" : "clips"
            throw ToolError("Give \(spelling("from")), \(spelling("to")), and \(spelling("track")), or \(clip).")
        }
    }

    /// Adds the excerpt of `selection` to `bin` as a new item. Gives the item ID.
    package static func addItem(_ selection: Selection, named name: String, to bin: String) -> Edit {
        let id = BinItemID()
        return { session throws(SessionError) in
            let excerpt =
                switch selection {
                case .range(let range, let tracks): try session.excerpt(of: range, on: tracks)
                case .clips(let ids): try session.excerpt(of: ids)
                }
            return [try session.addItem(excerpt, named: name, to: BinID(bin), id: id).rawValue]
        }
    }

    /// Pastes the item of this session with `mode` on the source tracks of its lanes, or on `onto`.
    /// Gives the pasted IDs.
    package static func paste(_ item: String, mode: PasteMode, onto: [String]) -> Edit {
        { session throws(SessionError) in
            let excerpt = try session.excerpt(of: BinItemID(item))
            return try session.paste(excerpt, mode: mode, on: EditRules.laneTargets(of: excerpt, onto: onto))
                .map(\.rawValue)
        }
    }

    /// The text of `bin list`: a `bin` line for each bin in list order, each followed by an `item`
    /// line for each of its items; `No bins.` with no bin. A name is in Swift string quotes.
    package static func list(_ session: Session) -> String {
        guard !session.bins.isEmpty else { return "No bins." }
        return session.bins.flatMap { bin in
            ["bin \(bin.id) \(String(reflecting: bin.name))"]
                + bin.items.map { item in
                    let kind = item.kind == .range ? "range" : "clips"
                    let tracks = item.lanes.map(\.source.rawValue).joined(separator: ",")
                    return "item \(item.id) \(String(reflecting: item.name)) \(kind) length \(item.length.count) "
                        + "tracks \(tracks)"
                }
        }.joined(separator: "\n")
    }
}
