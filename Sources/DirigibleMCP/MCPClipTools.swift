import DirigibleCore
import Foundation

private let clip = Param.required("clip", "The clip ID.", .string)
private let file = Param.required("file", "The file ID.", .string)
private let start = Param.required("start", "The timeline frame of the first clip frame.", .integer())
private let length = Param.required("length", "The length in frames.", .integer())
private let offset = Param.defaulted("offset", "The file frame of the first clip frame.", .integer(), 0)
private let clipGain = Param.defaulted("db", "The gain in dB.", .gain, 0)
private let clipID = Param<String?>.optional("id", "The clip ID. The default is a new UUID.", .string)
private let tracks = Param.required("track", "The tracks: one or more.", .strings(minItems: 1))
private let at = Param.required("at", "The timeline frame.", .integer())
private let ats = Param.required("at", "The timeline frames: one or more.", .integers(minItems: 1))
private let rightID = Param<String?>.optional(
    "right_id", "The ID of the right part. The default is <clip>@<frame>.", .string)
private let onto = Param.defaulted(
    "onto", "A target track for each source track, in order. The default is the source tracks.", .strings(), [String]())
private let source = Param<String?>.optional(
    "source",
    "The absolute path of another session package to copy from. Its files are copied or converted into this "
        + "package. Give onto.", .string)
/// The note of a paste with `source` (decision 0042): the server answers each call in full.
private let sourceNote =
    " With source, the call copies or converts files; it runs to the end and saves, also when the client stops "
    + "waiting. Read session_info before a retry."
private let someClips = Param.defaulted("clips", "The clip IDs.", .strings(), [String]())
private let clips = Param.required("clips", "The clip IDs: one or more.", .strings(minItems: 1))
private let by = Param.required("by", "The frames to move; negative moves left.", .integer())
private let lanes = Param.defaulted("lanes", "The tracks to move; negative moves up.", .integer(), 0)
private let fadeIn = Param<Int?>.optional(
    "in", "The fade-in length in frames. The default is the current value.", .integer())
private let fadeOut = Param<Int?>.optional(
    "out", "The fade-out length in frames. The default is the current value.", .integer())
private let crossfade = Param.required(
    "length", "The crossfade length in frames, an even number.", .integer(minimum: 0))

extension Arguments {
    /// The paste from another package of `source` (decision 0042), or nil with no `source`. The
    /// path is absolute, as `package`, and another package needs `onto`.
    fileprivate func paste(_ selection: PasteWork.Selection, at frame: Frames, onto: [String]) throws(ToolError)
        -> PasteWork?
    {
        guard let path = try self[source] else { return nil }
        guard path.hasPrefix("/") else { throw ToolError("The argument \"source\" must be an absolute path.") }
        let url = URL(filePath: path)
        guard !EditRules.sourceNeedsOnto(source: url, target: URL(filePath: self.path), onto: onto) else {
            throw ToolError("Give onto with source of another package.")
        }
        return PasteWork(source: url, selection: selection, at: frame, onto: onto)
    }

    /// `from` and `to` (V19: `EditRules.frameRange`).
    func range() throws(ToolError) -> Range<Frames> {
        guard let range = EditRules.frameRange(from: try self[Arg.from], to: try self[Arg.to]) else {
            throw ToolError("from must not be more than to.")
        }
        return range
    }
}

let clipTools = [
    Tool(
        "clip_place", "Place a clip and give its ID. The clip overwrites the clips under it.",
        [Arg.track, file, start, length, offset, clipGain, clipID]
    ) { a throws(ToolError) in
        let placed = Clip(
            id: try a[clipID].map { ClipID($0) } ?? ClipID(), file: FileID(try a[file]), start: Frames(try a[start]),
            offset: Frames(try a[offset]), length: Frames(try a[length]), gain: try a[clipGain])
        let track = TrackID(try a[Arg.track])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.place(placed, on: track)
            return [placed.id.rawValue]
        }
    },
    Tool(
        "clip_clear", "Remove the frames in a range on each track and leave a gap. One save for all tracks.",
        [tracks, Arg.from, Arg.to]
    ) { a throws(ToolError) in
        let (range, targets) = (try a.range(), try a[tracks].map { TrackID($0) })
        return .edit(ripple: false) { session throws(SessionError) in
            try session.clear(range, on: targets)
            return []
        }
    },
    Tool("clip_split", "Split a clip and give the ID of the right part.", [clip, at, rightID]) { a throws(ToolError) in
        let (id, frame, right) = (ClipID(try a[clip]), Frames(try a[at]), try a[rightID].map { ClipID($0) })
        return .edit(ripple: false) { session throws(SessionError) in
            [try session.split(id, at: frame, rightID: right).rawValue]
        }
    },
    Tool(
        "clip_split_at", "Split each clip that holds a frame inside it, and give the IDs of the right parts.",
        [tracks, ats]
    ) { a throws(ToolError) in
        let (frames, targets) = (try a[ats].map { Frames($0) }, try a[tracks].map { TrackID($0) })
        return .edit(ripple: false) { session throws(SessionError) in
            try session.splitClips(at: frames, on: targets).map(\.rawValue)
        }
    },
    Tool(
        "clip_paste",
        "Copy a range of tracks and paste it at a frame over the clips there. Give the pasted IDs." + sourceNote,
        [Arg.from, Arg.to, tracks, at, onto, source]
    ) { a throws(ToolError) in
        let (range, sources, frame) = (try a.range(), try a[tracks], Frames(try a[at]))
        guard let targets = EditRules.pasteTargets(sources: sources, onto: try a[onto]) else {
            throw ToolError("Give one onto for each track, or none.")
        }
        if let work = try a.paste(.range(range, tracks: sources.map { TrackID($0) }), at: frame, onto: try a[onto]) {
            return .paste(work)
        }
        return .edit(ripple: false) { session throws(SessionError) in
            let excerpt = try session.excerpt(of: range, on: sources.map { TrackID($0) })
            return try session.paste(excerpt, at: frame, on: targets.map { TrackID($0) }).map(\.rawValue)
        }
    },
    Tool(
        "clip_paste_clips",
        "Copy whole clips with their time and track offsets, and paste them at a frame over the clips under "
            + "them. Give the pasted IDs." + sourceNote,
        [clips, at, onto, source]
    ) { a throws(ToolError) in
        let (ids, frame, targets) = (try a[clips].map { ClipID($0) }, Frames(try a[at]), try a[onto])
        if let work = try a.paste(.clips(ids), at: frame, onto: targets) { return .paste(work) }
        return .edit(ripple: false) { session throws(SessionError) in
            let excerpt = try session.excerpt(of: ids)
            return try session.paste(excerpt, at: frame, on: EditRules.laneTargets(of: excerpt, onto: targets))
                .map(\.rawValue)
        }
    },
    Tool(
        "clip_nudge", "Move clips by a number of frames and tracks. They overwrite the clips under them.",
        [someClips, by, lanes]
    ) { a throws(ToolError) in
        let (ids, frames, count) = (try a[someClips].map { ClipID($0) }, Frames(try a[by]), try a[lanes])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.nudge(ids, by: frames, lanes: count)
            return []
        }
    },
    Tool("clip_remove", "Remove clips and leave gaps.", [someClips]) { a throws(ToolError) in
        let ids = try a[someClips].map { ClipID($0) }
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeClips(ids)
            return []
        }
    },
    Tool(
        "clip_move", "Move a clip. It overwrites the clips under it at the new place.", [clip, Arg.track, start]
    ) { a throws(ToolError) in
        let (id, track, frame) = (ClipID(try a[clip]), TrackID(try a[Arg.track]), Frames(try a[start]))
        return .edit(ripple: false) { session throws(SessionError) in
            try session.move(id, to: track, start: frame)
            return []
        }
    },
    Tool("clip_trim", "Give a clip a new timeline range.", [clip, Arg.from, Arg.to]) { a throws(ToolError) in
        let (id, range) = (ClipID(try a[clip]), try a.range())
        return .edit(ripple: false) { session throws(SessionError) in
            try session.trim(id, to: range)
            return []
        }
    },
    Tool("clip_gain", "Set the gain of one or more clips in one edit.", [clips, Arg.gain]) { a throws(ToolError) in
        let (ids, gain) = (try a[clips], try a[Arg.gain])
        // V16: Dictionary(uniqueKeysWithValues:) traps on an ID that is given twice.
        if let twice = EditRules.firstRepeat(ids) { throw ToolError("Clip \"\(twice)\" is given twice.") }
        let gains = Dictionary(uniqueKeysWithValues: ids.map { (ClipID($0), gain) })
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setGains(gains)
            return []
        }
    },
    Tool(
        "clip_fade", "Set the fade-in or the fade-out of a clip in frames. 0 removes a fade.", [clip, fadeIn, fadeOut]
    ) { a throws(ToolError) in
        let (id, newIn, newOut) = (ClipID(try a[clip]), try a[fadeIn], try a[fadeOut])
        guard EditRules.fadeGiven(fadeIn: newIn, fadeOut: newOut) else { throw ToolError("Give in, out, or both.") }
        return .edit(ripple: false) { session throws(SessionError) in
            guard let current = session.clip(id)?.clip.fades else { throw .unknownClip(id) }
            let fades = Fades(
                fadeIn: newIn.map { Frames($0) } ?? current.fadeIn,
                fadeOut: newOut.map { Frames($0) } ?? current.fadeOut)
            guard let fades else { throw .frameOutOfRange }
            try session.setFades([id: fades])
            return []
        }
    },
    Tool(
        "clip_crossfade",
        "Set the crossfade at the end of a clip and the start of the clip that touches it, in frames. 0 removes it.",
        [clip, crossfade]
    ) { a throws(ToolError) in
        let id = ClipID(try a[clip])
        guard let frames = EditRules.crossfadeLength(try a[crossfade]) else {
            throw ToolError("A crossfade length is an even number of frames, 0 or more.")
        }
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setCrossfades([id: frames])
            return []
        }
    },
]
