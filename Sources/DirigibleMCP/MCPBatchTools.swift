private let calls = Param.required(
    "calls",
    "The calls, in order, each {\"tool\": <name>, \"arguments\": {...}}. The arguments have no package.",
    BatchWork.calls)

/// The tool `batch` (decision 0063).
let batchTools = [
    Tool(
        "batch",
        "Apply \(BatchWork.limit.lowerBound) to \(BatchWork.limit.upperBound) edit calls, in order, as one edit: one undo step in the app, and one save on a closed "
            + "package. If a call fails, the batch changes nothing. Each call sees the session after the earlier "
            + "calls: a ripple moves the later frames, and the right part of a cut clip gets a new ID. Send ripple "
            + "cuts from the last to the first, or use one call with many ranges. A call is a step when its tool "
            + "edits session.xml only and has no file argument (a source, an image, or an artwork): file_remove, "
            + "capture_remove, silence_edit, the track and marker tools, the episode tools except episode_get, and the clip and "
            + "ripple tools except clip_split_stereo, clip_denoise, clip_repair, clip_level_over_time, and clip_sync. track_match_voice is a step "
            + "with no reference: a call with reference reads audio and cannot run in a batch. A call to transcript_cut or to any other "
            + "tool is refused. To name a new object in a later step, the earlier step gives its ID: track_add id, "
            + "track_add_call host_id and guest_id, clip_place id, clip_split right_id, marker_set id. A tool with "
            + "no ID argument, for example clip_split_at or clip_paste, gives its new IDs in its result lines. "
            + "Each result line is calls[<index>] <tool>: <line>.",
        [calls], batch: .alone
    ) { a throws(ToolError) in
        let list = try BatchWork.calls(of: a[calls])
        do throws(BatchWork.CheckFailure) {
            return .batch(try BatchWork.check(list, package: a.path))
        } catch {
            throw ToolError(error.message)
        }
    }
]
