import DirigibleAudio
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
private let targetAt = Param.required("at", "The first frame of the target range.", .integer())
private let until = Param.required("until", "The frame after the last frame of the target range.", .integer())
private let source = Param<String?>.optional(
    "source",
    "The absolute path of another session package to copy from. Its files are copied or converted into this "
        + "package. Give onto.", .string)
/// The note of a paste with `source` (decision 0042): the server answers each call in full.
private let sourceNote =
    " With source, the call copies or converts files; it runs to the end and saves, also when the client stops "
    + "waiting. Read session_info before a retry."
private let reduction = Param<NoiseReduction?>.optional(
    "reduction", "The noise reduction in dB, 1 to 30. The default is 12. Not with noise false.", .reduction)
private let hum = Param<Hum?>.optional(
    "hum", "Remove mains hum at this frequency in Hz, 50 or 60, and its harmonics. The default is no hum removal.",
    .hum)
private let noise = Param.defaulted(
    "noise", "Reduce the noise. False needs hum and removes a stored noise reduction.", .boolean, true)
private let rumble = Param<Int?>.optional(
    "rumble",
    "Reduce rumble with a high-pass filter at this frequency in Hz, \(Rumble.range.lowerBound) to "
        + "\(Rumble.range.upperBound). The standard value is \(Rumble.standard.hertz). The default is no rumble reduction.",
    .integer(in: Rumble.range))
private let clipping = Param<Int?>.optional(
    "clipping",
    "Repair clipped peaks. A sample at or over this percent of the peak of the run, \(Declip.range.lowerBound) to "
        + "\(Declip.range.upperBound), is a clip candidate. The standard value is \(Declip.standard.percent). The "
        + "default is no repair of clipped peaks.",
    .integer(in: Declip.range))
private let sibilance = Param<Int?>.optional(
    "sibilance",
    "Soften \"s\" sounds by a largest cut in dB, \(DeEss.decibelRange.lowerBound) to "
        + "\(DeEss.decibelRange.upperBound). The standard value is \(DeEss.standard.decibels). The default is no "
        + "softening.",
    .integer(in: DeEss.decibelRange))
private let sibilanceHertz = Param<Int?>.optional(
    "sibilance_hz",
    "The frequency of the sibilance repair in Hz, \(DeEss.hertzRange.lowerBound) to \(DeEss.hertzRange.upperBound). "
        + "The standard value is \(DeEss.standard.hertz). Needs sibilance.",
    .integer(in: DeEss.hertzRange))
private let someClips = Param.defaulted("clips", "The clip IDs.", .strings(), [String]())
private let clips = Param.required("clips", "The clip IDs: one or more.", .strings(minItems: 1))
private let by = Param.required("by", "The frames to move; negative moves left.", .integer())
private let lanes = Param.defaulted("lanes", "The tracks to move; negative moves up.", .integer(), 0)
private let mode = Param.defaulted(
    "mode", "overwrite, no-overlap, or crossfade. no-overlap refuses a cover; crossfade crossfades each covered join.",
    .choice(EditRules.overlapModeWords, EditRules.overlapMode), "overwrite")
private let fadeIn = Param<Int?>.optional(
    "in", "The fade-in length in frames. The default is the current value.", .integer())
private let fadeOut = Param<Int?>.optional(
    "out", "The fade-out length in frames. The default is the current value.", .integer())
private let crossfade = Param.required(
    "length", "The crossfade length in frames, an even number.", .integer(minimum: 0))
private let healTracks = Param<[String]?>.optional(
    "track", "Only these tracks. The default is all tracks.", .strings(minItems: 1))
private let healFrom = Param<Int?>.optional(
    "from", "Only the joins from this timeline frame. Give it with to.", .integer())
private let healTo = Param<Int?>.optional(
    "to", "Only the joins to this timeline frame, a join at this frame too. Give it with from.", .integer())

/// The `onto` and `source` arguments of each paste tool (decision 0042), and the note of `source`.
extension Arg {
    static let pasteOnto = onto
    static let pasteSource = source
    static let pasteSourceNote = sourceNote
}

extension Arguments {
    /// The paste from another package of `source` (decision 0042), or nil with no `source`. The
    /// path is absolute, as `package`, and another package needs `onto`.
    func paste(_ selection: PasteWork.Selection, mode: PasteMode, onto: [String]) throws(ToolError)
        -> PasteWork?
    {
        guard let path = try self[source] else { return nil }
        guard path.hasPrefix("/") else { throw ToolError("The argument \"source\" must be an absolute path.") }
        let url = URL(filePath: path)
        guard !EditRules.sourceNeedsOnto(source: url, target: URL(filePath: self.path), onto: onto) else {
            throw ToolError("Give onto with source of another package.")
        }
        return PasteWork(source: url, selection: selection, mode: mode, onto: onto)
    }

    /// `clip_replace` and `clip_fill`: the range `from` to `to` of `track`, put on the range `at` to
    /// `until` with `mode`, in one edit, or the paste of `source`.
    fileprivate func rangePaste(_ mode: (Range<Frames>) -> PasteMode) throws(ToolError) -> ToolWork {
        let (range, sources) = (try self.range(), try self[tracks])
        guard let target = EditRules.targetRange(at: try self[targetAt], until: try self[until]) else {
            throw ToolError("at must be less than until.")
        }
        guard let targets = EditRules.pasteTargets(sources: sources, onto: try self[onto]) else {
            throw ToolError("Give one onto for each track, or none.")
        }
        let mode = mode(target)
        if let work = try paste(.range(range, tracks: sources.map { TrackID($0) }), mode: mode, onto: try self[onto]) {
            return .paste(work)
        }
        return .edit(ripple: RippleNeed { _ in mode.ripples }) { session throws(SessionError) in
            let excerpt = try session.excerpt(of: range, on: sources.map { TrackID($0) })
            return try session.paste(excerpt, mode: mode, on: targets.map { TrackID($0) }).map(\.rawValue)
        }
    }

    /// `from` and `to` (V19: `EditRules.frameRange`).
    func range() throws(ToolError) -> Range<Frames> {
        guard let range = EditRules.frameRange(from: try self[Arg.from], to: try self[Arg.to]) else {
            throw ToolError("from must not be more than to.")
        }
        return range
    }
}

/// Restore Original of `clips` (decision 0057), for `dirigible clip restore` and `clip_restore`: the
/// IDs of the clips on a rendered file, which move to the roots of their chains, or "No rendered
/// clip." when there is none.
package func restoredClips(_ clips: [ClipID], in session: inout Session) throws(SessionError) -> [String] {
    let rendered = clips.filter { !session.origins(of: $0).isEmpty }
    try session.restoreOriginals(clips)
    return rendered.isEmpty ? ["No rendered clip."] : rendered.map(\.rawValue)
}

let clipTools = [
    Tool(
        "clip_place", "Place a clip and give its ID. The clip overwrites the clips under it.",
        [Arg.track, file, start, length, offset, clipGain, clipID], batch: .step
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
        [tracks, Arg.from, Arg.to], batch: .step
    ) { a throws(ToolError) in
        let (range, targets) = (try a.range(), try a[tracks].map { TrackID($0) })
        return .edit(ripple: false) { session throws(SessionError) in
            try session.clear(range, on: targets)
            return []
        }
    },
    Tool("clip_split", "Split a clip and give the ID of the right part.", [clip, at, rightID], batch: .step) {
        a throws(ToolError) in
        let (id, frame, right) = (ClipID(try a[clip]), Frames(try a[at]), try a[rightID].map { ClipID($0) })
        return .edit(ripple: false) { session throws(SessionError) in
            [try session.split(id, at: frame, rightID: right).rawValue]
        }
    },
    Tool(
        "clip_split_at", "Split each clip that holds a frame inside it, and give the IDs of the right parts.",
        [tracks, ats], batch: .step
    ) { a throws(ToolError) in
        let (frames, targets) = (try a[ats].map { Frames($0) }, try a[tracks].map { TrackID($0) })
        return .edit(ripple: false) { session throws(SessionError) in
            try session.splitClips(at: frames, on: targets).map(\.rawValue)
        }
    },
    Tool(
        "clip_split_stereo",
        "Split stereo clips into two mono tracks, as dirigible clip split-stereo: for each run of clips of one file, "
            + "two mono 24-bit WAVs in Clips/ with a handle of 10 s on each side, and under each source track two mono "
            + "tracks named \"<name> L\" and \"<name> R\". The source clips go; the source track and its file stay. "
            + "A clip on a mono track is refused. Give one line for each clip: the left clip, the right clip, the "
            + "left track, and the right track, with a tab between them." + editCancelNote("no track is added"),
        [clips], batch: .alone
    ) { a throws(ToolError) in
        .splitStereo(SplitWork(clips: try a[clips].map { ClipID($0) }))
    },
    Tool(
        "clip_paste",
        "Copy a range of tracks and paste it at a frame over the clips there. Give the pasted IDs." + sourceNote,
        [Arg.from, Arg.to, tracks, at, onto, source], batch: .step
    ) { a throws(ToolError) in
        let (range, sources, frame) = (try a.range(), try a[tracks], Frames(try a[at]))
        guard let targets = EditRules.pasteTargets(sources: sources, onto: try a[onto]) else {
            throw ToolError("Give one onto for each track, or none.")
        }
        if let work = try a.paste(
            .range(range, tracks: sources.map { TrackID($0) }), mode: .over(at: frame), onto: try a[onto])
        {
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
        [clips, at, onto, source], batch: .step
    ) { a throws(ToolError) in
        let (ids, frame, targets) = (try a[clips].map { ClipID($0) }, Frames(try a[at]), try a[onto])
        if let work = try a.paste(.clips(ids), mode: .over(at: frame), onto: targets) { return .paste(work) }
        return .edit(ripple: false) { session throws(SessionError) in
            let excerpt = try session.excerpt(of: ids)
            return try session.paste(excerpt, at: frame, on: EditRules.laneTargets(of: excerpt, onto: targets))
                .map(\.rawValue)
        }
    },
    Tool(
        "clip_replace",
        "Copy a range of tracks and replace the range at to until with it. The range goes on every track, and the "
            + "later audio on every track moves by the copy length minus the range length. at must be less than "
            + "until, else the call is refused. Give the pasted IDs." + sourceNote,
        [Arg.from, Arg.to, tracks, targetAt, until, onto, source], batch: .step
    ) { a throws(ToolError) in try a.rangePaste { .replace($0) } },
    Tool(
        "clip_fill",
        "Copy a range of tracks and paste it again and again from at, with butt joins, and cut the last copy at "
            + "until. Nothing moves. at must be less than until, else the call is refused. More than "
            + "\(Session.fillClipLimit) new clips are refused. Give the pasted IDs." + sourceNote,
        [Arg.from, Arg.to, tracks, targetAt, until, onto, source], batch: .step
    ) { a throws(ToolError) in try a.rangePaste { .fill($0) } },
    Tool(
        "clip_nudge",
        "Move clips by a number of frames and tracks. They overwrite the clips under them, or follow the mode.",
        [someClips, by, lanes, mode], batch: .step
    ) { a throws(ToolError) in
        let (ids, frames, count, overlap) = (
            try a[someClips].map { ClipID($0) }, Frames(try a[by]), try a[lanes], try a[mode]
        )
        return .edit(ripple: false) { session throws(SessionError) in
            try session.nudge(ids, by: frames, lanes: count, mode: overlap)
            return []
        }
    },
    Tool("clip_remove", "Remove clips and leave gaps.", [someClips], batch: .step) { a throws(ToolError) in
        let ids = try a[someClips].map { ClipID($0) }
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeClips(ids)
            return []
        }
    },
    Tool(
        "clip_move", "Move a clip. It overwrites the clips under it at the new place, or follows the mode.",
        [clip, Arg.track, start, mode], batch: .step
    ) { a throws(ToolError) in
        let (id, track, frame, overlap) = (
            ClipID(try a[clip]), TrackID(try a[Arg.track]), Frames(try a[start]), try a[mode]
        )
        return .edit(ripple: false) { session throws(SessionError) in
            try session.move(id, to: track, start: frame, mode: overlap)
            return []
        }
    },
    Tool("clip_trim", "Give a clip a new timeline range.", [clip, Arg.from, Arg.to], batch: .step) {
        a throws(ToolError) in
        let (id, range) = (ClipID(try a[clip]), try a.range())
        return .edit(ripple: false) { session throws(SessionError) in
            try session.trim(id, to: range)
            return []
        }
    },
    Tool("clip_gain", "Set the gain of one or more clips in one edit.", [clips, Arg.gain], batch: .step) {
        a throws(ToolError) in
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
        "clip_fade", "Set the fade-in or the fade-out of a clip in frames. 0 removes a fade.", [clip, fadeIn, fadeOut],
        batch: .step
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
        "clip_denoise",
        "Reduce the noise or remove the hum in clips, as dirigible clip denoise: for each run of clips of one file, "
            + "one new 24-bit WAV in Clips/ with a handle of 10 s on each side, made by the noise reduction of macOS, "
            + "and the clips move onto it. The source file stays. With hum 50 or 60, the render first removes mains "
            + "hum at that frequency and its harmonics; with noise false, it removes only the hum and also a stored "
            + "noise reduction, and a clip on any track is allowed. The noise reduction refuses a clip on a music or effects track. A second call on a "
            + "clip that this version reduced renders again from its source, and the same amount gives \"Nothing to "
            + "change.\". A clip that an older version reduced has no link, so a second call reduces it again. Give "
            + "one line for each clip: the clip and its new file, with a tab between them."
            + editCancelNote("no clip changes"),
        [clips, reduction, hum, noise], batch: .alone
    ) { a throws(ToolError) in
        let (withNoise, amount, hertz) = (try a[noise], try a[reduction], try a[hum])
        let request: ClipRenderRequest
        do throws(ClipRenderWork.Refusal) {
            request = try ClipRenderWork.request(noise: withNoise, reduction: amount, hum: hertz)
        } catch {
            throw ToolError(error.rawValue)
        }
        return .clipRender(ClipRenderWork(clips: try a[clips].map { ClipID($0) }, request: request))
    },
    Tool(
        "clip_repair",
        "Repair clips, as dirigible clip repair: reduce rumble with a high-pass filter, repair clipped peaks, and "
            + "soften harsh \"s\" sounds. Give at least one of rumble, clipping, and sibilance. For each run of clips "
            + "of one file, one new 24-bit WAV in Clips/ with a handle of 10 s on each side, and the clips move onto "
            + "it. The source file stays. Repairing clipped peaks makes the clip quieter by the level drop that "
            + "its line names: set clip_gain to that many dB to bring it back. A call or a compressed track can show no clipped peak. A second call on a clip that this version "
            + "rendered renders again from its source, and the same values give \"Nothing to change.\". A filter "
            + "corner (rumble or sibilance_hz) over 0.45 times the session rate is refused. Give one line for each "
            + "clip: the clip and its new file, with a tab between them. With clipping, one more line for each clip: "
            + "the clip, its repaired clipped runs, and its level drop in dB."
            + editCancelNote("no clip changes"),
        [clips, rumble, clipping, sibilance, sibilanceHertz], batch: .alone
    ) { a throws(ToolError) in
        let ids = try a[clips].map { ClipID($0) }
        let (high, declip, deess, hertz) = (try a[rumble], try a[clipping], try a[sibilance], try a[sibilanceHertz])
        let request: ClipRenderRequest
        do throws(ClipRenderWork.RepairRefusal) {
            request = try ClipRenderWork.repairRequest(
                rumble: high, clipping: declip, sibilance: deess, sibilanceHertz: hertz)
        } catch {
            throw ToolError(error.text)
        }
        return .clipRender(ClipRenderWork(clips: ids, request: request))
    },
    Tool(
        "clip_restore",
        "Put rendered clips back on their original files, as dirigible clip restore: each clip goes to the root of "
            + "its render chain at the frame that it played, with the added gain taken off. No audio is read or "
            + "written. Give the ID of each restored clip, or No rendered clip.",
        [clips], batch: .step
    ) { a throws(ToolError) in
        let ids = try a[clips]
        if let twice = EditRules.firstRepeat(ids) { throw ToolError("Clip \"\(twice)\" is given twice.") }
        let restored = ids.map { ClipID($0) }
        return .edit(ripple: false) { session throws(SessionError) in try restoredClips(restored, in: &session) }
    },
    Tool(
        "clip_crossfade",
        "Set the crossfade at the end of a clip and the start of the clip that touches it, in frames. 0 removes it.",
        [clip, crossfade], batch: .step
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
    Tool(
        "clip_heal",
        "Join the clips that touch and play on in one file at one gain at each frame, the envelope included, with "
            + "no fade at the join. The sound does not change: it undoes a split. Give the ID of each healed clip.",
        [healTracks, healFrom, healTo], batch: .step
    ) { a throws(ToolError) in
        let targets = try a[healTracks]?.map { TrackID($0) }
        let range: ClosedRange<Frames>?
        switch (try a[healFrom], try a[healTo]) {
        case (nil, nil): range = nil
        case (let from?, let to?):
            guard let checked = EditRules.joinRange(from: from, to: to) else {
                throw ToolError("from must not be more than to.")
            }
            range = checked
        default: throw ToolError("Give from and to, or neither.")
        }
        return .edit(ripple: false) { session throws(SessionError) in
            try session.heal(tracks: targets, range: range).map(\.rawValue)
        }
    },
]
