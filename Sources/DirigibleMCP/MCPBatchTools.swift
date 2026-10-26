private let calls = Param.required(
    "calls",
    "The calls, in order, each {\"tool\": <name>, \"arguments\": {...}}. The arguments have no package.",
    BatchWork.calls)

/// The tool `batch` (decision 0063).
let batchTools = [
    Tool(
        "batch",
        "Apply \(BatchWork.limit.lowerBound) to \(BatchWork.limit.upperBound) edit calls, in order, as one edit: one undo step in the app, and one save on a closed "
            + "package. If a call fails, the batch changes nothing. A call is a step when its tool edits session.xml "
            + "only: the track, marker, episode, clip, ripple, and transcript_cut tools, file_remove, and "
            + "capture_remove, with no file argument (a source, an image, or an artwork). A call to any other tool "
            + "is refused. To name a new object in a later step, the earlier step gives its ID: track_add id, "
            + "track_add_call host_id and guest_id, clip_place id, clip_split right_id, marker_set id. A tool with "
            + "no ID argument, for example clip_split_at or clip_paste, gives its new IDs in its result lines. "
            + "Each result line is calls[<index>] <tool>: <line>.",
        [calls], batch: .alone
    ) { a throws(ToolError) in
        let list = try a[calls]
        do throws(BatchWork.Failure) {
            return .batch(try BatchWork.check(list, package: a.path))
        } catch {
            throw ToolError(error.message(rippleBlocked: splitTakeMessage(a.path)))
        }
    }
]
