import Foundation

extension Session {
    /// `<bins>` (F22): one `<bin id name>` for each bin in list order, with one `<item id name kind
    /// length>` for each item, with one `<lane source name layout>` for each lane, with the `<clip>` of
    /// each clip. `rides` gives the `<rides>` list of a bin clip by its ride.
    func binsElement(rides: [GainEnvelope: Int]) -> XMLElement {
        let list = element("bins")
        for bin in bins {
            let binNode = element("bin", ("id", bin.id.rawValue), ("name", bin.name))
            for item in bin.items {
                let itemNode = element(
                    "item", ("id", item.id.rawValue), ("name", item.name), ("kind", item.kind.fileToken),
                    ("length", item.length.description))
                for lane in item.lanes {
                    let laneNode = element(
                        "lane", ("source", lane.source.rawValue), ("name", lane.name), ("layout", lane.layout.rawValue))
                    for clip in lane.clips { laneNode.addChild(clipElement(clip, ride: rides[clip.ride])) }
                    itemNode.addChild(laneNode)
                }
                binNode.addChild(itemNode)
            }
            list.addChild(binNode)
        }
        return list
    }
}

extension Excerpt.Kind {
    /// The `kind` token of `<item>`.
    var fileToken: String {
        switch self {
        case .range: "range"
        case .clips: "clips"
        }
    }
}
