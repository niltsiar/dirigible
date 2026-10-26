import Testing

@testable import DirigibleMCP

/// Each tool of `Tool.all` names its batch role (decision 0063). A new tool must join one of the
/// two lists below, and this test fails until it does.
struct BatchRoleTests {
    /// The 35 tools whose call can be a step: 31 always, and 4 when the call copies no file.
    static let steps: Set<String> = [
        "track_add", "track_add_call", "track_remove", "track_rename", "track_gain", "track_route", "track_layout",
        "track_mute", "track_solo", "track_role", "marker_set", "marker_remove", "episode_set", "capture_remove",
        "file_remove", "clip_place", "clip_clear", "clip_split", "clip_split_at", "clip_paste", "clip_paste_clips",
        "clip_nudge", "clip_remove", "clip_move", "clip_trim", "clip_gain", "clip_fade", "clip_crossfade",
        "clip_heal", "clip_envelope", "clip_gain_range", "clip_ripple_delete", "clip_ripple_insert",
        "clip_ripple_trim", "transcript_cut",
    ]

    /// The 29 tools that are never a step.
    static let alone: Set<String> = [
        "session_create", "session_info", "episode_get", "file_prune", "backup_list", "backup_revert",
        "clip_split_stereo", "transcript_import", "transcript_words", "transcript_export", "take_map", "record",
        "transport_play", "transport_stop", "transport_locate", "loudness", "export", "render", "level", "duck",
        "import", "silences", "nearest_pause", "meter", "chapters_export", "chapters_import", "devices", "apps",
        "batch",
    ]

    @Test func eachToolHasItsBatchRole() {
        #expect(Self.steps.count == 35 && Self.alone.count == 29 && Self.steps.isDisjoint(with: Self.alone))
        let names = Tool.all.map(\.name)
        let unlisted = Set(names).subtracting(Self.steps).subtracting(Self.alone)
        #expect(unlisted.isEmpty, "BATCH-S2-6 tools in neither list: \(unlisted.sorted())")
        let gone = Self.steps.union(Self.alone).subtracting(names)
        #expect(gone.isEmpty, "names that are not tools: \(gone.sorted())")
        for tool in Tool.all {
            let expected: Tool.BatchRole = Self.steps.contains(tool.name) ? .step : .alone
            #expect(tool.batch == expected, "\(tool.name) has the role \(tool.batch), the list says \(expected)")
        }
    }
}
