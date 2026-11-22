import DirigibleCore
import Foundation

/// The session half of `pasteClipboard`: the target tracks, the new file records, the scale at
/// another rate, the map, and the paste, on a copy of the session.
struct PastePlan {
    var session: Session
    var clips: [ClipID] = []
    var tracks: [TrackID] = []
    /// The source record and the new record of each file to copy, in the order of the source IDs.
    var copies: [(record: AudioFile, copy: AudioFile)] = []

    /// `lengths` and `gains` are by source file ID. `stems` keeps the stems of an earlier plan.
    init(
        _ excerpt: Excerpt, same: Bool, into session: Session, in package: URL, mode: PasteMode,
        on target: PasteTarget, lengths: [FileID: Frames], gains: [FileID: Gain],
        stems: [FileID: String]?
    ) throws(SessionError) {
        self.session = session
        switch target {
        case .tracks(let ids): tracks = ids
        case .unselected where same: tracks = excerpt.lanes.map(\.source)
        case .unselected:
            for lane in excerpt.lanes {
                let id = TrackID()
                try self.session.addTrack(id, name: lane.name, layout: lane.layout)
                tracks.append(id)
            }
        }
        var pasted = excerpt
        if !same {
            if excerpt.sampleRate != session.sampleRate {
                pasted = excerpt.resampled(to: session.sampleRate, lengths: lengths, gains: gains)
            }
            var records: [FileID: AudioFile] = [:]
            for id in excerpt.files.keys.sorted() {
                guard let record = excerpt.files[id] else { continue }
                let stem =
                    stems?[id]
                    ?? importStem(of: URL(filePath: record.path), in: self.session, package: package, taken: [])
                let copy = AudioFile(
                    id: FileID(stem), path: "\(stem).wav", layout: record.layout, length: lengths[id] ?? record.length)
                try self.session.addFile(copy)
                records[id] = copy
                copies.append((record, copy))
            }
            pasted = try pasted.mapped(to: records)
        }
        clips = try self.session.paste(pasted, mode: mode, on: tracks)
    }
}
