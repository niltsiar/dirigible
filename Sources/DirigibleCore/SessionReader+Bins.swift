import Foundation

/// A `<bin>` of `<bins>` (F22) as the file holds it. `Session.addBins` adds it through the bin edits,
/// so each item clip gets the checks of a track clip.
struct ParsedBin {
    let id: BinID
    let name: String
    let items: [BinItem]

    /// The bins of `<bins>`, from `binSessionVersion` on, in file order. Empty with no element. The
    /// call comes before `RideLists.checkAllNamed`, so a list that only a bin clip names counts.
    static func list(in root: XMLElement, version: Int, rides: inout RideLists) throws(SessionFileError)
        -> [ParsedBin]
    {
        let elements = root.sessionElements("bins")
        guard elements.count <= 1 else { throw .invalidValue(element: "bins", attribute: "count") }
        guard let list = elements.first else { return [] }
        guard version >= binSessionVersion else { throw .invalidValue(element: "bins", attribute: "version") }
        var bins: [ParsedBin] = []
        for node in list.sessionElements("bin") {
            var items: [BinItem] = []
            for item in node.sessionElements("item") {
                items.append(try BinItem(item, version: version, rides: &rides))
            }
            bins.append(ParsedBin(id: BinID(try node.string("id")), name: try node.string("name"), items: items))
        }
        return bins
    }
}

extension BinItem {
    /// `<item id name kind length>` with its `<lane source name layout>` children.
    fileprivate init(_ node: XMLElement, version: Int, rides: inout RideLists) throws(SessionFileError) {
        let token = try node.string("kind")
        guard let kind = [Excerpt.Kind.range, .clips].first(where: { $0.fileToken == token }) else {
            throw .invalidValue(element: "item", attribute: "kind")
        }
        var lanes: [Excerpt.Lane] = []
        for lane in node.sessionElements("lane") {
            guard let layout = ChannelLayout(rawValue: try lane.string("layout")) else {
                throw .invalidValue(element: "lane", attribute: "layout")
            }
            var clips: [Clip] = []
            for clip in lane.sessionElements("clip") { clips.append(try Clip(clip, version: version, rides: &rides)) }
            lanes.append(
                Excerpt.Lane(
                    source: TrackID(try lane.string("source")), name: try lane.string("name"), layout: layout,
                    clips: clips))
        }
        self.init(
            id: BinItemID(try node.string("id")), name: try node.string("name"), kind: kind,
            length: try node.frames("length"), lanes: lanes)
    }
}

extension Session {
    /// Adds the read bins through `addBin` and `addItem`, after the files, origins, and drift links.
    mutating func addBins(_ bins: [ParsedBin]) throws(SessionError) {
        for bin in bins {
            try addBin(bin.id, named: bin.name)
            for item in bin.items {
                let excerpt = Excerpt(
                    kind: item.kind, length: item.length, lanes: item.lanes, sampleRate: sampleRate, pool: files)
                try addItem(excerpt, named: item.name, to: bin.id, id: item.id)
            }
        }
    }
}
